import {PGlite} from '@electric-sql/pglite';
import {readFileSync} from 'node:fs';import assert from 'node:assert/strict';
const db=new PGlite();await db.exec(`create role anon;create role authenticated;create schema auth;create schema storage;
create table auth.users(id uuid primary key,email text,created_at timestamptz default now());create table auth.identities(user_id uuid references auth.users(id),provider text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
grant usage on schema auth,storage to anon,authenticated;grant execute on function auth.uid() to anon,authenticated;
create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text);
alter table storage.objects enable row level security;grant select,insert,delete on storage.objects to authenticated;create function storage.foldername(text) returns text[] language sql as $$ select string_to_array($1,'/') $$;`);
for(const f of ['setup','week3-auth','week4-memes','week6-admin','week7-observability'])await db.exec(readFileSync(new URL('./fixtures/'+f+'.sql',import.meta.url),'utf8'));
const a='00000000-0000-4000-8000-000000000001',b='00000000-0000-4000-8000-000000000002',c='00000000-0000-4000-8000-000000000003';
await db.query("insert into auth.users(id,email) values($1,'a@example.test'),($2,'b@example.test'),($3,'c@example.test')",[a,b,c]);await db.query("insert into auth.identities values($1,'google'),($2,'google'),($3,'email')",[a,b,c]);await db.query('update public.profiles set is_superadmin=true where id in($1,$2)',[a,c]);
const migration=readFileSync(new URL('../supabase/week8-studio.sql',import.meta.url),'utf8');await db.exec(migration);await db.exec(migration);
async function role(uid,kind='authenticated'){await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[uid??'']);await db.exec('set role '+kind)}
async function denied(q,p=[]){await assert.rejects(()=>db.query(q,p))}
const rpc=async(name,args=[])=>(await db.query(name,args)).rows[0]?.v;
await role(a);const model=(await db.query('select id from public.llm_models limit 1')).rows[0].id;const step=(id,name,input='previous')=>({id,name,input_kind:input,instructions:'Make something from this input.',model_id:model});const s1=step('10000000-0000-4000-8000-000000000001','Describe','image'),s2=step('10000000-0000-4000-8000-000000000002','Angle'),s3=step('10000000-0000-4000-8000-000000000003','Captions');
const save=async d=>rpc('select public.studio_save_chain($1::jsonb) v',[JSON.stringify(d)]);let draft={name:'Sequence',description:'Test',steps:[s1,s2,s3]};const initial=await save(draft);draft={...draft,...initial};
assert.equal((await db.query('select count(*)::int n from public.studio_steps')).rows[0].n,3);
const edited=await save({...draft,name:'Edited',steps:[s3,s1]});await denied('select public.studio_save_chain($1::jsonb)',[JSON.stringify(draft)]);draft={...draft,...edited,steps:[s3,s1]};
assert.deepEqual((await db.query('select name from public.studio_steps order by position')).rows.map(r=>r.name),['Captions','Describe']);
await denied("update public.studio_chains set name='Bypass'");
await denied("select public.studio_start_run($1,'Brief',null)",[draft.id]);
const run=await rpc("select public.studio_start_run($1,'Brief','png') v",[draft.id]);await denied('select public.studio_claim_step($1)',[run.id]);
await db.query("insert into storage.objects(bucket_id,name) values('studio-inputs',$1)",[run.image_path]);
const job=await rpc('select public.studio_claim_step($1) v',[run.id]);assert.equal(job.step.name,'Captions');await denied('select public.studio_claim_step($1)',[run.id]);
const event=(job,text)=>({status:'succeeded',model:job.step.model,instructions:job.step.instructions,input_text:job.previous??job.brief,image_attached:job.step.input_kind==='image',output_text:text,duration_ms:100,input_tokens:20,output_tokens:5});
await denied('select public.studio_complete_step($1,$2,$3::jsonb)',[run.id,a,JSON.stringify(event(job,'One'))]);
await rpc('select public.studio_complete_step($1,$2,$3::jsonb) v',[run.id,job.lease,JSON.stringify(event(job,'One'))]);
await save({...draft,revision:edited.revision,steps:[s2]}); // Future runs change; the current snapshot must not.
const job2=await rpc('select public.studio_claim_step($1) v',[run.id]);assert.equal(job2.step.name,'Describe');assert.equal(job2.previous,'One');
await rpc('select public.studio_complete_step($1,$2,$3::jsonb) v',[run.id,job2.lease,JSON.stringify(event(job2,'Final'))]);
assert.equal((await db.query('select status from public.studio_runs where id=$1',[run.id])).rows[0].status,'succeeded');assert.equal((await db.query('select count(*)::int n from public.studio_outputs')).rows[0].n,2);
await role(b);for(const t of ['studio_chains','studio_steps','studio_runs','studio_outputs'])assert.equal((await db.query('select count(*)::int n from public.'+t)).rows[0].n,0);await denied('select public.studio_save_chain($1::jsonb)',[JSON.stringify({name:'Bad',description:'',steps:[]})]);await denied('select public.studio_claim_step($1)',[run.id]);await denied("insert into storage.objects(bucket_id,name) values('studio-inputs','bad')");
await role(c);assert.equal((await db.query('select count(*)::int n from public.studio_chains')).rows[0].n,0);await denied('select public.studio_delete_chain($1,3)',[draft.id]);
await role(null,'anon');await denied('select * from public.studio_chains');await denied("select public.studio_start_run($1,'x',null)",[draft.id]);
await role(a);const second=await rpc("select public.studio_start_run($1,'New brief',null) v",[draft.id]);const j=await rpc('select public.studio_claim_step($1) v',[second.id]);await rpc('select public.studio_complete_step($1,$2,$3::jsonb) v',[second.id,j.lease,JSON.stringify({status:'failed',output_text:'',error_code:'provider_rate_or_quota',duration_ms:2})]);assert.equal((await db.query('select status from public.studio_runs where id=$1',[second.id])).rows[0].status,'failed');
await denied('select public.studio_delete_chain($1,1)',[draft.id]);await db.query('select public.studio_delete_chain($1,3)',[draft.id]);assert.equal((await db.query('select count(*)::int n from public.studio_steps')).rows[0].n,0);assert.equal((await db.query('select count(*)::int n from public.studio_runs where chain_id is null')).rows[0].n,2);assert.equal((await db.query("select snapshot->>'name' n from public.studio_runs where id=$1",[run.id])).rows[0].n,'Edited');
await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub','',false)");await db.query('update public.profiles set is_superadmin=false where id=$1',[a]);await role(a);await denied('select public.studio_save_chain($1::jsonb)',[JSON.stringify({name:'Revoked',description:'',steps:[]})]);
await db.close();console.log('PASS: actual additive migration reruns; chain/step CRUD + reorder + revision conflict; immutable per-run snapshots; image reservation; paid-call lease; ordered success/failure persistence; Google-admin RLS and immediate revocation; chain deletion preserves generated works. Local PGlite only.');
