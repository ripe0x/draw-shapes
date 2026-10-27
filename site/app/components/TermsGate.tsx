"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useAccount, useDisconnect } from "wagmi";
import { useTermsAcceptance } from "../lib/terms-acceptance";
import { deployment } from "../lib/deployment";

/** Clickwrap: the first time a wallet connects (and again when the Terms change) it must accept before playing. */
export function TermsGate() {
  const { address } = useAccount();
  const { disconnect } = useDisconnect();
  const { accepted, accept } = useTermsAcceptance(deployment.chainId, address);
  const [checked, setChecked] = useState(false);
  const path = usePathname();
  if (!address || accepted !== false || path?.startsWith("/terms")) return null;
  return (
    <div className="gate" role="dialog" aria-modal="true" aria-labelledby="gate-title">
      <div className="card">
        <h2 id="gate-title">Before you play</h2>
        <ul>
          <li>Every pull is random. A pull costs more than the average prize is worth, and most pulls win the smallest
            prize: expect to lose about a third of each ticket.</li>
          <li>Each Shape holds ETH that its contract pays out when you burn it. Ethereum transactions are final.</li>
          <li>ENGINE is a token with no claim on the game's ETH. Its price can fall to zero.</li>
          <li>The game's contracts have no withdraw function, but governance (a timelock with no delay at launch) can
            move the game's ETH between the registered game, the profit buyback and the ENGINE liquidity. No independent
            audit has been done.</li>
          <li>You must be 18 or older, and it is up to you to make sure playing is legal where you are.</li>
        </ul>
        <label className="check">
          <input type="checkbox" checked={checked} onChange={(e) => setChecked(e.target.checked)} />
          <span>I am 18 or older and I agree to the <Link href="/terms/" target="_blank">Terms of Use</Link>.</span>
        </label>
        <div className="row">
          <button className="btn-filled" disabled={!checked} onClick={accept}>Agree and continue</button>
          <button className="btn-outline" onClick={() => disconnect()}>Disconnect</button>
        </div>
      </div>
    </div>
  );
}
