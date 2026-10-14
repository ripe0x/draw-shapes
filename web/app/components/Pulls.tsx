"use client";

import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useAccount, usePublicClient } from "wagmi";
import { getAbiItem, zeroAddress, type Address, type PublicClient } from "viem";
import { fwaCloneAbi, packsAbi, shapesAbi } from "../lib/abi/external";
import { poolAbi } from "../lib/abi/pool";
import type { Deployment } from "../lib/deployment";
import { formatTxError } from "../lib/errors";
import { eth } from "../lib/format";
import { useDeployment } from "../Providers";
import { TxButton, TxStatus, useTx } from "./Tx";

const POLL_MS = 6_000;
const pulledEvent = getAbiItem({ abi: poolAbi, name: "Pulled" });
const grailEvent = getAbiItem({ abi: poolAbi, name: "GrailCaptured" });

/** FWA `AcquisitionStatus` in declaration order. */
const STATUS = ["None", "Pending", "Fulfilled", "Expired", "Refunded", "Ready", "TimedOut", "DeliveryPending", "DeliveryRefunded"];
const CHIP: Record<number, string> = {
  1: "Pending",
  2: "Delivered",
  3: "Expired",
  4: "Refunded",
  5: "Ready",
  6: "Timed out",
  7: "Delivery pending",
  8: "Delivery refunded",
};
const HINT: Record<number, string> = {
  1: "Waiting for randomness.",
  5: "Randomness is in. Waiting for processing.",
  6: "Randomness arrived late. The ticket is refunded when processed.",
  7: "The item could not be delivered yet. Delivery retries are open.",
  3: "No randomness in time. The ticket is credited for withdrawal on FWA.",
  4: "No listing was available. The ticket is credited for withdrawal on FWA.",
  8: "Delivery did not complete. The ticket is credited for withdrawal on FWA.",
};
const UNRESOLVED = new Set([0, 1, 5, 6, 7]);

interface Item {
  collection: Address;
  tokenId: bigint;
  pack: boolean;
  /** Backing of a Shape, value of a Draw Pack. */
  value: bigint;
  grail: boolean;
}
interface Card {
  id: bigint;
  status: number;
  ticket: bigint;
  item?: Item;
}
interface Batch {
  block: bigint;
  count: bigint;
  fee: bigint;
  ids: readonly bigint[];
}
interface Data {
  /** Last block scanned for `Pulled`. */
  scanned: bigint;
  batches: Batch[];
  cards: Record<string, Card>;
  /** Request ids seen moving from unresolved to delivered while the page was open. */
  fresh: string[];
}

/** Scans `Pulled` for the wallet from the last scanned block, reads each request on the FWA pool and
 *  the delivered items. `prior` carries the earlier result so only new blocks are scanned. */
