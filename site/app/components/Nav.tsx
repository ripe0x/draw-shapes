"use client";

import Link from "next/link";
import { useAccount, useConnect, useDisconnect } from "wagmi";

export function Nav() {
  const { address } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  return (
    <header className="nav">
      <Link href="/" className="brand">Draw Shapes</Link>
      <nav>
        <Link href="/">Play</Link>
        <Link href="/genesis/">Genesis</Link>
        <Link href="/claim/">Claim</Link>
        <Link href="/convert/">Convert</Link>
        <Link href="/stats/">Stats</Link>
        <Link href="/terms/">Terms</Link>
      </nav>
      {address ? (
        <button className="btn-outline" onClick={() => disconnect()}>
          {address.slice(0, 6)}…{address.slice(-4)}
        </button>
      ) : (
        <button className="btn-filled" onClick={() => connectors[0] && connect({ connector: connectors[0] })}>
          Connect
        </button>
      )}
    </header>
  );
}
