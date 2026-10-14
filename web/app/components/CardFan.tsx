"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { useListedItems, type ListedItem } from "../lib/art";
import { eth } from "../lib/format";
import { TokenArt } from "./TokenArt";

const CARD_WIDTH = 250;
/** Pixels of drag per card step; matches the card spacing in landing.css. */
const CAROUSEL_STEP_PX = 150;
/** Cards on the ring: the largest `HEAD` first, then a pick of the rest fixed per page load. */
const CAROUSEL_CARDS = 30;
const HEAD = 5;

/** Ring order: item 0 at the center, odd items to its right, even items wrapping in from the left. */
function ringOrder<T>(items: readonly T[]): T[] {
  const ring = new Array<T>(items.length);
  let right = 0;
  let left = items.length;
  items.forEach((item, i) => {
    if (i === 0 || i % 2 === 1) ring[right++] = item;
    else ring[--left] = item;
  });
  return ring;
}

/** Up to `count` items in an order fixed by `seed` and each item's listing id. */
function sprinkle(pool: readonly ListedItem[], count: number, seed: number): ListedItem[] {
  const rank = (id: bigint) => {
    let h = (Number(id & 0xffffffffn) ^ seed) >>> 0;
    h = Math.imul(h ^ (h >>> 16), 0x45d9f3b) >>> 0;
    h = Math.imul(h ^ (h >>> 16), 0x45d9f3b) >>> 0;
    return (h ^ (h >>> 16)) >>> 0;
  };
  return pool
    .map((item) => ({ item, rank: rank(item.listingId) }))
    .sort((a, b) => a.rank - b.rank)
    .slice(0, Math.max(count, 0))
    .map((e) => e.item);
}

/** Slot `i`'s signed distance from carousel position `pos`, wrapped into [-n/2, n/2). */
function ringDistance(i: number, pos: number, n: number): number {
  const d = (((i - pos) % n) + n) % n;
  return d >= n / 2 ? d - n : d;
}

/**
 * Listed Shapes and Draw Packs as a wrapping carousel. Each card's place is a function of one CSS
 * variable, `--d` (distance from the center in cards, `.landing-hero-slide` in landing.css). Drag,
 * horizontal scroll, arrow keys or a tap on a card move `--d`, settling on a whole card. The variable
 * is written to the card elements directly, so a drag repaints without a React render.
 */