async function load(client: PublicClient, dep: Deployment, owner: Address, prior?: Data): Promise<Data> {
  const latest = await client.getBlockNumber();
  const base = prior && prior.scanned <= latest ? prior : undefined;
  const from = base ? base.scanned + 1n : BigInt(dep.blockNumber);
  const logs =
    from <= latest
      ? await client.getLogs({ address: dep.pool, event: pulledEvent, args: { purchaser: owner }, fromBlock: from, toBlock: latest, strict: true })
      : [];
  const batches = [
    ...(base?.batches ?? []),
    ...logs.map((l) => ({ block: l.blockNumber, count: l.args.count, fee: l.args.fee, ids: l.args.requestIds })),
  ];
  const ids = batches.flatMap((b) => b.ids);
  if (!ids.length) return { scanned: latest, batches, cards: {}, fresh: [] };

  const fwa = dep.fwaPool ?? (await client.readContract({ address: dep.pool, abi: poolAbi, functionName: "fwaPool" }));
  if (fwa === zeroAddress) throw new Error("The FWA pool is not created yet.");
  const fee = new Map(batches.flatMap((b) => b.ids.map((id) => [id, b.fee] as const)));
  const acqs = await client.multicall({
    allowFailure: false,
    contracts: ids.map((id) => ({ address: fwa, abi: fwaCloneAbi, functionName: "acquisitions", args: [id] }) as const),
  });
  const cards: Record<string, Card> = {};
  ids.forEach((id, i) => {
    const key = id.toString();
    cards[key] = { id, status: acqs[i][4], ticket: fee.get(id)!, item: base?.cards[key]?.item };
  });

  // Delivered requests without an item yet: the listing, then its backing or value.
  const todo = ids.filter((_, i) => acqs[i][4] === 2 && !cards[ids[i].toString()].item);
  if (todo.length) {
    const lists = await client.multicall({
      allowFailure: false,
      contracts: todo.map((id) => ({ address: fwa, abi: fwaCloneAbi, functionName: "listings", args: [acqs[ids.indexOf(id)][3]] }) as const),
    });
    const packs = lists.map((l) => l[0].toLowerCase() === dep.drawPacks.toLowerCase());
    const values = await client.multicall({
      allowFailure: false,
      contracts: lists.map((l, i) =>
        packs[i]
          ? ({ address: l[0], abi: packsAbi, functionName: "valueOf", args: [l[3]] } as const)
          : ({ address: l[0], abi: shapesAbi, functionName: "backingOf", args: [l[3]] } as const),
      ),
    });
    todo.forEach((id, i) => {
      cards[id.toString()].item = { collection: lists[i][0], tokenId: lists[i][3], pack: packs[i], value: values[i], grail: false };
    });
  }

  // GRAIL captures are booked by `settle`, so a delivered pack is rechecked until it shows up.
  const open = Object.values(cards).filter((c) => c.item?.pack && !c.item.grail);
  if (open.length) {
    const found = await client.getLogs({
      address: dep.pool,
      event: grailEvent,
      args: { requestId: open.map((c) => c.id) },
      fromBlock: BigInt(dep.blockNumber),
      toBlock: latest,
      strict: true,
    });
    for (const l of found) cards[l.args.requestId.toString()].item!.grail = true;
  }

  const fresh = new Set(base?.fresh);
  for (const [key, c] of Object.entries(cards)) {
    const was = base?.cards[key];
    if (was && UNRESOLVED.has(was.status) && c.status === 2) fresh.add(key);
  }
  return { scanned: latest, batches, cards, fresh: [...fresh] };
}

/** First `image` field of a data-URI JSON `tokenURI`, restricted to data:image URIs. */
function imageOf(uri: string): string {
  const m = /^data:application\/json(;base64)?,(.*)$/s.exec(uri);
  if (!m) throw new Error("Unsupported tokenURI");
  const text = m[1] ? new TextDecoder().decode(Uint8Array.from(atob(m[2]), (c) => c.charCodeAt(0))) : decodeURIComponent(m[2]);
  const image = JSON.parse(text).image;
  if (typeof image !== "string" || !image.startsWith("data:image/")) throw new Error("No inline image");
  return image;
}

function Art({ item }: { item: Item }) {
  const dep = useDeployment();
  const client = usePublicClient({ chainId: dep.chainId });
  const [broken, setBroken] = useState(false);
  const art = useQuery({
    queryKey: ["token-image", dep.chainId, item.collection, item.tokenId.toString()],
    queryFn: async () =>
      imageOf(
        await client!.readContract({ address: item.collection, abi: item.pack ? packsAbi : shapesAbi, functionName: "tokenURI", args: [item.tokenId] }),
      ),
    enabled: !!client,
    staleTime: Infinity,
    retry: 1,
  });
  const label = `${item.pack ? "Draw Pack" : "Shape"} ${item.tokenId}`;
  return (
    <div className="pull-art">
      {art.data && !broken ? (
        // A plain image keeps on-chain SVG markup outside the page DOM.
        // eslint-disable-next-line @next/next/no-img-element
        <img src={art.data} alt={label} referrerPolicy="no-referrer" onError={() => setBroken(true)} />
      ) : (
        <span className="note">{art.isPending ? "Loading art." : "No preview."}</span>
      )}
    </div>
  );
}

