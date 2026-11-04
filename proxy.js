import { createServerClient } from "@supabase/ssr";
import { NextResponse } from "next/server";
export async function proxy(request) {
 let response=NextResponse.next({request});
 response.headers.set("Cache-Control","private, no-store");
 if(!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY) return response;
 const supabase=createServerClient(process.env.NEXT_PUBLIC_SUPABASE_URL,process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,{cookies:{getAll(){return request.cookies.getAll();},setAll(items,headers){items.forEach(({name,value})=>request.cookies.set(name,value));response=NextResponse.next({request});items.forEach(({name,value,options})=>response.cookies.set(name,value,options));if(headers)Object.entries(headers).forEach(([key,value])=>response.headers.set(key,value));response.headers.set("Cache-Control","private, no-store");}}});
 await supabase.auth.getUser();
 return response;
}
export const config={matcher:["/((?!_next/static|_next/image|favicon.ico).*)"]};
