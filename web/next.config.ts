import type { NextConfig } from "next";

// @wagmi/connectors imports Coinbase's optional x402 packages behind literal dynamic imports that
// this app never reaches. Listing the Coinbase packages as server externals stops the bundler from
// resolving them at build time.
const nextConfig: NextConfig = {
  reactStrictMode: true,
  agentRules: false,
  allowedDevOrigins: ["127.0.0.1"],
  serverExternalPackages: ["@coinbase/cdp-sdk", "@base-org/account"],
};

export default nextConfig;
