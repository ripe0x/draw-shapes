"use client";

/** Renders a Shape's SVG in a portrait art box at width `width`. The SVG is passed in. */
export function ShapeArt({ tokenId, svg, width = 160 }: { tokenId: bigint; svg: string; width?: number }) {
  return (
    <div>
      <div className="shape-art" style={{ width }}>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={`data:image/svg+xml,${encodeURIComponent(svg)}`}
          alt={`Shape ${tokenId.toString()}`}
          referrerPolicy="no-referrer"
          style={{ width: "100%", height: "100%" }}
        />
      </div>
    </div>
  );
}
