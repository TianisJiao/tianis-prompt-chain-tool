import Link from "next/link";
import {requireAdmin} from "../../lib/admin";
export const dynamic="force-dynamic";
export default async function Layout({children}){const {user}=await requireAdmin();return <div className="shell"><header><Link href="/studio" className="wordmark">NYC SIDE<br/>QUESTS ✳</Link><nav><Link href="/studio">Your chains</Link><Link href="/studio/runs">Generated works</Link><a href="https://tianis-humor-admin.vercel.app">Editorial office ↗</a></nav><form method="post" action="/auth/signout"><button className="quiet">Sign out</button></form></header><main>{children}</main><footer><span>THE CHAIN STUDIO / VOL. 08</span><span>Signed in as {user.email}</span></footer></div>}
