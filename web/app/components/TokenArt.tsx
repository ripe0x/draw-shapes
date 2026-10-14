"use client";

import { useState } from "react";
import { useTokenImage, type Token } from "../lib/art";
import { useDeployment } from "../Providers";

/**
 * A Shape or Draw Pack drawn from its `tokenURI` image in the 5:7 card box. A Draw Pack image is a
 * transparent stack of its component cards, drawn in `.shape-pack-view`; a placeholder stack stands
 * in until it loads. A plain image keeps on-chain SVG markup outside the page DOM.
 */
export function TokenArt({ token, width = "100%" }: { token: Token; width?: number | string }) {
  const dep = useDeployment();
  const art = useTokenImage(token);
  const [broken, setBroken] = useState(false);
  const pack = token.collection.toLowerCase() === dep.drawPacks.toLowerCase();
  const label = `${pack ? "Draw Pack" : "Shape"} ${token.tokenId.toString()}`;
  const src = art.data && !broken ? art.data : undefined;

  if (pack) {
    return (
      <div className={src ? "shape-pack-view has-image" : "shape-pack-view"} style={{ width }} aria-label={label}>
        {src ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img className="shape-pack-image" src={src} alt={label} referrerPolicy="no-referrer" onError={() => setBroken(true)} />
        ) : (
          <div className="shape-pack-stack" aria-hidden>
            <span />
            <span />
            <span />
          </div>
        )}
      </div>
    );
  }
  return (
    <div className="shape-art" style={{ width }}>
      {src && (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={src} alt={label} referrerPolicy="no-referrer" style={{ width: "100%", height: "100%" }} onError={() => setBroken(true)} />
      )}
    </div>
  );
}
