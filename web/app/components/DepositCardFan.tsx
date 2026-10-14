"use client";

import { useListedItems } from "../lib/art";
import { TokenArt } from "./TokenArt";

/** The three listed items with the most redeemable value, largest in the center. */
export function DepositCardFan() {
  const items = useListedItems().data;
  if (!items?.length) return null;
  const top = [...items].sort((a, b) => (a.valueWei === b.valueWei ? 0 : a.valueWei < b.valueWei ? 1 : -1)).slice(0, 3);
  return (
    <div className="deposit-card-fan" aria-hidden>
      {[2, 0, 1].flatMap((index, slot) =>
        top[index] ? (
          <div className={`deposit-card deposit-card-${slot + 1}`} key={top[index].listingId.toString()}>
            <TokenArt token={top[index]} width="100%" />
          </div>
        ) : [],
      )}
    </div>
  );
}
