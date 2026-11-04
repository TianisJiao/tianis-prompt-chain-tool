-- Apply to the SAME shared database after Week 7. Additive and rerunnable.
begin;
create table if not exists public.studio_chains (
 id uuid primary key default gen_random_uuid(),name text not null check(length(trim(name)) between 1 and 80),
 description text not null default '' check(length(description)<=500),revision integer not null default 1,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.studio_steps (
 id uuid primary key default gen_random_uuid(),chain_id uuid not null references public.studio_chains on delete cascade,
 position integer not null check(position between 1 and 6),name text not null check(length(trim(name)) between 1 and 80),
 instructions text not null check(length(trim(instructions)) between 1 and 6000),
 input_kind text not null check(input_kind in ('image','original','previous')),
 model_id uuid not null references public.llm_models on delete restrict,unique(chain_id,position)
);
create table if not exists public.studio_runs (
 id uuid primary key default gen_random_uuid(),chain_id uuid references public.studio_chains on delete set null,
 user_id uuid not null references auth.users on delete cascade,snapshot jsonb not null,
 brief text not null check(length(brief)<=4000),image_path text unique,
 status text not null default 'running' check(status in ('running','succeeded','failed')),
 next_step integer not null default 0 check(next_step between 0 and 6),lease_id uuid,
 lease_started_at timestamptz,output_text text not null default '' check(length(output_text)<=16000),
 error_code text,created_at timestamptz not null default now(),finished_at timestamptz
);
create index if not exists studio_runs_chain on public.studio_runs(chain_id,created_at desc,id);
create table if not exists public.studio_outputs (
 id uuid primary key default gen_random_uuid(),run_id uuid not null references public.studio_runs on delete cascade,
 position integer not null check(position between 1 and 6),step_name text not null,model text not null,
 instructions text not null,input_text text not null, image_attached boolean not null,
 output_text text not null check(length(output_text)<=16000),status text not null check(status in ('succeeded','failed')),
 error_code text,input_tokens integer check(input_tokens>=0),output_tokens integer check(output_tokens>=0),
 provider_response_id text check(length(provider_response_id)<=200),duration_ms integer not null check(duration_ms between 0 and 300000),
 created_at timestamptz not null default now(),unique(run_id,position)
);
do $$ declare t text; begin
 foreach t in array array['studio_chains','studio_steps','studio_runs','studio_outputs'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant select on public.%I to authenticated',t);
 execute format('drop policy if exists "Studio admin reads" on public.%I',t);
 execute format('create policy "Studio admin reads" on public.%I for select to authenticated using ((select public.is_superadmin()))',t);
 end loop;
end $$;
-- One atomic document save handles create/update/delete/reorder of steps.
-- A revision prevents one editor tab overwriting another's newer work.
create or replace function public.studio_save_chain(document jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare cid uuid;rev integer;item jsonb;pos integer:=0;begin
 perform public.require_superadmin();
 if document is null or octet_length(document::text)>220000 or jsonb_typeof(document->'steps') is distinct from 'array'
 or jsonb_array_length(document->'steps')>6 or document->>'name' is null or document->>'description' is null then raise exception 'invalid_document';end if;
 if document->>'id' is null then
 insert into public.studio_chains(name,description) values(trim(document->>'name'),document->>'description') returning id,revision into cid,rev;
 else
 cid:=(document->>'id')::uuid;
 select revision into rev from public.studio_chains where id=cid for update;
 if not found then raise exception 'chain_missing';end if;
 if rev is distinct from (document->>'revision')::integer then raise exception 'revision_conflict';end if;
 update public.studio_chains set name=trim(document->>'name'),description=document->>'description',revision=revision+1,updated_at=now() where id=cid returning revision into rev;
 end if;
 for item in select value from jsonb_array_elements(document->'steps') loop
 if not exists(select 1 from public.llm_models m join public.llm_providers p on p.id=m.provider_id where m.id=(item->>'model_id')::uuid and m.enabled and p.enabled and p.adapter='openai_responses') then raise exception 'enabled_model_required';end if;
 if exists(select 1 from public.studio_steps where id=(item->>'id')::uuid and chain_id<>cid) then raise exception 'foreign_step_id';end if;
 end loop;
 delete from public.studio_steps where chain_id=cid;
 for item in select value from jsonb_array_elements(document->'steps') loop
 pos:=pos+1;
 insert into public.studio_steps(id,chain_id,position,name,instructions,input_kind,model_id)
 values((item->>'id')::uuid,cid,pos,trim(item->>'name'),item->>'instructions',item->>'input_kind',(item->>'model_id')::uuid);
 end loop;
 return jsonb_build_object('id',cid,'revision',rev);
end $$;
create or replace function public.studio_delete_chain(target uuid,expected_revision integer) returns void
language plpgsql security definer set search_path='' as $$ declare rev integer;begin
 perform public.require_superadmin();select revision into rev from public.studio_chains where id=target for update;
 if not found then raise exception 'chain_missing';end if;
 if rev is distinct from expected_revision then raise exception 'revision_conflict';end if;
 delete from public.studio_chains where id=target;
end $$;
create or replace function public.studio_start_run(target uuid,brief text,extension text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.studio_chains;steps jsonb;rid uuid:=gen_random_uuid();path text;begin
 perform public.require_superadmin();
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,8));
 if (select count(*) from public.studio_runs where user_id=auth.uid() and created_at >= date_trunc('day',now() at time zone 'UTC') at time zone 'UTC')>=10 then raise exception 'daily_run_limit';end if;
 if exists(select 1 from public.studio_runs where user_id=auth.uid() and lease_id is not null and lease_started_at>now()-interval '2 minutes') then raise exception 'step_in_flight';end if;
 select * into c from public.studio_chains where id=target for update;
 if not found then raise exception 'chain_missing';end if;
 if extension is not null and extension not in ('jpg','png','webp') then raise exception 'invalid_image';end if;
 if brief is null or length(brief)>4000 then raise exception 'invalid_brief';end if;
 if not exists(select 1 from public.studio_steps where chain_id=target) then raise exception 'add_a_step_first';end if;
 if exists(select 1 from public.studio_steps s join public.llm_models m on m.id=s.model_id join public.llm_providers p on p.id=m.provider_id where s.chain_id=target and(not m.enabled or not p.enabled or p.adapter<>'openai_responses')) then raise exception 'enabled_model_required';end if;
 if exists(select 1 from public.studio_steps where chain_id=target and input_kind='image') and extension is null then raise exception 'image_required';end if;
 if length(trim(brief))=0 and extension is null then raise exception 'brief_or_image_required';end if;
 select jsonb_agg(jsonb_build_object('id',s.id,'position',s.position,'name',s.name,'instructions',s.instructions,'input_kind',s.input_kind,'model',m.model_id,'model_name',m.name) order by s.position) into steps from public.studio_steps s join public.llm_models m on m.id=s.model_id where s.chain_id=target;
 if extension is not null then path:=auth.uid()::text||'/'||rid::text||'.'||extension;end if;
 insert into public.studio_runs(id,chain_id,user_id,snapshot,brief,image_path) values(rid,target,auth.uid(),jsonb_build_object('id',c.id,'name',c.name,'description',c.description,'revision',c.revision,'steps',steps),brief,path);
 return jsonb_build_object('id',rid,'image_path',path);
end $$;
create or replace function public.studio_fail_upload(target uuid) returns void
language plpgsql security definer set search_path='' as $$ begin
 perform public.require_superadmin();update public.studio_runs set status='failed',error_code='upload_failed',finished_at=now() where id=target and user_id=auth.uid() and status='running' and next_step=0 and lease_id is null;
end $$;
create or replace function public.studio_claim_step(target uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.studio_runs;lease uuid:=gen_random_uuid();begin
 perform public.require_superadmin();select * into r from public.studio_runs where id=target and user_id=auth.uid() for update;
 if not found then raise exception 'owned_run_required';end if;
 if r.status<>'running' then return jsonb_build_object('done',true);end if;
 if r.lease_id is not null then raise exception 'step_in_flight_or_unconfirmed';end if;
 if r.image_path is not null and not exists(select 1 from storage.objects where bucket_id='studio-inputs' and name=r.image_path) then raise exception 'image_upload_required';end if;
 update public.studio_runs set lease_id=lease,lease_started_at=now() where id=r.id;
 return jsonb_build_object('lease',lease,'step',r.snapshot->'steps'->r.next_step,'brief',r.brief,'previous',case when r.next_step>0 then r.output_text else null end,'image_path',r.image_path,'last',r.next_step+1=jsonb_array_length(r.snapshot->'steps'));
end $$;
create or replace function public.studio_complete_step(target uuid,lease uuid,payload jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare r public.studio_runs;s jsonb;ok boolean;expected_input text;begin
 perform public.require_superadmin();select * into r from public.studio_runs where id=target and user_id=auth.uid() for update;
 if not found or r.status<>'running' or r.lease_id is distinct from lease or lease is null then raise exception 'valid_lease_required';end if;
 if payload is null or octet_length(payload::text)>200000 or payload->>'status' not in ('succeeded','failed') or payload->>'status' is null then raise exception 'invalid_result';end if;
 s:=r.snapshot->'steps'->r.next_step;ok:=payload->>'status'='succeeded';
 expected_input:=case when s->>'input_kind'='original' or r.next_step=0 then r.brief else r.output_text end;
 if expected_input='' then expected_input:='Please work with the provided image.';end if;
 if ok and(length(trim(coalesce(payload->>'output_text','')))=0 or payload->>'model' is distinct from s->>'model' or payload->>'instructions' is distinct from s->>'instructions' or payload->>'input_text' is distinct from expected_input or (payload->>'image_attached')::boolean is distinct from (s->>'input_kind'='image')) then raise exception 'snapshot_required';end if;
 if payload->>'error_code' is not null and (payload->>'error_code') !~ '^[a-z0-9_]{1,80}$' then raise exception 'invalid_error';end if;
 insert into public.studio_outputs(run_id,position,step_name,model,instructions,input_text,image_attached,output_text,status,error_code,input_tokens,output_tokens,provider_response_id,duration_ms)
 values(r.id,r.next_step+1,s->>'name',s->>'model',s->>'instructions',expected_input,s->>'input_kind'='image',coalesce(payload->>'output_text',''),payload->>'status',payload->>'error_code',(payload->>'input_tokens')::integer,(payload->>'output_tokens')::integer,payload->>'provider_response_id',(payload->>'duration_ms')::integer);
 update public.studio_runs set next_step=case when ok then next_step+1 else next_step end,output_text=case when ok then payload->>'output_text' else output_text end,lease_id=null,
 status=case when not ok then 'failed' when r.next_step+1=jsonb_array_length(r.snapshot->'steps') then 'succeeded' else 'running' end,
 error_code=payload->>'error_code',finished_at=case when not ok or r.next_step+1=jsonb_array_length(r.snapshot->'steps') then now() else null end where id=r.id;
end $$;
revoke all on function public.studio_save_chain(jsonb),public.studio_delete_chain(uuid,integer),public.studio_start_run(uuid,text,text),public.studio_fail_upload(uuid),public.studio_claim_step(uuid),public.studio_complete_step(uuid,uuid,jsonb) from public,anon;
grant execute on function public.studio_save_chain(jsonb),public.studio_delete_chain(uuid,integer),public.studio_start_run(uuid,text,text),public.studio_fail_upload(uuid),public.studio_claim_step(uuid),public.studio_complete_step(uuid,uuid,jsonb) to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('studio-inputs','studio-inputs',false,2097152,array['image/png','image/jpeg','image/webp']) on conflict(id) do nothing;
drop policy if exists "Studio admins read inputs" on storage.objects;
create policy "Studio admins read inputs" on storage.objects for select to authenticated using(bucket_id='studio-inputs' and (select public.is_superadmin()));
drop policy if exists "Studio admins upload reserved inputs" on storage.objects;
create policy "Studio admins upload reserved inputs" on storage.objects for insert to authenticated with check(bucket_id='studio-inputs' and (select public.is_superadmin()) and exists(select 1 from public.studio_runs where image_path=name and user_id=(select auth.uid()) and status='running' and next_step=0 and lease_id is null));
commit;
