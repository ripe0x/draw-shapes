"use client";

import { useAccount, useReadContract, useWriteContract } from "wagmi";
import { deployment, lensAddresses } from "../lib/deployment";
import { lensAbi, farmAbi } from "../lib/abi";
import { engine } from "../lib/format";
import { NotDeployed } from "../components/NotDeployed";
import { TxStatus } from "../components/Tx";

const ZERO = "0x0000000000000000000000000000000000000000";

export default function Claim() {
  const { address } = useAccount();
  const { data: market } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "market", args: [lensAddresses], query: { enabled: deployment.deployed } });
  const to = market ? market.currentEpoch + 1n : 0n;
  const { data } = useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "claimable", args: [deployment.farm, address ?? ZERO, 0n, to], query: { enabled: deployment.deployed && !!address && to > 0n } });
  const { writeContract, data: hash, error, isPending } = useWriteContract();
  const [total, list] = data ?? [0n, []];
  return (
    <>
      <h1>Claim ENGINE</h1>
      <p>Rewards of final epochs. Claims never expire.</p>
      <NotDeployed>
        <div className="grid"><div className="stat"><b>{engine(total)}</b><span>ENGINE claimable over {list.length} epochs</span></div></div>
        <div className="row">
          <button className="btn-filled" disabled={!address || list.length === 0 || isPending}
            onClick={() => writeContract({ address: deployment.farm, abi: farmAbi, functionName: "claim", args: [list as bigint[]] })}>
            Claim
          </button>
        </div>
        <TxStatus hash={hash} error={error} />
      </NotDeployed>
    </>
  );
}
