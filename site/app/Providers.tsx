"use client";

import { useState } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import { buildConfig } from "./lib/wagmi";
import { deployment } from "./lib/deployment";

const config = buildConfig(deployment.chainId);

export function Providers({ children }: { children: React.ReactNode }) {
  const [client] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={config} reconnectOnMount>
      <QueryClientProvider client={client}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
