import {NextResponse} from "next/server";
import {createClient} from "../../../lib/supabase/server";
export async function GET(request){const url=new URL(request.url),code=url.searchParams.get("code");if(!code)return NextResponse.redirect(new URL("/login?error=oauth",url.origin));const supabase=await createClient();const {error}=await supabase.auth.exchangeCodeForSession(code);return NextResponse.redirect(new URL(error?"/login?error=oauth":"/studio",url.origin));}
