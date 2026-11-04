"use client";
import {useState} from "react";
import {createClient} from "../../lib/supabase/browser";
export default function SignIn(){const [busy,setBusy]=useState(false),[error,setError]=useState("");return <><button disabled={busy} onClick={async()=>{setBusy(true);setError("");try{const {error}=await createClient().auth.signInWithOAuth({provider:"google",options:{redirectTo:`${window.location.origin}/auth/callback`}});if(error)throw error;}catch{setError("Could not start sign-in. Please try again.");setBusy(false);}}}>{busy?"Connecting…":"Continue with Google ↗"}</button>{error&&<p role="alert">{error}</p>}</>;}
