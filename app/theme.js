"use client";
import {useEffect,useSyncExternalStore} from "react";
let fallback="system";
const event="studio-theme-change";
function subscribe(callback){window.addEventListener("storage",callback);window.addEventListener(event,callback);return()=>{window.removeEventListener("storage",callback);window.removeEventListener(event,callback)}}
function snapshot(){try{const t=localStorage.getItem("studio-theme");return ["light","dark","system"].includes(t)?t:fallback}catch{return fallback}}
export default function Theme(){const theme=useSyncExternalStore(subscribe,snapshot,()=>"system");useEffect(()=>{document.documentElement.dataset.theme=theme},[theme]);return <label className="theme">Appearance<select aria-label="Appearance" value={theme} onChange={e=>{fallback=e.target.value;try{localStorage.setItem("studio-theme",fallback)}catch{}window.dispatchEvent(new Event(event))}}><option value="system">System</option><option value="light">Light</option><option value="dark">Dark</option></select></label>}
