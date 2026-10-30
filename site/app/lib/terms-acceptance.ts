"use client";

import { useCallback, useEffect, useState } from "react";
import type { Address } from "viem";
import { TERMS_VERSION } from "./legal";

const key = (chainId: number, owner: Address) => `draw-terms-${chainId}-${owner.toLowerCase()}`;

/** Whether this wallet accepted the current Terms in this browser; `null` until storage is read. */
export function useTermsAcceptance(chainId: number, owner?: Address) {
  const [accepted, setAccepted] = useState<boolean | null>(null);
  useEffect(() => {
    if (!owner) return setAccepted(null);
    try {
      const v = JSON.parse(localStorage.getItem(key(chainId, owner)) ?? "null") as { version?: string } | null;
      setAccepted(v?.version === TERMS_VERSION);
    } catch {
      setAccepted(false);
    }
  }, [chainId, owner]);
  const accept = useCallback(() => {
    if (!owner) return;
    try {
      localStorage.setItem(key(chainId, owner), JSON.stringify({ version: TERMS_VERSION, at: new Date().toISOString() }));
    } catch {
      // storage unavailable: acceptance lasts for this page view
    }
    setAccepted(true);
  }, [chainId, owner]);
  return { accepted, accept };
}
