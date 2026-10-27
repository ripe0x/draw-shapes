// Draw Shapes backup keeper. Reads the work available from Lens and runs the keeper jobs only per the backup policy
// (src/policy.mjs). Every write is simulated first; a job that would revert (NoWork, TooSoon) is skipped.
//
// Environment (no secrets in files): MAINNET_RPC_URL, KEEPER_PRIVATE_KEY (a funded key supplied at runtime),
// DEPLOYMENT (path to deployments/<chainId>.json, default ../deployments/1.json), CHAIN_ID (1), BACKUP_AFTER_SECONDS (21600),
// BACKUP_BASEFEE_GATE_GWEI (1), POLL_SECONDS (300), SYNC_MAX_COUNT (50).
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, parseGwei } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import { lensAbi, gameAbi, treasuryAbi, buybackAbi, grailFundAbi, farmAbi } from "./abi.mjs";
import { shouldAct, jobs } from "./policy.mjs";

const env = (k, d) => process.env[k] ?? d;
const rpc = env("MAINNET_RPC_URL");
const key = env("KEEPER_PRIVATE_KEY");
// KEEPER_ADDRESS (local anvil rehearsals only): an impersonated node account instead of a key.
const localAccount = env("KEEPER_ADDRESS");
if (!rpc || (!key && !localAccount)) {
  console.error("MAINNET_RPC_URL and KEEPER_PRIVATE_KEY are required");
  process.exit(1);
}
const dep = JSON.parse(readFileSync(env("DEPLOYMENT", new URL("../../deployments/1.json", import.meta.url)), "utf8"));
const backupAfter = BigInt(env("BACKUP_AFTER_SECONDS", "21600"));
const gate = parseGwei(env("BACKUP_BASEFEE_GATE_GWEI", "1"));
const pollMs = Number(env("POLL_SECONDS", "300")) * 1000;
const syncMax = BigInt(env("SYNC_MAX_COUNT", "50"));

const account = key ? privateKeyToAccount(key) : localAccount;
const chain = { ...mainnet, id: Number(env("CHAIN_ID", String(mainnet.id))) };
const pub = createPublicClient({ chain, transport: http(rpc) });
const wallet = createWalletClient({ account, chain, transport: http(rpc) });

const addrs = {
  game: dep.game,
  farm: dep.farm,
  treasury: dep.treasury,
  keeperFund: dep.keeperFund,
  buyback: dep.buyback,
  grailFund: dep.grailFund,
  swapPolicy: dep.swapPolicy,
  liquidity: dep.liquidity,
};

const calls = {
  sync: { address: dep.game, abi: gameAbi, functionName: "sync", args: [syncMax] },
  distribute: { address: dep.treasury, abi: treasuryAbi, functionName: "distribute", args: [] },
  buyback: { address: dep.buyback, abi: buybackAbi, functionName: "process", args: [0n] },
  grail: { address: dep.grailFund, abi: grailFundAbi, functionName: "process", args: [] },
  retireUnearned: { address: dep.farm, abi: farmAbi, functionName: "retireUnearned", args: [] },
};

async function ageOf(job, now) {
  if (job.age !== null) return job.age;
  if (job.name === "buyback") return now - (await pub.readContract({ address: dep.buyback, abi: buybackAbi, functionName: "lastRunAt" }));
  if (job.name === "grail") return now - (await pub.readContract({ address: dep.grailFund, abi: grailFundAbi, functionName: "lastRunAt" }));
  return backupAfter + 1n; // retireUnearned: nobody else may have done it; act
}

async function tick() {
  const block = await pub.getBlock();
  const basefee = block.baseFeePerGas ?? 0n;
  const work = await pub.readContract({ address: dep.lens, abi: lensAbi, functionName: "work", args: [addrs] });
  for (const job of jobs(work)) {
    const age = await ageOf(job, block.timestamp);
    if (!shouldAct({ ageSeconds: age, basefeeWei: basefee, backupAfterSeconds: backupAfter, basefeeGateWei: gate })) {
      console.log(`${job.name}: waiting (age ${age}s, basefee ${basefee})`);
      continue;
    }
    try {
      const { request } = await pub.simulateContract({ account, ...calls[job.name] });
      const hash = await wallet.writeContract(request);
      const receipt = await pub.waitForTransactionReceipt({ hash });
      console.log(`${job.name}: ${receipt.status} ${hash} gas ${receipt.gasUsed}`);
    } catch (e) {
      console.log(`${job.name}: skipped (${e.shortMessage ?? e.message})`);
    }
  }
}

const once = process.argv.includes("--once");
do {
  try {
    await tick();
  } catch (e) {
    console.error("tick failed:", e.shortMessage ?? e.message);
  }
  if (!once) await new Promise((r) => setTimeout(r, pollMs));
} while (!once);
