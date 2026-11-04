import {registerHooks} from 'node:module';
import assert from 'node:assert/strict';
registerHooks({resolve(specifier,context,next){
 if(specifier==='server-only')return {url:'data:text/javascript,',shortCircuit:true};
 if(specifier==='next/navigation')return {url:'data:text/javascript,'+encodeURIComponent('export function redirect(path){throw new Error("REDIRECT:"+path)}'),shortCircuit:true};
 if(specifier==='./supabase/server'&&context.parentURL?.endsWith('/lib/admin.js'))return {url:'data:text/javascript,'+encodeURIComponent('export async function createClient(){return globalThis.testAdminClient}'),shortCircuit:true};
 return next(specifier,context);
}});
const {requireAdmin}=await import('../lib/admin.js');
function client(user,allowed,error=null){return {auth:{getUser:async()=>({data:{user},error:null})},rpc:async()=>({data:allowed,error})};}
globalThis.testAdminClient=client(null,false);await assert.rejects(requireAdmin,/REDIRECT:\/login$/);
const member={id:'member',identities:[{provider:'google'}]};
globalThis.testAdminClient=client(member,false);await assert.rejects(requireAdmin,/admin_required/);
globalThis.testAdminClient=client(member,true,{message:'database unavailable'});await assert.rejects(requireAdmin,/admin_required/);
globalThis.testAdminClient=client({id:'email-only',identities:[{provider:'email'}]},true);await assert.rejects(requireAdmin,/admin_required/);
globalThis.testAdminClient=client(member,true);assert.equal((await requireAdmin()).user.id,'member');
// A newly revoked database flag must reject even with the same signed-in user.
globalThis.testAdminClient=client(member,false);await assert.rejects(requireAdmin,/admin_required/);
console.log('PASS: actual server authorization helper denies anonymous, regular, non-Google, failed-check and revoked sessions; accepts an authorized Google admin. Session/DB responses mocked.');
