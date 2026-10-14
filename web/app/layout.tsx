import type { Metadata } from "next";
import { Archivo, IBM_Plex_Mono } from "next/font/google";
import { Providers } from "./Providers";
import { getDeployment } from "./lib/deployment";
import { Nav } from "./components/Nav";
import { SiteFooter } from "./components/SiteFooter";
import "./globals.css";
import "./vault.css";
import "./reveal.css";
import "./landing.css";

const archivo = Archivo({ subsets: ["latin"], weight: ["400", "500", "700", "800"], variable: "--font-archivo" });
const ibmPlexMono = IBM_Plex_Mono({ subsets: ["latin"], weight: ["400", "500"], variable: "--font-mono" });

// The deployment record is read per request, so a record written after the build is used.
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Draw Shapes",
  description: "Pull a Shape or a Draw Pack. Each redeems for its ETH backing at face. Depositors own the pool's ordinary NAV.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  const deployment = getDeployment();
  return (
    <html lang="en">
      <body className={`${archivo.variable} ${ibmPlexMono.variable}`} suppressHydrationWarning>
        <Providers deployment={deployment}>
          <Nav />
          {deployment.present ? (
            children
          ) : (
            <main className="vault-page">
              <h1 className="vault-headline">No deployment record</h1>
              <p className="vault-note">
                Chain {deployment.chainId} has no record. Set <code>NEXT_PUBLIC_DEPLOYMENT</code> to a record written by{" "}
                <code>script/deploy.sh</code>, or <code>NEXT_PUBLIC_CHAIN_ID</code> to a chain with a file in{" "}
                <code>deployments/</code>.
              </p>
            </main>
          )}
          <SiteFooter />
        </Providers>
      </body>
    </html>
  );
}
