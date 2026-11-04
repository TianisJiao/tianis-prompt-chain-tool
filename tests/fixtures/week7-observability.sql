-- Week 7: apply once to the EXISTING shared database AFTER week6-admin.sql.
-- Rerunnable; no existing images, captions, votes, profiles or prompts are removed.
begin;
create table if not exists public.llm_providers (
 id uuid primary key default gen_random_uuid(), name text not null unique check(length(trim(name)) between 1 and 80),
 adapter text not null default 'openai_responses' check(adapter='openai_responses'),
 enabled boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.llm_models (
 id uuid primary key default gen_random_uuid(), provider_id uuid not null references public.llm_providers(id) on delete restrict,
 name text not null unique check(length(trim(name)) between 1 and 80),
 model_id text not null check(model_id ~ '^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,99}$'),
 enabled boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.prompt_chains (
 id uuid primary key default gen_random_uuid(), slug text not null unique, name text not null,
 description text not null, model_id uuid not null references public.llm_models(id) on delete restrict,
 created_at timestamptz not null default now()
);
create table if not exists public.prompt_chain_steps (
 id uuid primary key default gen_random_uuid(), chain_id uuid not null references public.prompt_chains(id) on delete cascade,
 position integer not null check(position in (1,2)), name text not null,
 purpose text not null, instructions_suffix text not null default '', unique(chain_id,position)
);
create table if not exists public.prompt_chain_mix (
 chain_id uuid primary key references public.prompt_chains(id) on delete restrict,
 weight integer not null check(weight between 0 and 100), updated_at timestamptz not null default now()
);
create table if not exists public.terms (
 id uuid primary key default gen_random_uuid(), term text not null unique check(length(trim(term)) between 1 and 80),
 definition text not null check(length(trim(definition)) between 1 and 500),
 style text not null default 'all' check(style in ('all','meme','scenery')),
 enabled boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.ai_generation_examples (
 id uuid primary key default gen_random_uuid(), title text not null check(length(trim(title)) between 1 and 80),
 image_id uuid references public.meme_images(id) on delete set null,
 input_description text not null check(length(trim(input_description)) between 1 and 500),
 caption text not null check(length(trim(caption)) between 1 and 240),
 style text not null check(style in ('meme','scenery')), enabled boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists public.allowed_signup_domains (
 id uuid primary key default gen_random_uuid(), domain text not null unique
 check(domain=lower(trim(domain)) and domain ~ '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}$' and domain not like '%..%'),
 note text not null default '' check(length(note)<=300), enabled boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists public.whitelisted_emails (
 id uuid primary key default gen_random_uuid(), email text not null unique
 check(email=lower(trim(email)) and length(email)<=254 and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
 note text not null default '' check(length(note)<=300), enabled boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists public.signup_settings (
 id boolean primary key default true check(id), enforce_allowlist boolean not null default false
);
insert into public.signup_settings(id) values(true) on conflict do nothing;
create table if not exists public.generation_requests (
 id uuid primary key default gen_random_uuid(), image_id uuid not null unique references public.meme_images(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 source text not null check(source in ('rating_app','admin_app')),
 requested_mode text not null check(requested_mode in ('auto','meme','scenery')),
 chain_id uuid references public.prompt_chains(id) on delete restrict, config_snapshot jsonb not null,
 status text not null default 'running' check(status in ('running','succeeded','failed')),
 error_code text check(length(error_code)<=80), created_at timestamptz not null default now(), finished_at timestamptz
);
create index if not exists generation_requests_created on public.generation_requests(created_at desc,id);
create table if not exists public.llm_responses (
 id uuid primary key default gen_random_uuid(), request_id uuid not null references public.generation_requests(id) on delete cascade,
 step integer not null check(step in (1,2)), step_name text not null check(step_name in ('describe_image','write_captions')),
 model text not null check(length(model) between 1 and 100), prompt jsonb not null,
 output_text text not null default '' check(length(output_text)<=32000),
 status text not null check(status in ('succeeded','failed')),
 http_status integer check(http_status between 100 and 599), error_code text check(length(error_code)<=80),
 provider_response_id text check(length(provider_response_id)<=200), provider_request_id text check(length(provider_request_id)<=200),
 input_tokens integer check(input_tokens>=0), output_tokens integer check(output_tokens>=0),
 duration_ms integer not null check(duration_ms between 0 and 300000), created_at timestamptz not null default now(),
 unique(request_id,step), check(octet_length(prompt::text)<=24000)
);
insert into public.llm_providers(name) values('OpenAI') on conflict(name) do nothing;
insert into public.llm_models(provider_id,name,model_id)
 select id,'GPT-4.1 mini','gpt-4.1-mini' from public.llm_providers where name='OpenAI' on conflict(name) do nothing;
insert into public.prompt_chains(slug,name,description,model_id)
 select v.slug,v.name,v.description,m.id from public.llm_models m cross join (values
 ('classic','Classic NYC','Two steps: analyze the image, then write three adaptive captions.'),
 ('postcard','Postcard voice','The same two steps, with a concise personal postcard voice.')) v(slug,name,description)
 where m.name='GPT-4.1 mini' on conflict(slug) do nothing;
insert into public.prompt_chain_steps(chain_id,position,name,purpose,instructions_suffix)
 select c.id,s.position,s.name,s.purpose,case when c.slug='postcard' and s.position=2
 then 'Keep the voice concise and personal, like a postcard sent to a friend. Preserve the selected funny or poetic style.' else '' end
 from public.prompt_chains c cross join (values (1,'describe_image','Analyze visible details and classify meme versus scenery.'),
 (2,'write_captions','Use the description, theme, glossary, and examples to write three captions.')) s(position,name,purpose)
 on conflict(chain_id,position) do nothing;
insert into public.prompt_chain_mix(chain_id,weight) select id,case when slug='classic' then 80 else 20 end from public.prompt_chains on conflict do nothing;
-- New configuration and observability tables are private to current Google admins.
do $$ declare t text; begin
 foreach t in array array['llm_providers','llm_models','prompt_chains','prompt_chain_steps','prompt_chain_mix','terms','ai_generation_examples','allowed_signup_domains','whitelisted_emails','signup_settings','generation_requests','llm_responses'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant select on public.%I to authenticated',t);
 execute format('drop policy if exists "Week7 admin read" on public.%I',t);
 execute format('create policy "Week7 admin read" on public.%I for select to authenticated using ((select public.is_superadmin()))',t);
 end loop;
 foreach t in array array['llm_providers','llm_models','terms','ai_generation_examples','allowed_signup_domains','whitelisted_emails'] loop
 execute format('grant insert,update,delete on public.%I to authenticated',t);
 execute format('drop policy if exists "Week7 admin write" on public.%I',t);
 execute format('create policy "Week7 admin write" on public.%I for all to authenticated using ((select public.is_superadmin())) with check ((select public.is_superadmin()))',t);
 end loop;
end $$;
-- Mix updates are atomic: all weights are supplied together and at least one stays positive.
create or replace function public.admin_set_chain_mix(weights jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare item record; n integer;
begin
 perform public.require_superadmin();
 perform 1 from public.prompt_chain_mix order by chain_id for update;
 if jsonb_typeof(weights) is distinct from 'object' then raise exception 'invalid_mix'; end if;
 select count(*) into n from public.prompt_chain_mix;
 if (select count(*) from jsonb_object_keys(weights))<>n then raise exception 'complete_mix_required'; end if;
 for item in select * from public.prompt_chain_mix loop
 if not(weights ? item.chain_id::text) or (weights->>item.chain_id::text) !~ '^\d{1,3}$'
 or (weights->>item.chain_id::text)::int not between 0 and 100 then raise exception 'invalid_weight'; end if;
 end loop;
 if not exists(select 1 from public.prompt_chain_mix x join public.prompt_chains c on c.id=x.chain_id
 join public.llm_models m on m.id=c.model_id join public.llm_providers p on p.id=m.provider_id
 where (weights->>x.chain_id::text)::int>0 and m.enabled and p.enabled) then raise exception 'one_enabled_chain_required'; end if;
 update public.prompt_chain_mix set weight=(weights->>chain_id::text)::int,updated_at=now();
end $$;
-- Only new signups are restricted. Existing accounts and admin flags are unchanged.
create or replace function public.admin_set_signup_gate(enforce boolean) returns void
language plpgsql security definer set search_path='' as $$ begin
 perform public.require_superadmin();
 if enforce is null then raise exception 'invalid_setting'; end if;
 if enforce and not exists(select 1 from public.allowed_signup_domains where enabled)
 and not exists(select 1 from public.whitelisted_emails where enabled) then raise exception 'add_allowlist_entry_first'; end if;
 update public.signup_settings set enforce_allowlist=enforce where id;
end $$;
create or replace function public.check_signup_allowlist() returns trigger
language plpgsql security definer set search_path='' as $$ begin
 if (select enforce_allowlist from public.signup_settings where id) and not exists(
 select 1 from public.whitelisted_emails where enabled and email=lower(new.email)) and not exists(
 select 1 from public.allowed_signup_domains where enabled and domain=split_part(lower(new.email),'@',2)) then
 raise exception 'signup_not_allowed'; end if;
 return new;
end $$;
drop trigger if exists week7_signup_allowlist on auth.users;
create trigger week7_signup_allowlist before insert on auth.users for each row execute function public.check_signup_allowlist();
revoke all on function public.check_signup_allowlist() from public,anon,authenticated;
-- Starts one immutable configuration snapshot for an owned pending image.
create or replace function public.begin_generation(target_image uuid,request_source text,caption_mode text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record; cfg jsonb; rid uuid;
begin
 if auth.uid() is null then raise exception 'authentication_required'; end if;
 if request_source is null or request_source not in ('rating_app','admin_app') or caption_mode is null or caption_mode not in ('auto','meme','scenery') then raise exception 'invalid_request'; end if;
 if request_source='admin_app' then perform public.require_superadmin(); end if;
 perform 1 from public.meme_images where id=target_image and user_id=auth.uid() and status='pending' for update;
 if not found then raise exception 'owned_pending_image_required'; end if;
 select ch.id,ch.slug,ch.name,m.model_id,p.name as provider into c from public.prompt_chain_mix x
 join public.prompt_chains ch on ch.id=x.chain_id join public.llm_models m on m.id=ch.model_id
 join public.llm_providers p on p.id=m.provider_id where x.weight>0 and m.enabled and p.enabled
 order by -ln(greatest(random(),0.000001))/x.weight limit 1;
 if not found then
 insert into public.generation_requests(image_id,user_id,source,requested_mode,config_snapshot)
 values(target_image,auth.uid(),request_source,caption_mode,'{"error":"no_enabled_chain"}'::jsonb) returning id into rid;
 return jsonb_build_object('request_id',rid,'config',jsonb_build_object('error','no_enabled_chain'));
 end if;
 select jsonb_build_object('chain_id',c.id,'slug',c.slug,'name',c.name,'model',c.model_id,'provider',c.provider,
 'steps',(select jsonb_agg(to_jsonb(s) order by s.position) from public.prompt_chain_steps s where s.chain_id=c.id),
 'terms',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from (select term,definition,style from public.terms where enabled order by term limit 8)t),
 'examples',(select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from (select title,input_description,caption,style from public.ai_generation_examples where enabled order by created_at desc,id limit 4)t)) into cfg;
 insert into public.generation_requests(image_id,user_id,source,requested_mode,chain_id,config_snapshot)
 values(target_image,auth.uid(),request_source,caption_mode,c.id,cfg) returning id into rid;
 return jsonb_build_object('request_id',rid,'config',cfg);
end $$;
-- Receives only text/metadata, never credentials or image bytes. No direct client table writes.
create or replace function public.record_generation_step(target_request uuid,payload jsonb) returns void
language plpgsql security definer set search_path='' as $$ begin
 perform 1 from public.generation_requests where id=target_request and user_id=auth.uid() and status='running' for update;
 if not found then raise exception 'owned_running_request_required'; end if;
 if payload is null or octet_length(payload::text)>65000 or payload::text ~* '(data:image|bearer |sk-proj-|sk-[A-Za-z0-9]{20})' then raise exception 'invalid_telemetry'; end if;
 if payload->>'model' is distinct from (select config_snapshot->>'model' from public.generation_requests where id=target_request)
 or payload->'prompt'->>'model' is distinct from payload->>'model' then raise exception 'snapshot_model_required'; end if;
 if (payload->>'step')::int=2 and not exists(select 1 from public.llm_responses where request_id=target_request and step=1 and status='succeeded') then raise exception 'first_step_required'; end if;
 if jsonb_typeof(payload->'prompt') is distinct from 'object' or payload->'prompt'->>'step' is distinct from payload->>'step_name' then raise exception 'invalid_prompt'; end if;
 insert into public.llm_responses(request_id,step,step_name,model,prompt,output_text,status,http_status,error_code,
 provider_response_id,provider_request_id,input_tokens,output_tokens,duration_ms)
 values(target_request,(payload->>'step')::int,payload->>'step_name',payload->>'model',payload->'prompt',coalesce(payload->>'output_text',''),payload->>'status',
 (payload->>'http_status')::int,payload->>'error_code',payload->>'provider_response_id',payload->>'provider_request_id',
 (payload->>'input_tokens')::int,(payload->>'output_tokens')::int,(payload->>'duration_ms')::int);
end $$;
create or replace function public.finish_generation(target_request uuid,succeeded boolean,failure_code text default null) returns void
language plpgsql security definer set search_path='' as $$
declare r public.generation_requests; begin
 select * into r from public.generation_requests where id=target_request and user_id=auth.uid() for update;
 if not found then raise exception 'owned_request_required'; end if;
 if r.status<>'running' then return; end if;
 if succeeded is null then raise exception 'invalid_status'; end if;
 if succeeded and (not exists(select 1 from public.meme_images where id=r.image_id and status='ready')
 or (select count(*) from public.llm_responses where request_id=r.id and status='succeeded')<>2) then raise exception 'published_two_step_request_required'; end if;
 if failure_code is not null and failure_code !~ '^[a-z0-9_]{1,80}$' then raise exception 'invalid_error_code'; end if;
 update public.generation_requests set status=case when succeeded then 'succeeded' else 'failed' end,
 error_code=case when succeeded then null else coalesce(failure_code,'generation_failed') end,finished_at=now() where id=r.id;
end $$;
revoke all on function public.admin_set_chain_mix(jsonb),public.admin_set_signup_gate(boolean),public.begin_generation(uuid,text,text),public.record_generation_step(uuid,jsonb),public.finish_generation(uuid,boolean,text) from public,anon;
grant execute on function public.admin_set_chain_mix(jsonb),public.admin_set_signup_gate(boolean),public.begin_generation(uuid,text,text),public.record_generation_step(uuid,jsonb),public.finish_generation(uuid,boolean,text) to authenticated;

-- Admin can assign newly created models to a real chain without editing source code.
create or replace function public.admin_assign_chain_model(target_chain uuid,target_model uuid) returns void
language plpgsql security definer set search_path='' as $$ begin
 perform public.require_superadmin();
 if not exists(select 1 from public.llm_models m join public.llm_providers p on p.id=m.provider_id where m.id=target_model and m.enabled and p.enabled) then raise exception 'enabled_model_required'; end if;
 update public.prompt_chains set model_id=target_model where id=target_chain;
 if not found then raise exception 'chain_not_found'; end if;
end $$;
create or replace function public.admin_observability() returns jsonb
language plpgsql security definer set search_path='' as $$ begin
 perform public.require_superadmin();
 return jsonb_build_object('requests',(select count(*) from public.generation_requests),
 'succeeded',(select count(*) from public.generation_requests where status='succeeded'),
 'failed',(select count(*) from public.generation_requests where status='failed'),
 'running',(select count(*) from public.generation_requests where status='running'),
 'responses',(select count(*) from public.llm_responses),
 'mean_step_ms',(select round(avg(duration_ms)) from public.llm_responses),
 'input_tokens',(select sum(input_tokens) from public.llm_responses),
 'output_tokens',(select sum(output_tokens) from public.llm_responses),
 'usage_known',(select count(*) from public.llm_responses where input_tokens is not null and output_tokens is not null));
end $$;
revoke all on function public.admin_assign_chain_model(uuid,uuid),public.admin_observability() from public,anon;
grant execute on function public.admin_assign_chain_model(uuid,uuid),public.admin_observability() to authenticated;

commit;
