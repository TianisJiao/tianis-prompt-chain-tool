import "./globals.css";
import Theme from "./theme";
export const metadata={title:"NYC Side Quests · Chain Studio",description:"An editorial workbench for building and running prompt chains."};
export default function Layout({children}){return <html lang="en" suppressHydrationWarning><body><Theme/>{children}</body></html>}
