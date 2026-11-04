-- WEEK 6: run in the EXISTING Supabase project after Week 4.
-- Includes the Week 5 caption-style upgrade. Safe to rerun.
-- Existing captions were generated as jokes: preserve their style and all votes.
begin;
alter table public.meme_images add column if not exists caption_style text not null default 'meme'
  check (caption_style in ('meme', 'scenery'));

create or replace function public.publish_meme(image_id uuid, image_description text, caption_texts text[], generation_prompts jsonb, generation_model text, generation_version text)
returns void language plpgsql security definer set search_path = '' as $$
declare img public.meme_images; caption text; prompt jsonb; n integer := 0; style text;
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
  style := coalesce(generation_prompts->0->>'caption_style', 'meme');
  if style not in ('meme', 'scenery') then raise exception 'invalid_caption_style'; end if;
  insert into public.meme_generations(image_id, prompts, model, prompt_version) values (img.id, generation_prompts, generation_model, generation_version);
  foreach caption in array caption_texts loop
    if caption is null or length(trim(caption)) not between 1 and 240 then raise exception 'invalid_caption'; end if;
    n := n + 1;
    insert into public.meme_captions(image_id, text, position) values (img.id, trim(caption), n);
  end loop;
  update public.meme_images set description = trim(image_description), caption_style = style, status = 'ready' where id = img.id;
end $$;

revoke all on function public.publish_meme(uuid,text,text[],jsonb,text,text) from public, anon;
grant execute on function public.publish_meme(uuid,text,text[],jsonb,text,text) to authenticated;

-- Lock down the privilege column without breaking the original profile editor.
alter table public.profiles add column if not exists is_superadmin boolean not null default false;
revoke insert, update, delete on public.profiles from public, anon, authenticated;
revoke update (is_superadmin) on public.profiles from public, anon, authenticated;
grant update(first_name,last_name,avatar_path,updated_at) on public.profiles to authenticated;
alter table public.profiles enable row level security;

-- Defense in depth even if table-wide UPDATE is accidentally regranted later.
create or replace function public.protect_admin_flag()
returns trigger language plpgsql set search_path = '' as $$
begin
 if (tg_op = 'INSERT' and new.is_superadmin) or (tg_op = 'UPDATE' and new.is_superadmin is distinct from old.is_superadmin) then
  if auth.uid() is not null or current_user in ('anon','authenticated') then raise exception 'admin_flag_dashboard_only'; end if;
 end if;
 return new;
end $$;
drop trigger if exists protect_admin_flag on public.profiles;
create trigger protect_admin_flag before insert or update on public.profiles for each row execute function public.protect_admin_flag();

create or replace function public.is_superadmin()
returns boolean language sql stable security definer set search_path = '' as $$
 select auth.uid() is not null
 and exists(select 1 from public.profiles p where p.id=auth.uid() and p.is_superadmin)
 and exists(select 1 from auth.identities i where i.user_id=auth.uid() and i.provider='google');
$$;
create or replace function public.require_superadmin()
returns void language plpgsql security definer set search_path = '' as $$
begin
 if not public.is_superadmin() then raise exception 'administrator_required' using errcode='42501'; end if;
end $$;
revoke all on function public.is_superadmin(), public.require_superadmin() from public, anon;
grant execute on function public.is_superadmin(), public.require_superadmin() to authenticated;

-- Extra reads are available only to real Google-authenticated administrators.
drop policy if exists "Admins read all images" on public.meme_images;
create policy "Admins read all images" on public.meme_images for select to authenticated using ((select public.is_superadmin()));
drop policy if exists "Admins read all captions" on public.meme_captions;
create policy "Admins read all captions" on public.meme_captions for select to authenticated using ((select public.is_superadmin()));
drop policy if exists "Admins read all generations" on public.meme_generations;
create policy "Admins read all generations" on public.meme_generations for select to authenticated using ((select public.is_superadmin()));
drop policy if exists "Admins read all ratings" on public.caption_votes;
create policy "Admins read all ratings" on public.caption_votes for select to authenticated using ((select public.is_superadmin()));
drop policy if exists "Admins view media storage" on storage.objects;
create policy "Admins view media storage" on storage.objects for select to authenticated
 using (bucket_id='meme-images' and (select public.is_superadmin()));
drop policy if exists "Admins clean media storage" on storage.objects;
create policy "Admins clean media storage" on storage.objects for delete to authenticated
 using (bucket_id='meme-images' and (select public.is_superadmin()));

create or replace function public.admin_profiles(page_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
 perform public.require_superadmin();
 if page_offset is null or page_offset<0 or page_offset>2000000 then raise exception 'invalid_page'; end if;
 select jsonb_build_object('total',(select count(*) from public.profiles), 'items',coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb)) into result
 from (select p.id,p.first_name,p.last_name,p.is_superadmin,u.email,u.created_at from public.profiles p join auth.users u on u.id=p.id order by u.created_at desc,p.id limit 20 offset page_offset) t;
 return result;
