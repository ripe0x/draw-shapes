"use client";

import { createContext, useContext, useMemo, useState } from "react";
import "@rainbow-me/rainbowkit/styles.css";
import { RainbowKitProvider, lightTheme } from "@rainbow-me/rainbowkit";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import { buildWagmiConfig } from "./lib/wagmi";
import type { Deployment } from "./lib/deployment";

const DeploymentContext = createContext<Deployment | null>(null);

export function useDeployment(): Deployment {
  const dep = useContext(DeploymentContext);
  if (!dep) throw new Error("useDeployment must be used inside Providers");
  return dep;
}

export function Providers({ deployment, children }: { deployment: Deployment; children: React.ReactNode }) {
  const config = useMemo(() => buildWagmiConfig(deployment.chainId), [deployment.chainId]);
  const [queryClient] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={config} reconnectOnMount>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={lightTheme({ accentColor: "#11110f", accentColorForeground: "#f7f7f3" })}>
          <DeploymentContext.Provider value={deployment}>{children}</DeploymentContext.Provider>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
