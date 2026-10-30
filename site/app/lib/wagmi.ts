import { createConfig, fallback, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { mainnet, sepolia, foundry } from "wagmi/chains";

// `NEXT_PUBLIC_RPC_URL` is an optional primary ahead of public endpoints. No key is embedded in the bundle.
const primary = process.env.NEXT_PUBLIC_RPC_URL?.trim();
const rpcs = (urls: string[]) => fallback([...(primary ? [primary] : []), ...urls].map((u) => http(u)));

export function buildConfig(chainId: number) {
  const local = { ...foundry, id: 31337 };
  return createConfig({
    chains: chainId === 31337 ? [local, mainnet] : chainId === 11155111 ? [sepolia, mainnet] : [mainnet, sepolia],
    connectors: [injected()],
    transports: {
      [mainnet.id]: rpcs(["https://ethereum-rpc.publicnode.com", "https://eth.drpc.org"]),
      [sepolia.id]: rpcs(["https://ethereum-sepolia-rpc.publicnode.com"]),
      [local.id]: http("http://127.0.0.1:8545"),
    },
    ssr: true,
  });
}
