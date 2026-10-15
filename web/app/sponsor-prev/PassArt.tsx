"use client";

import { useState } from "react";

/** A FWAIR pass image, or the head-and-shoulders placeholder while the image is missing or fails
 *  to load. */
export function PassArt({ image, name, tokenId }: { image?: string; name?: string; tokenId?: bigint }) {
  const [failed, setFailed] = useState<string | undefined>();
  if (image && failed !== image) {
    return (
      // Static asset under public/fwair, not a configured next/image remote pattern.
      // eslint-disable-next-line @next/next/no-img-element
      <img
        src={image}
        alt={name ?? (tokenId != null ? `FWAIR PFP #${tokenId.toString()}` : "")}
        onError={() => setFailed(image)}
      />
    );
  }
  return (
    <div className="sponsor-tile-art">
      <div className="head" />
      <div className="body" />
    </div>
  );
}
