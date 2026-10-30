import type { Metadata } from "next";
import "./globals.css";
import { Providers } from "./Providers";
import { Nav } from "./components/Nav";
import { TermsGate } from "./components/TermsGate";
import { OPERATOR, CONTACT } from "./lib/legal";

export const metadata: Metadata = {
  title: "Draw Shapes",
  description: "Pull Shapes from a verifiably random board on Ethereum. Earn ENGINE during genesis.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Nav />
          <main>{children}</main>
          <TermsGate />
          <footer className="foot">
            Operated by {OPERATOR}
            {CONTACT ? <> · {CONTACT}</> : null} · No independent audit has been done.
          </footer>
        </Providers>
      </body>
    </html>
  );
}
