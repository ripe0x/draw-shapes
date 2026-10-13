import type { Metadata } from "next";
import { Providers } from "./Providers";
import { getDeployment } from "./lib/deployment";
import { Nav } from "./components/Nav";
import "./globals.css";

// The deployment record is read per request, so a record written after the build is used.
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Draw Shapes",
  description: "Pull a Shape from the pool, deposit ETH, and run the pool upkeep.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  const deployment = getDeployment();
  return (
    <html lang="en">
      <body>
        <Providers deployment={deployment}>
          <Nav />
          <main className="page">
            {deployment.present ? (
              children
            ) : (
              <section>
                <h1>No deployment record</h1>
                <p className="note">
                  Chain {deployment.chainId} has no record. Set <code>NEXT_PUBLIC_DEPLOYMENT</code> to a record
                  written by <code>script/deploy.sh</code>, or <code>NEXT_PUBLIC_CHAIN_ID</code> to a chain with
                  a file in <code>deployments/</code>.
                </p>
              </section>
            )}
          </main>
        </Providers>
      </body>
    </html>
  );
}
