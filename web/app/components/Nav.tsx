"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { WalletMenu } from "./WalletMenu";

const LINKS = [
  ["/pull", "Pull"],
  ["/deposit", "Deposit"],
  ["/sponsor", "Sponsor"],
  ["/protocol", "Protocol"],
] as const;

export function Nav() {
  const path = usePathname();
  return (
    <header className="site-header">
      <div className="site-header-inner">
        <div className="site-nav-group">
          <Link className="site-wordmark" href="/">
            Draw
          </Link>
          <div className="site-nav-links">
            {LINKS.map(([href, label]) => (
              <Link key={href} className="site-nav-link" href={href} aria-current={path === href ? "page" : undefined}>
                {label}
              </Link>
            ))}
          </div>
        </div>
        <WalletMenu />
      </div>
    </header>
  );
}
