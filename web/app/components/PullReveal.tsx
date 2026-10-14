"use client";

import { useEffect, useState } from "react";
import { useListedItems, useTokenImages } from "../lib/art";
import { eth } from "../lib/format";
import { TRACK } from "../lib/pool";
import { ACQ, type Batch, type Card } from "../lib/pulls";
import { Eth } from "./Measure";
import { TokenArt } from "./TokenArt";

/** Steps of one pull from the wallet to the delivered item. */
export const PULL_STEPS = ["Sent", "Waiting for randomness", "Delivering"] as const;

/** Index into `PULL_STEPS` for an unresolved FWA acquisition status. */
function stepOf(status: number): number {
  if (status === ACQ.None) return 0;
  if (status === ACQ.Pending) return 1;
  return 2;
}

/** A dot per step joined by a rule, the current step named below. Steps before `active` are done. */
export function PackProgress({ steps, active, label }: { steps: readonly string[]; active: number; label?: string }) {
  return (
    <div className="pack-progress">
      <ol className="pack-steps" style={{ "--steps": steps.length } as React.CSSProperties}>
        {steps.map((name, i) => (
          <li key={name} className={i < active ? "is-done" : i === active ? "is-active" : undefined} tabIndex={0} aria-label={name}>
            <span className="pack-step-dot" />
            <span className="pack-step-tip" role="tooltip">
              {name}
            </span>
          </li>
        ))}
      </ol>
      <p className="pack-step-current">{label ?? steps[active]}</p>
    </div>
  );
}

const REEL_FRAMES = 8;

/** Art of up to eight listed items, rotated by `seed` so the cards of a batch differ. */
function useReelFrames(seed: number): string[] {
  const listed = useListedItems().data ?? [];
  const images = useTokenImages(listed.slice(0, REEL_FRAMES));
  if (images.length < 2) return [];
  return Array.from({ length: REEL_FRAMES }, (_, j) => images[(seed + j * 3) % images.length]);
}

/** Hard-cut strip of listed items' art for a card still being drawn. Motion is `.pack-reel` in
 *  reveal.css and stops under `prefers-reduced-motion`. */
function DrawReel({ frames }: { frames: string[] }) {
  return (
    <div className="pack-reel" style={{ "--frames": frames.length } as React.CSSProperties} aria-hidden>
      {frames.map((src, j) => (
        <div key={j} className="pack-reel-frame">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={src} alt="" draggable={false} />
        </div>
      ))}
    </div>
  );
}

/** Card back: the "Draw" wordmark over the pattern in `.pack-face`, or with `reel` the draw reel
 *  once listed art is loaded. */
export function PackBack({ reel, children }: { reel?: number; children?: React.ReactNode }) {
  const frames = useReelFrames(reel ?? 0);
  const playing = reel !== undefined && frames.length > 0;
  return (
    <div className={playing ? "pack-face pack-face-reel" : "pack-face"}>
      {playing ? (
        <DrawReel frames={frames} />
      ) : (
        <span className="pack-wordmark" aria-hidden>
          Draw
        </span>
      )}
      {children}
    </div>
  );
}

/** Mounts showing `back`, then rotates to `front` on the next frame so the flip plays. */
function PackFlip({ back, front }: { back: React.ReactNode; front: React.ReactNode }) {
  const [flipped, setFlipped] = useState(false);
  useEffect(() => {
    const id = requestAnimationFrame(() => setFlipped(true));
    return () => cancelAnimationFrame(id);
  }, []);
  return (
    <div className="pack-flip">
      <div className={flipped ? "pack-flip-inner is-flipped" : "pack-flip-inner"}>
        <div className="pack-flip-face pack-flip-back">{back}</div>
        <div className="pack-flip-face pack-flip-front">{front}</div>
      </div>
    </div>
  );
}

/** Row class for `count` cards; reveal.css lays out one to five in a fixed grid. */
export function packRowClass(count: number): string {
  return `pack-row ${count > 5 ? "pack-row-many" : `pack-row-${count}`}`;
}

/** One card per pull while the wallet confirms and the transaction mines. */
export function SealedPacks({ count, sent }: { count: number; sent: boolean }) {
  return (
    <div className="pack-panel" aria-live="polite">
      <div className={`${packRowClass(count)}${count === 3 ? " pack-row-fanned" : ""}`}>
        {Array.from({ length: count }, (_, i) => (
          <div key={i} className="pack pack-sealed">
            <PackBack reel={i * 5} />
            <p className="pack-title">Sending your pull</p>
            <PackProgress steps={PULL_STEPS} active={0} label={sent ? "Waiting for the block" : "Confirm in your wallet"} />
          </div>
        ))}
      </div>
    </div>
  );
}

