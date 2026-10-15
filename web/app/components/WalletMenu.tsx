"use client";

import { useEffect, useRef } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useConnect, useDisconnect } from "wagmi";
import { short } from "../lib/format";

/** Connect button, network chooser and a disconnect menu, drawn with RainbowKit's custom render. */
export function WalletMenu() {
  const details = useRef<HTMLDetailsElement>(null);
  const { disconnect } = useDisconnect();
  const { connect, connectors } = useConnect();
  const anvilWallet = connectors.find((c) => c.id === "mock");

  useEffect(() => {
    function closeOutside(event: PointerEvent) {
      if (details.current && !details.current.contains(event.target as Node)) details.current.open = false;
    }
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape" && details.current) details.current.open = false;
    }
    document.addEventListener("pointerdown", closeOutside);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("pointerdown", closeOutside);
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, []);

  return (
    <ConnectButton.Custom>
      {({ account, chain, authenticationStatus, mounted, openConnectModal, openChainModal }) => {
        const ready = mounted && authenticationStatus !== "loading";
        const connected = ready && account && (!authenticationStatus || authenticationStatus === "authenticated");
        return (
          <div className="wallet-control" aria-hidden={!ready} style={!ready ? { opacity: 0, pointerEvents: "none" } : undefined}>
            {!connected ? (
              <>
                <button type="button" className="wallet-trigger" onClick={openConnectModal}>
                  Connect wallet
                </button>
                {anvilWallet && (
                  <button type="button" className="wallet-trigger" onClick={() => connect({ connector: anvilWallet })}>
                    Use anvil test wallet
                  </button>
                )}
              </>
            ) : (
              <>
                <button
                  type="button"
                  className={chain?.unsupported ? "wallet-trigger wallet-chain-trigger is-warn" : "wallet-trigger wallet-chain-trigger"}
                  onClick={openChainModal}
                  aria-label="Switch network"
                >
                  {chain?.hasIcon && chain.iconUrl && (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={chain.iconUrl} alt="" width={16} height={16} />
                  )}
                  <span>{chain?.unsupported ? "Wrong network" : (chain?.name ?? "Network")}</span>
                </button>
                <details ref={details} className="wallet-menu">
                  <summary className="wallet-trigger" aria-label={`Wallet ${account.address}`}>
                    <span>{account.ensName ?? short(account.address)}</span>
                    {account.displayBalance && <span className="wallet-balance">{account.displayBalance}</span>}
                    <span className="wallet-chevron" aria-hidden>
                      ⌄
                    </span>
                  </summary>
                  <div className="wallet-menu-popover" role="menu">
                    <button
                      type="button"
                      role="menuitem"
                      onClick={() => {
                        if (details.current) details.current.open = false;
                        disconnect();
                      }}
                    >
                      Disconnect
                    </button>
                  </div>
                </details>
              </>
            )}
          </div>
        );
      }}
    </ConnectButton.Custom>
  );
}
