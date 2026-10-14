import { connectorsForWallets, getDefaultConfig } from "@rainbow-me/rainbowkit";
import { injectedWallet } from "@rainbow-me/rainbowkit/wallets";
import { createConfig, fallback, http } from "wagmi";
import { mainnet, sepolia } from "wagmi/chains";
import { defineChain } from "viem";

/** Local anvil fork. `NEXT_PUBLIC_ANVIL_RPC` overrides the port used by `script/local.sh`. */
export const anvil = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_ANVIL_RPC || "http://127.0.0.1:8545"] } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});

// `NEXT_PUBLIC_RPC_URL` is an optional paid primary for the live chains, ahead of the public list.
const primary = process.env.NEXT_PUBLIC_RPC_URL?.trim();
const withPrimary = (urls: string[]) => fallback([...(primary ? [primary] : []), ...urls].map((u) => http(u)));

/**
 * The deployment's chain comes first so RainbowKit starts on it. Without
 * `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` only injected browser wallets are offered, which keeps
 * local runs from calling the WalletConnect cloud.
 */
export function buildWagmiConfig(chainId: number) {
  const all = [anvil, sepolia, mainnet] as const;
  const chains = [all.find((c) => c.id === chainId) ?? anvil, ...all.filter((c) => c.id !== chainId)] as unknown as typeof all;
  const transports = {
    [anvil.id]: http(anvil.rpcUrls.default.http[0]),
    [sepolia.id]: withPrimary([
      "https://ethereum-sepolia-rpc.publicnode.com",
      "https://sepolia.drpc.org",
      "https://1rpc.io/sepolia",
    ]),
    [mainnet.id]: withPrimary([
      "https://ethereum-rpc.publicnode.com",
      "https://eth.llamarpc.com",
      "https://cloudflare-eth.com",
    ]),
  };
  const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID?.trim();
  const appName = "Draw Shapes";
  if (projectId) return getDefaultConfig({ appName, projectId, chains, transports, ssr: true });
  const connectors = connectorsForWallets([{ groupName: "Browser wallets", wallets: [injectedWallet] }], {
    appName,
    projectId: "unused",
  });
  return createConfig({ chains, transports, connectors, ssr: true });
}
