"use client";

import { useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { erc721Abi } from "viem";
import { sponsorshipAbi } from "../lib/abi/sponsorship";
import { duration, eth, pct, short, utc } from "../lib/format";
import { useChainTime, useSponsorship, useTreasury, type SponsorshipData } from "../lib/engine";
import { oneInFromWeight, useFwaTotalWeight, usePool } from "../lib/pool";
import { useDeployment } from "../Providers";
import { Eth, Kv, Stat } from "../components/Measure";
import { TxButton, TxLine, useTx } from "../components/Tx";

function stateOf(s: SponsorshipData): string {
  if (s.listingId === 0n) return "Unstaked";
  if (s.won) return "Won by a player";
  if (s.reclaimed) return "Reclaimed";
  if (s.completed) return "Completed (cap reached)";
  return s.active ? "Active" : "Listed, inactive";
}

function SponsorActions({ s }: { s: SponsorshipData }) {
  const dep = useDeployment();
  const { address } = useAccount();
  const now = useChainTime().data;
  const pool = usePool().data;
  const stakeTx = useTx();
  const approveTx = useTx();
  const claimTx = useTx();
  const reclaimTx = useTx();
  const releaseTx = useTx();
  const [tokenIdText, setTokenIdText] = useState("");

  const target = { chainId: dep.chainId, address: dep.sponsorship!, abi: sponsorshipAbi } as const;
  const isSponsor = !!address && address.toLowerCase() === s.sponsor.toLowerCase();
  const tokenId = /^\d+$/.test(tokenIdText.trim()) ? BigInt(tokenIdText.trim()) : undefined;

  // Ownership check for the token the sponsor wants to stake.
  const ownerOf = useReadContract({
    chainId: dep.chainId,
    address: s.collection,
    abi: erc721Abi,
    functionName: "ownerOf",
    args: tokenId !== undefined ? [tokenId] : undefined,
    query: { enabled: tokenId !== undefined },
  });
  const ownsToken = ownerOf.data?.toLowerCase() === address?.toLowerCase();
  const owed = s.paid - s.claimed;
  const canReclaim = isSponsor && !s.won && !s.reclaimed && !s.completed && s.listingId !== 0n && now !== undefined && now >= s.reclaimAfter;
  // `release()` is permissionless only when the staked NFT is unlisted: the pool entry is gone
  // (exported) or held with a zero notional after a refunded delivery. While it is actively listed,
  // release reverts, so the button is hidden.
  const entry = pool?.foreign?.find((f) => f.listingId === s.listingId);
  const unlisted = s.listingId !== 0n && (entry === undefined || entry.notional === 0n);
  const canRelease = unlisted && !s.won;

  return (
    <div className="card">
      <h3 className="vault-h2">Actions</h3>
      {isSponsor && s.listingId === 0n && (
        <>
          <p className="vault-note">
            Approve this contract for your {short(s.collection)} token, then stake it. It lists on the board at{" "}
            {eth(s.listPriceWei)} ETH from the stake.
          </p>
          <div className="field-row">
            <input type="text" inputMode="numeric" placeholder="Wrapped Cryptopunk token id" aria-label="Token id" value={tokenIdText} onChange={(e) => setTokenIdText(e.target.value)} />
          </div>
          {tokenId !== undefined && !ownerOf.isPending && !ownsToken && <p className="error-line">This wallet does not own token #{tokenId.toString()}.</p>}
          <div className="row-actions">
            <TxButton
              tx={approveTx}
              label="Approve"
              outline
              disabled={tokenId === undefined || !ownsToken}
              onClick={() => void approveTx.run(() => approveTx.write({ chainId: dep.chainId, address: s.collection, abi: erc721Abi, functionName: "approve", args: [dep.sponsorship!, tokenId!] }))}
            />
            <TxButton
              tx={stakeTx}
              label="Stake"
              disabled={tokenId === undefined || !ownsToken}
              onClick={() => void stakeTx.run(() => stakeTx.write({ ...target, functionName: "stake", args: [tokenId!] }))}
            />
          </div>
          <TxLine tx={approveTx} />
          <TxLine tx={stakeTx} />
        </>
      )}

      {isSponsor && s.listingId !== 0n && (
        <>
          <div className="row-actions">
            <TxButton tx={claimTx} label="Claim" disabled={owed === 0n} onClick={() => void claimTx.run(() => claimTx.write({ ...target, functionName: "claim" }))} />
            <TxButton tx={reclaimTx} label="Reclaim NFT" outline disabled={!canReclaim} onClick={() => void reclaimTx.run(() => reclaimTx.write({ ...target, functionName: "reclaim" }))} />
          </div>
          {!canReclaim && !s.won && !s.reclaimed && !s.completed && (
            <p className="vault-note">
              Reclaim is allowed from {utc(s.reclaimAfter)} while the prize is unwon and short of the cap, and only when no draw is pending.
            </p>
          )}
          <TxLine tx={claimTx} />
          <TxLine tx={reclaimTx} />
        </>
      )}

      {canRelease && (
        <>
          <p className="vault-note">If a refunded delivery or the pool export left the NFT unlisted, anyone can send it to its owner.</p>
          <TxButton tx={releaseTx} label="Release NFT" outline onClick={() => void releaseTx.run(() => releaseTx.write({ ...target, functionName: "release" }))} />
          <TxLine tx={releaseTx} />
        </>
      )}

      {!isSponsor && !canRelease && <p className="vault-note">Connect the sponsor wallet to stake, claim or reclaim.</p>}
    </div>
  );
}

/** `/sponsor`: a single sponsored-prize deal. Shows "no sponsorship is open" when the record has no
 *  sponsorship address. */
export default function SponsorPage() {
  const dep = useDeployment();
  const s = useSponsorship().data;
  const t = useTreasury().data;
  const now = useChainTime().data;
  const totalWeight = useFwaTotalWeight().data;

  if (!dep.sponsorship) {
    return (
      <main className="vault-page">
        <section className="vault-hero">
          <h1 className="vault-headline">Sponsor</h1>
          <p className="vault-lede">No sponsorship is open.</p>
        </section>
      </main>
    );
  }

  const odds = s && s.active ? oneInFromWeight(s.listPriceWei, totalWeight) : undefined;

  return (
    <main className="vault-page">
      <section className="vault-hero">
        <h1 className="vault-headline">Sponsored prize</h1>
        <p className="vault-lede">
          One sponsor lends an NFT as a headline prize, listed on the board at a published price. The sponsor is paid up to a
          cap from the treasury&apos;s trading receipts while the prize stays unwon. The game never owes the NFT&apos;s market value.
        </p>
      </section>

      {!s ? (
        <p className="vault-note">Reading the sponsorship.</p>
      ) : (
        <>
          <div className="stat-grid">
            <Stat label="State" value={stateOf(s)} />
            <Stat label="List price" value={<Eth wei={s.listPriceWei} digits={3} />} sub={odds ? `odds ${odds} draws` : s.active ? "computing odds" : "not listed"} />
            <Stat label="Paid / cap" value={<>{eth(s.paid, 3)} / {eth(s.capWei, 2)}</>} sub="ETH to the sponsor" />
            <Stat label="Owed to the sponsor" value={<Eth wei={s.owed} digits={3} />} />
          </div>

          <section className="vault-section two-col">
            <div className="card">
              <h3 className="vault-h2">Terms</h3>
              <Kv label="Sponsor" value={short(s.sponsor)} />
              <Kv label="Collection" value={short(s.collection)} />
              <Kv label="List price" value={<Eth wei={s.listPriceWei} digits={4} />} />
              <Kv label="Payment cap" value={<Eth wei={s.capWei} digits={4} />} />
              <Kv label="Reclaim delay" value={duration(s.reclaimDelay)} />
              <Kv label="Sponsor share of trading receipts" value={t ? pct(t.sponsorShareBps) : "-"} />
              <Kv label="Reclaim allowed at" value={s.stakedAt === 0 ? "After stake" : utc(s.reclaimAfter)} />
              {now !== undefined && s.stakedAt !== 0 && s.reclaimAfter > now && (
                <Kv label="Reclaim in" value={duration(s.reclaimAfter - now)} />
              )}
              <h3 className="vault-h2" style={{ marginTop: 18 }}>Payments</h3>
              <Kv label="Paid in" value={<Eth wei={s.paid} digits={4} />} />
              <Kv label="Claimed" value={<Eth wei={s.claimed} digits={4} />} />
              <Kv label="Claimable now" value={<Eth wei={s.paid - s.claimed} digits={4} />} strong />
              {s.listingId !== 0n && <Kv label="FWA listing id" value={s.listingId.toString()} />}
            </div>
            <SponsorActions s={s} />
          </section>
        </>
      )}
    </main>
  );
}
