import {NextResponse} from "next/server";
import {createClient} from "../../../lib/supabase/server";
export async function POST(request){const url=new URL(request.url);if(request.headers.get("origin")!==url.origin)return new Response("Forbidden",{status:403});const supabase=await createClient();await supabase.auth.signOut();return NextResponse.redirect(new URL("/login",url.origin),303);}
