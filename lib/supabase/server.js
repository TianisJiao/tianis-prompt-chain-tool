import "server-only";
import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";
export async function createClient() {
 const jar = await cookies();
 return createServerClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY, {cookies:{getAll(){return jar.getAll();},setAll(items){try{items.forEach(({name,value,options})=>jar.set(name,value,options));}catch{/* Proxy refreshes cookies for server pages. */}}}});
}