function PullCard({ card, fresh }: { card: Card; fresh: boolean }) {
  const { status, item, ticket } = card;
  const ratio = item && ticket ? Number((item.value * 10_000n) / ticket) / 100 : undefined;
  const up = item !== undefined && item.value > ticket;
  return (
    <div className={`pull-card${fresh ? " reveal" : ""}`}>
      <div className="row">
        <span className={`chip${status === 2 ? " ok" : ""}`} title={STATUS[status]}>
          {CHIP[status] ?? STATUS[status]}
        </span>
        {item?.grail && <span className="chip grail">GRAIL</span>}
        <span className="note">Request {card.id.toString()}</span>
      </div>
      {item ? (
        <>
          <Art item={item} />
          <dl className="kv">
            <dt>{item.pack ? "Draw Pack" : "Shape"}</dt>
            <dd>#{item.tokenId.toString()}</dd>
            <dt>{item.pack ? "Value" : "Backing"}</dt>
            <dd className={up ? "up" : undefined}>
              {eth(item.value)} ETH{ratio !== undefined && ` (${ratio.toLocaleString("en-US", { maximumFractionDigits: 1 })}% of ticket)`}
            </dd>
          </dl>
        </>
      ) : (
        <p className="note">{status === 2 ? "Reading the item." : (HINT[status] ?? "")}</p>
      )}
    </div>
  );
}

/** The connected wallet's pulls, newest first, with the keeper actions that move a pull along. */
export function Pulls() {
  const dep = useDeployment();
  const { address } = useAccount();
  const client = usePublicClient({ chainId: dep.chainId });
  const queryClient = useQueryClient();
  const tx = useTx();
  const key = ["pulls", dep.chainId, dep.pool, address] as const;
  const pulls = useQuery({
    queryKey: key,
    queryFn: () => load(client!, dep, address!, queryClient.getQueryData<Data>(key)),
    enabled: !!client && !!address,
    refetchInterval: (q) => (q.state.data && Object.values(q.state.data.cards).some((c) => UNRESOLVED.has(c.status)) ? POLL_MS : false),
  });
  const data = pulls.data;
  const fresh = new Set(data?.fresh);

  function fwaAddress() {
    return dep.fwaPool ?? client!.readContract({ address: dep.pool, abi: poolAbi, functionName: "fwaPool" });
  }

  return (
    <section>
      <h2>Your pulls</h2>
      {!address && <p className="note">Connect a wallet to see its pulls.</p>}
      {pulls.isPending && address && <p className="note">Reading pulls.</p>}
      {pulls.error && <p className="error">Reading pulls failed: {formatTxError(pulls.error)}</p>}
      {data && data.batches.length === 0 && <p className="note">This wallet has no pulls on this pool.</p>}
      {data?.batches
        .slice()
        .reverse()
        .map((b) => (
          <div key={`${b.block}-${b.ids[0]}`} className="pull-batch">
            <p className="note">
              Block {b.block.toString()}, {b.count.toString()} {b.count === 1n ? "ticket" : "tickets"} at {eth(b.fee, 6)} ETH, paid{" "}
              {eth(b.fee * b.count, 6)} ETH plus the VRF fee
            </p>
            <div className="pull-cards">
              {b.ids.map((id) => {
                const card = data.cards[id.toString()];
                return card && <PullCard key={card.id.toString()} card={card} fresh={fresh.has(card.id.toString())} />;
              })}
            </div>
          </div>
        ))}
      <div className="row">
        <TxButton
          tx={tx}
          label="Settle now"
          outline
          onClick={() => void tx.run(() => tx.write({ address: dep.pool, abi: poolAbi, functionName: "settle", args: [20n], chainId: dep.chainId }))}
        />
        <TxButton
          tx={tx}
          label="Process on FWA"
          outline
          onClick={() =>
            void tx.run(async () =>
              tx.write({ address: await fwaAddress(), abi: fwaCloneAbi, functionName: "processAcquisitions", args: [20n], chainId: dep.chainId }),
            )
          }
        />
      </div>
      <p className="note">
        Settle now books up to 20 requests on the pool. When the pool is due to list replacements, the pool refunds the caller&apos;s gas
        from its maintenance bucket. Process on FWA processes up to 20 ready requests directly, for the case where the pool is not due.
      </p>
      <TxStatus tx={tx} />
    </section>
  );
}
