-- Run in the EXISTING Week 3 Supabase project. Safe to rerun.
begin;

create table if not exists public.meme_images (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  storage_path text not null unique,
  description text check (length(description) between 1 and 4000),
  status text not null default 'pending' check (status in ('pending', 'ready', 'failed')),
  created_at timestamptz not null default now()
);
create index if not exists meme_images_user_created on public.meme_images(user_id, created_at);
create table if not exists public.meme_captions (
  id uuid primary key default gen_random_uuid(),
  image_id uuid not null references public.meme_images(id) on delete cascade,
  text text not null check (length(trim(text)) between 1 and 240),
  position integer not null check (position between 1 and 3),
  created_at timestamptz not null default now(),
  unique(image_id, position)
);
create table if not exists public.caption_votes (
  caption_id uuid not null references public.meme_captions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  value smallint not null check (value in (-1, 1)),
  created_at timestamptz not null default now(),
  primary key(caption_id, user_id)
);
create index if not exists caption_votes_user on public.caption_votes(user_id);
create table if not exists public.meme_generations (
  image_id uuid primary key references public.meme_images(id) on delete cascade,
  prompts jsonb not null check (jsonb_typeof(prompts) = 'array' and jsonb_array_length(prompts) = 2),
  model text not null check (length(trim(model)) between 1 and 100),
  prompt_version text not null check (length(trim(prompt_version)) between 1 and 100),
  created_at timestamptz not null default now()
);


-- All application tables, including any extra public tables, use default-deny RLS.
-- Existing policies are retained; audit the results at the bottom for extra tables.
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t.tablename);
  end loop;
end $$;

revoke all on public.meme_images, public.meme_captions, public.caption_votes, public.meme_generations from anon, authenticated;
grant select on public.meme_images, public.meme_captions, public.caption_votes, public.meme_generations to authenticated;
drop policy if exists "Owners read generation prompts" on public.meme_generations;
create policy "Owners read generation prompts" on public.meme_generations for select to authenticated
  using (exists (select 1 from public.meme_images i where i.id = image_id and i.user_id = (select auth.uid())));
-- Voting remains constrained by RLS even when called directly via Supabase.
grant insert, update, delete on public.caption_votes to authenticated;
revoke all on public.caption_ideas from anon, authenticated;
grant select on public.caption_ideas to anon, authenticated;

drop policy if exists "Members read published or own images" on public.meme_images;
create policy "Members read published or own images" on public.meme_images for select to authenticated
  using (status = 'ready' or user_id = (select auth.uid()));
drop policy if exists "Members read published captions" on public.meme_captions;
create policy "Members read published captions" on public.meme_captions for select to authenticated
  using (exists (select 1 from public.meme_images i where i.id = image_id and i.status = 'ready'));
drop policy if exists "Read own votes" on public.caption_votes;
create policy "Read own votes" on public.caption_votes for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "Insert own vote" on public.caption_votes;
create policy "Insert own vote" on public.caption_votes for insert to authenticated
  with check (user_id = (select auth.uid()) and exists (select 1 from public.meme_captions c where c.id = caption_id));