function CardCarousel({ cards }: { cards: readonly ListedItem[] }) {
  const n = cards.length;
  const root = useRef<HTMLDivElement>(null);
  const slots = useRef<(HTMLDivElement | null)[]>([]);
  const pos = useRef(0);
  const frame = useRef(0);
  const heading = useRef<number | undefined>(undefined);
  const wheelIdle = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const drag = useRef<{ x: number; pos: number; lastPos: number; lastT: number; velocity: number; moved: boolean } | null>(null);

  function paint() {
    slots.current.forEach((el, i) => el?.style.setProperty("--d", ringDistance(i, pos.current, n).toFixed(3)));
  }

  /** Pixels one card step covers on screen; the hero scales the fan on narrow viewports. */
  function stepPx(): number {
    const el = root.current;
    const scale = el && el.offsetWidth > 0 ? el.getBoundingClientRect().width / el.offsetWidth : 1;
    return CAROUSEL_STEP_PX * scale;
  }

  function glideTo(target: number) {
    cancelAnimationFrame(frame.current);
    const from = pos.current;
    const distance = target - from;
    if (distance === 0 || window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      pos.current = target;
      heading.current = undefined;
      paint();
      return;
    }
    heading.current = target;
    const ms = 260 + Math.min(Math.abs(distance), 4) * 70;
    const start = performance.now();
    const tick = (now: number) => {
      const t = Math.min(1, (now - start) / ms);
      pos.current = from + distance * (1 - (1 - t) ** 3);
      paint();
      if (t < 1) frame.current = requestAnimationFrame(tick);
      else heading.current = undefined;
    };
    frame.current = requestAnimationFrame(tick);
  }

  // Runs before the first paint so every card has its place when it first shows.
  useLayoutEffect(() => {
    paint();
    return () => cancelAnimationFrame(frame.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- repaint when the card count changes.
  }, [n]);

  // Left and right arrows move the carousel while it is on screen, outside fields and controls.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.key !== "ArrowLeft" && e.key !== "ArrowRight") || e.defaultPrevented) return;
      if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
      if (e.target instanceof Element && e.target.closest("input, textarea, select, [contenteditable], [role='slider']")) return;
      const box = root.current?.getBoundingClientRect();
      if (!box || box.bottom <= 0 || box.top >= window.innerHeight) return;
      e.preventDefault();
      glideTo((heading.current ?? Math.round(pos.current)) + (e.key === "ArrowRight" ? 1 : -1));
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- glideTo reads refs and the card count.
  }, [n]);

  function onPointerDown(e: React.PointerEvent<HTMLDivElement>) {
    if (e.pointerType === "mouse" && e.button !== 0) return;
    cancelAnimationFrame(frame.current);
    heading.current = undefined;
    e.currentTarget.setPointerCapture(e.pointerId);
    drag.current = { x: e.clientX, pos: pos.current, lastPos: pos.current, lastT: e.timeStamp, velocity: 0, moved: false };
  }

  function onPointerMove(e: React.PointerEvent<HTMLDivElement>) {
    const d = drag.current;
    if (!d) return;
    const dx = e.clientX - d.x;
    if (!d.moved && Math.abs(dx) < 4) return;
    if (!d.moved) root.current?.classList.add("is-grabbing");
    d.moved = true;
    pos.current = d.pos - dx / stepPx();
    // Velocity is sampled over windows of at least 16 ms so an event burst does not read as a flick.
    const dt = e.timeStamp - d.lastT;
    if (dt >= 16) {
      d.velocity = (pos.current - d.lastPos) / dt;
      d.lastPos = pos.current;
      d.lastT = e.timeStamp;
    }
    paint();
  }

  function endDrag(e: React.PointerEvent<HTMLDivElement>) {
    const d = drag.current;
    if (!d) return;
    drag.current = null;
    root.current?.classList.remove("is-grabbing");
    e.currentTarget.releasePointerCapture(e.pointerId);
    if (d.moved) {
      // A flick carries on for about 180 ms of its release velocity, then settles on a card.
      glideTo(Math.round(pos.current + Math.max(-3, Math.min(3, d.velocity * 180))));
      return;
    }
    const tapped = document.elementFromPoint(e.clientX, e.clientY)?.closest<HTMLElement>("[data-slot]");
    if (tapped) {
      const i = Number(tapped.dataset.slot);
      glideTo(Math.round(pos.current + ringDistance(i, pos.current, n)));
    }
  }

  function onWheel(e: React.WheelEvent<HTMLDivElement>) {
    if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
    cancelAnimationFrame(frame.current);
    heading.current = undefined;
    pos.current += e.deltaX / stepPx();
    paint();
    clearTimeout(wheelIdle.current);
    wheelIdle.current = setTimeout(() => glideTo(Math.round(pos.current)), 140);
  }

  return (
    <div
      ref={root}
      className="landing-hero-fan landing-hero-carousel"
      role="region"
      aria-roledescription="carousel"
      aria-label="Items listed on the board"
      tabIndex={0}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={endDrag}
      onPointerCancel={endDrag}
      onWheel={onWheel}
      onDragStart={(e) => e.preventDefault()}
    >
      {cards.map((card, i) => (
        <div
          key={card.listingId.toString()}
          ref={(el) => {
            slots.current[i] = el;
          }}
          data-slot={i}
          className="landing-hero-card landing-hero-slide"
        >
          <div className="landing-hero-slide-art">
            <TokenArt token={card} width={CARD_WIDTH} />
          </div>
          <div className="landing-hero-card-label">{eth(card.valueWei)} ETH</div>
        </div>
      ))}
    </div>
  );
}

/** The board's listed items on the hero carousel: the five largest by redeemable value first, then a
 *  pick of the rest drawn once per page load. Renders nothing before the board lists an item. */
export function CardFan() {
  const listed = useListedItems().data;
  // The pick is fixed per mount, so a refetch keeps the order.
  const [seed] = useState(() => Math.floor(Math.random() * 2 ** 32));
  if (!listed || listed.length === 0) return null;
  const sorted = [...listed].sort((a, b) => (a.valueWei === b.valueWei ? 0 : a.valueWei > b.valueWei ? -1 : 1));
  const cards = [...sorted.slice(0, HEAD), ...sprinkle(sorted.slice(HEAD), CAROUSEL_CARDS - HEAD, seed)];
  return <CardCarousel cards={ringOrder(cards)} />;
}