end $$;
create or replace function public.admin_ratings(page_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
 perform public.require_superadmin();
 if page_offset is null or page_offset<0 or page_offset>2000000 then raise exception 'invalid_page'; end if;
 select jsonb_build_object('total',(select count(*) from public.caption_votes),'items',coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb)) into result
 from (select v.caption_id,v.user_id,v.value,v.created_at,c.text,i.caption_style as style,trim(concat_ws(' ',p.first_name,p.last_name)) as name from public.caption_votes v join public.meme_captions c on c.id=v.caption_id join public.meme_images i on i.id=c.image_id left join public.profiles p on p.id=v.user_id order by v.created_at desc,v.caption_id,v.user_id limit 20 offset page_offset) t;
 return result;
end $$;
create or replace function public.admin_dashboard()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb; trend jsonb; top_captions jsonb;
begin
 perform public.require_superadmin();
 select coalesce(jsonb_agg(to_jsonb(t) order by t.day),'[]'::jsonb) into trend
 from (select to_char(d.day,'YYYY-MM-DD') as day,count(i.id) as count
 from generate_series(date_trunc('day',now() at time zone 'UTC')-interval '13 days',date_trunc('day',now() at time zone 'UTC'),interval '1 day') d(day)
 left join public.meme_images i on i.status='ready' and (i.created_at at time zone 'UTC')>=d.day and (i.created_at at time zone 'UTC')<d.day+interval '1 day' group by d.day) t;
 select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) into top_captions
 from (select c.id,c.text,i.caption_style as style,sum(v.value) as score,count(*) filter(where v.value=1) as upvotes,count(*) filter(where v.value=-1) as downvotes
 from public.meme_captions c join public.meme_images i on i.id=c.image_id and i.status='ready' join public.caption_votes v on v.caption_id=c.id
 group by c.id,c.text,i.caption_style order by sum(v.value) desc,count(*) desc,c.id limit 5) t;
 select jsonb_build_object('profiles',(select count(*) from public.profiles),
 'images',count(*) filter(where status='ready'),'memes',count(*) filter(where status='ready' and caption_style='meme'),
 'scenery',count(*) filter(where status='ready' and caption_style='scenery'),'pending',count(*) filter(where status='pending'),'failed',count(*) filter(where status='failed'),
 'votes',(select count(*) from public.caption_votes),
 'rated_percent',(select coalesce(round(100.0*count(distinct v.caption_id)/nullif(count(distinct c.id),0)),0) from public.meme_captions c join public.meme_images i on i.id=c.image_id and i.status='ready' left join public.caption_votes v on v.caption_id=c.id),
 'trend',trend,'top',top_captions) into result from public.meme_images;
 return result;
end $$;

-- All writes are explicit authenticated RPCs, never a service-role client.
create or replace function public.admin_update_media(target_image uuid,new_description text,caption_texts text[],new_style text)
returns void language plpgsql security definer set search_path = '' as $$
declare caption text; n integer := 0;
begin
 perform public.require_superadmin();
 perform 1 from public.meme_images where id=target_image and status='ready' for update;
 if not found then raise exception 'published_image_required'; end if;
 if new_description is null or length(trim(new_description)) not between 1 and 4000 or new_style is null or new_style not in ('meme','scenery') or caption_texts is null or cardinality(caption_texts)<>3 then raise exception 'invalid_output'; end if;
 if (select count(distinct trim(t)) from unnest(caption_texts) as t)<>3 then raise exception 'invalid_output'; end if;
 foreach caption in array caption_texts loop
  if caption is null or length(trim(caption)) not between 1 and 240 then raise exception 'invalid_caption'; end if;
  n:=n+1;
  update public.meme_captions set text=trim(caption) where image_id=target_image and position=n;
  if not found then raise exception 'caption_missing'; end if;
 end loop;
 update public.meme_images set description=trim(new_description),caption_style=new_style where id=target_image;
end $$;
create or replace function public.admin_delete_media(target_image uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare path text; image_status text; image_created timestamptz;
begin
 perform public.require_superadmin();
 select storage_path,status,created_at into path,image_status,image_created from public.meme_images where id=target_image for update;
 if not found then raise exception 'image_not_found'; end if;
 if image_status='pending' and image_created>now()-interval '5 minutes' then raise exception 'generation_in_progress'; end if;
 delete from public.meme_images where id=target_image;
 return path;
end $$;
revoke all on function public.admin_profiles(integer),public.admin_ratings(integer),public.admin_dashboard(),public.admin_update_media(uuid,text,text[],text),public.admin_delete_media(uuid) from public,anon;
grant execute on function public.admin_profiles(integer),public.admin_ratings(integer),public.admin_dashboard(),public.admin_update_media(uuid,text,text[],text),public.admin_delete_media(uuid) to authenticated;
commit;

-- Bootstrap your own account in Supabase Table Editor AFTER this migration:
-- public.profiles -> find your exact auth user UUID -> set is_superadmin=true.
-- Do not grant the flag from the website or use a service-role key in the app.
