"use client";

import Link from "next/link";
import { ConnectButton } from "@rainbow-me/rainbowkit";

export function Nav() {
  return (
    <header className="header">
      <nav>
        <Link className="wordmark" href="/">
          Draw Shapes
        </Link>
        <Link href="/">Pull</Link>
        <Link href="/deposit">Deposit</Link>
        <Link href="/protocol">Protocol</Link>
      </nav>
      <ConnectButton showBalance={false} chainStatus="icon" />
    </header>
  );
}
