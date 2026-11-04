"use client";
export default function Error({reset}){return <section className="panel"><h1>This page couldn’t load.</h1><p>Check the Week 8 database migration and your administrator access.</p><button onClick={reset}>Try again</button></section>}