const REFUND_NOTE: Record<number, string> = {
  [ACQ.Expired]: "Randomness did not arrive in time.",
  [ACQ.Refunded]: "The ticket price moved past the slippage limit, or the board had no selectable listing.",
  [ACQ.DeliveryRefunded]: "Delivery did not complete.",
};

function PullPack({ card, flip }: { card: Card; flip: boolean }) {
  const { status, item, ticket } = card;
  if (status in REFUND_NOTE) {
    return (
      <div className="pack pack-refund">
        <PackBack />
        <p className="pack-title">Refunded</p>
        <p className="vault-note">{REFUND_NOTE[status]} FWA credits the ticket for withdrawal at the FWA pool. The VRF fee is spent.</p>
      </div>
    );
  }
  if (status !== ACQ.Fulfilled || !item) {
    return (
      <div className="pack pack-pending pack-drawing" aria-live="polite">
        <PackBack reel={Number(card.id % 97n)} />
        <p className="pack-title">{status === ACQ.Fulfilled ? "Reading the item" : "Drawing"}</p>
        <PackProgress
          steps={PULL_STEPS}
          active={stepOf(status)}
          label={status === ACQ.TimedOut ? "Randomness arrived late. Processing refunds the ticket." : undefined}
        />
      </div>
    );
  }
  const art = <TokenArt token={item} />;
  const grail = item.grail !== undefined;
  return (
    <div className={grail ? `pack pack-opened pack-grail pack-tier-${item.grail === 0 ? "minor" : "major"}` : "pack pack-opened"}>
      {grail && <p className="pack-tier">{TRACK[item.grail!]} GRAIL pack</p>}
      {flip ? <PackFlip back={<PackBack />} front={art} /> : art}
      <p className="pack-value">{eth(item.value)} ETH</p>
      <p className="vault-note pack-result-line">
        {item.pack ? "Draw Pack" : "Shape"} #{item.tokenId.toString()}. Paid {eth(ticket, 5)} ETH ticket.
      </p>
    </div>
  );
}

/** One batch: a card per pull and, once every pull resolves, received value against tickets paid. */
export function PullBatchView({ batch, cards, fresh }: { batch: Batch; cards: Record<string, Card>; fresh: ReadonlySet<string> }) {
  const list = batch.ids.map((id) => cards[id.toString()]).filter(Boolean);
  const delivered = list.filter((c) => c.item);
  const received = delivered.reduce((sum, c) => sum + c.item!.value, 0n);
  // Refunded tickets return as FWA credits, so the comparison counts delivered pulls.
  const paid = delivered.reduce((sum, c) => sum + c.ticket, 0n);
  const settled = list.length > 0 && list.every((c) => c.item || c.status in REFUND_NOTE);
  const best = delivered.reduce<bigint>((max, c) => (c.item!.value > max ? c.item!.value : max), 0n);
  const sealedFan = list.length === 3 && delivered.length === 0;
  return (
    <div className="pack-panel">
      <div className={`${packRowClass(list.length)}${sealedFan ? " pack-row-fanned" : ""}`}>
        {list.map((c) => (
          <PullPack key={c.id.toString()} card={c} flip={fresh.has(c.id.toString())} />
        ))}
      </div>
      {settled && (
        <div className="pack-summary">
          <div className="stat-grid">
            <div className="stat">
              <div className="stat-label">Delivered</div>
              <div className="stat-value">
                {delivered.length}/{list.length}
              </div>
              {delivered.length < list.length && <div className="stat-sub">{list.length - delivered.length} refunded at FWA</div>}
            </div>
            <div className="stat">
              <div className="stat-label">Redeemable value</div>
              <div className={received >= paid ? "stat-value is-up" : "stat-value"}>
                <Eth wei={received} />
              </div>
              <div className="stat-sub">
                against <Eth wei={paid} digits={5} /> in tickets for the delivered pulls, VRF fee excluded
              </div>
            </div>
            {list.length > 1 && (
              <div className="stat">
                <div className="stat-label">Best draw</div>
                <div className="stat-value">
                  <Eth wei={best} />
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