drop policy if exists "Update own vote" on public.caption_votes;
create policy "Update own vote" on public.caption_votes for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and exists (select 1 from public.meme_captions c where c.id = caption_id));
drop policy if exists "Delete own vote" on public.caption_votes;
create policy "Delete own vote" on public.caption_votes for delete to authenticated using (user_id = (select auth.uid()));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('meme-images', 'meme-images', false, 2097152, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 2097152,
  allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp'];
drop policy if exists "Members view meme images" on storage.objects;
create policy "Members view meme images" on storage.objects for select to authenticated
  using (bucket_id = 'meme-images' and exists (select 1 from public.meme_images i where i.storage_path = name and (i.status = 'ready' or i.user_id = (select auth.uid()))));
drop policy if exists "Upload reserved image" on storage.objects;
create policy "Upload reserved image" on storage.objects for insert to authenticated
  with check (bucket_id = 'meme-images' and exists (select 1 from public.meme_images i where i.storage_path = name and i.user_id = (select auth.uid()) and i.status = 'pending'));
drop policy if exists "Remove unpublished own image" on storage.objects;
create policy "Remove unpublished own image" on storage.objects for delete to authenticated
  using (bucket_id = 'meme-images' and exists (select 1 from public.meme_images i where i.storage_path = name and i.user_id = (select auth.uid()) and i.status <> 'ready'));

-- Narrow, authenticated RPCs avoid requiring a service-role key.
-- All SECURITY DEFINER functions have fixed search paths and explicit auth checks.
create or replace function public.reserve_meme_image(extension text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); image_id uuid := gen_random_uuid(); path text;
begin
  if uid is null then raise exception 'authentication_required'; end if;
  if extension is null or extension not in ('png', 'jpg', 'webp') then raise exception 'invalid_extension'; end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));
  if (select count(*) from public.meme_images where user_id = uid and created_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC') >= 10 then
    raise exception 'daily_limit';
  end if;
  if exists (select 1 from public.meme_images where user_id = uid and status = 'pending' and created_at > now() - interval '5 minutes') then
    raise exception 'generation_in_progress';
  end if;
  path := uid::text || '/' || image_id::text || '.' || extension;
  insert into public.meme_images(id, user_id, storage_path) values (image_id, uid, path);
  return jsonb_build_object('id', image_id, 'storage_path', path);
end $$;

-- Remove the earlier signature so prompts cannot be omitted through the old RPC.
drop function if exists public.publish_meme(uuid,text,text[]);
create or replace function public.publish_meme(image_id uuid, image_description text, caption_texts text[], generation_prompts jsonb, generation_model text, generation_version text)
returns void language plpgsql security definer set search_path = '' as $$
declare img public.meme_images; caption text; prompt jsonb; n integer := 0;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  select * into img from public.meme_images i where i.id = image_id and i.user_id = auth.uid() for update;
  if not found or img.status <> 'pending' then raise exception 'invalid_image'; end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'meme-images' and o.name = img.storage_path) then raise exception 'missing_upload'; end if;
  if image_description is null or length(trim(image_description)) not between 1 and 4000 or caption_texts is null or cardinality(caption_texts) <> 3 then raise exception 'invalid_output'; end if;
  if (select count(distinct trim(t)) from unnest(caption_texts) as t) <> 3 then raise exception 'invalid_output'; end if;
  if generation_prompts is null or jsonb_typeof(generation_prompts) <> 'array' then raise exception 'invalid_prompts'; end if;
  if octet_length(generation_prompts::text) > 30000 or jsonb_array_length(generation_prompts) <> 2 or generation_model is null or generation_version is null then raise exception 'invalid_prompts'; end if;
  if generation_prompts->0->>'step' is distinct from 'describe_image' or generation_prompts->1->>'step' is distinct from 'write_captions' then raise exception 'invalid_prompts'; end if;
  for prompt in select value from jsonb_array_elements(generation_prompts) loop
    if jsonb_typeof(prompt->'instructions') is distinct from 'string' or length(trim(prompt->>'instructions')) not between 1 and 8000
      or jsonb_typeof(prompt->'user_prompt') is distinct from 'string' or length(trim(prompt->>'user_prompt')) not between 1 and 8000
      or prompt->>'model' is distinct from generation_model then raise exception 'invalid_prompts'; end if;
  end loop;
  insert into public.meme_generations(image_id, prompts, model, prompt_version) values (img.id, generation_prompts, generation_model, generation_version);
  foreach caption in array caption_texts loop
    if caption is null or length(trim(caption)) not between 1 and 240 then raise exception 'invalid_caption'; end if;
    n := n + 1;
    insert into public.meme_captions(image_id, text, position) values (img.id, trim(caption), n);
  end loop;
  update public.meme_images set description = trim(image_description), status = 'ready' where id = img.id;
end $$;

create or replace function public.fail_meme(image_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  update public.meme_images i set status = 'failed' where i.id = image_id and i.user_id = auth.uid() and i.status = 'pending';
end $$;

create or replace function public.caption_scores(caption_ids uuid[])
returns table(caption_id uuid, score bigint, upvotes bigint, downvotes bigint)
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  if cardinality(caption_ids) > 300 then raise exception 'too_many_captions'; end if;
  return query select c.id, coalesce(sum(v.value), 0)::bigint,
    count(*) filter (where v.value = 1), count(*) filter (where v.value = -1)
    from public.meme_captions c join public.meme_images i on i.id = c.image_id and i.status = 'ready'
    left join public.caption_votes v on v.caption_id = c.id
    where c.id = any(caption_ids) group by c.id;
end $$;

create or replace function public.cast_caption_vote(target_caption uuid, direction integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); old_value integer; current_value integer; result jsonb;
begin
  if uid is null then raise exception 'authentication_required'; end if;
  if direction is null or direction not in (-1, 1) then raise exception 'invalid_vote'; end if;
  if not exists (select 1 from public.meme_captions c join public.meme_images i on i.id = c.image_id where c.id = target_caption and i.status = 'ready') then raise exception 'caption_unavailable'; end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text || target_caption::text, 0));
  select value into old_value from public.caption_votes where caption_id = target_caption and user_id = uid;
  if old_value = direction then
    delete from public.caption_votes where caption_id = target_caption and user_id = uid;
    current_value := 0;
  else
    insert into public.caption_votes(caption_id, user_id, value) values (target_caption, uid, direction)
      on conflict (caption_id, user_id) do update set value = excluded.value;
    current_value := direction;
  end if;
  select jsonb_build_object('score', coalesce(sum(value), 0), 'upvotes', count(*) filter (where value = 1),
    'downvotes', count(*) filter (where value = -1), 'mine', current_value) into result
    from public.caption_votes where caption_id = target_caption;
  return result;
end $$;

revoke all on function public.reserve_meme_image(text), public.publish_meme(uuid,text,text[],jsonb,text,text), public.fail_meme(uuid), public.caption_scores(uuid[]), public.cast_caption_vote(uuid,integer) from public, anon;
grant execute on function public.reserve_meme_image(text), public.publish_meme(uuid,text,text[],jsonb,text,text), public.fail_meme(uuid), public.caption_scores(uuid[]), public.cast_caption_vote(uuid,integer) to authenticated;
commit;

-- These checks should show RLS=true on all application tables and only intended policies.
select tablename, rowsecurity from pg_tables where schemaname = 'public' order by tablename;
select tablename, policyname, roles, cmd from pg_policies where schemaname = 'public' order by tablename, policyname;
