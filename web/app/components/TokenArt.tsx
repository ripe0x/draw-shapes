"use client";

import { useState } from "react";
import { usePackContents, useTokenImage, type Token } from "../lib/art";
import { useDeployment } from "../Providers";

/** Stack frame in the units of the stack's own 500 x 700 box. */
const FRAME_W = 500;
const FRAME_H = 700;
/** Offset of each later card: 3 percent of the frame. Packs over 8 cards share the 7-step total. */
const STEP_X = 15;
const STEP_Y = 21;
const MAX_STEPS = 7;

/** One Shape's `tokenURI` image in the 5:7 card box. A plain image keeps on-chain SVG markup outside
 *  the page DOM. */
function ShapeImage({ token, label }: { token: Token; label: string }) {
  const art = useTokenImage(token);
  const [broken, setBroken] = useState(false);
  const src = art.data && !broken ? art.data : undefined;
  return src ? (
    // eslint-disable-next-line @next/next/no-img-element
    <img src={src} alt={label} referrerPolicy="no-referrer" style={{ width: "100%", height: "100%" }} onError={() => setBroken(true)} />
  ) : null;
}

/**
 * A Draw Pack as a stack of its component Shapes in a 500 x 700 frame. The smallest-backing Shape is
 * the top card at (0, 0); each later card sits 15 x 21 units right and down, and every card is
 * `500 - 15 (n - 1)` by `700 - 21 (n - 1)` so the stack fills the frame.
 */
function PackStack({ packId, label }: { packId: bigint; label: string }) {
  const dep = useDeployment();
  const contents = usePackContents(packId).data;
  if (!contents || contents.length === 0) {
    return (
      <div className="shape-pack-view" aria-label={label}>
        <div className="shape-pack-stack" aria-hidden>
          <span />
          <span />
          <span />
        </div>
      </div>
    );
  }
  const n = contents.length;
  const scale = n - 1 > MAX_STEPS ? MAX_STEPS / (n - 1) : 1;
  const dx = STEP_X * scale;
  const dy = STEP_Y * scale;
  const w = FRAME_W - dx * (n - 1);
  const h = FRAME_H - dy * (n - 1);
  return (
    <div className="pack-stack" role="img" aria-label={label}>
      {contents.map((id, i) => (
        <div
          key={id.toString()}
          className="pack-stack-card"
          style={{
            left: `${((i * dx) / FRAME_W) * 100}%`,
            top: `${((i * dy) / FRAME_H) * 100}%`,
            width: `${(w / FRAME_W) * 100}%`,
            height: `${(h / FRAME_H) * 100}%`,
            zIndex: n - i,
          }}
        >
          <ShapeImage token={{ collection: dep.shapes, tokenId: id }} label={`Shape ${id.toString()}`} />
        </div>
      ))}
    </div>
  );
}

/** A Shape from its `tokenURI` image, or a Draw Pack as the stack of its component Shapes. */
export function TokenArt({ token, width = "100%" }: { token: Token; width?: number | string }) {
  const dep = useDeployment();
  const pack = token.collection.toLowerCase() === dep.drawPacks.toLowerCase();
  const label = `${pack ? "Draw Pack" : "Shape"} ${token.tokenId.toString()}`;
  return (
    <div className={pack ? "token-art is-pack" : "shape-art"} style={{ width }}>
      {pack ? <PackStack packId={token.tokenId} label={label} /> : <ShapeImage token={token} label={label} />}
    </div>
  );
}
