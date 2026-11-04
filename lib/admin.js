import "server-only";
import { redirect } from "next/navigation";
import { createClient } from "./supabase/server";
export async function requireAdmin(){
 const supabase=await createClient();
 const {data,error}=await supabase.auth.getUser();
 if(error || !data.user) redirect("/login");
 const google=data.user.identities?.some(identity=>identity.provider === "google");
 const {data:allowed,error:checkError}=await supabase.rpc("is_superadmin");
 if(!google || checkError || allowed !== true) redirect("/login?error=admin_required");
 return {supabase,user:data.user};
}
export function must(result){if(result.error)throw new Error("The admin data could not load. Check the database migration and your administrator access, then retry.");return result.data;}
export function pageNumber(value){const n=Number(value);return Number.isInteger(n)&&n>0?Math.min(n,100000):1;}
export function stamp(value){return new Date(value).toLocaleString("en-US",{timeZone:"America/New_York",month:"short",day:"numeric",year:"numeric",hour:"numeric",minute:"2-digit"});}
