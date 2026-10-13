# FWA V2 launch snapshot

Pinned Ethereum state: block `25991175`, timestamp `2026-09-16T16:16:35Z`.

The V2 main pool had 571 active listings.  Public getters return an EV of
0.066394769005772277 ETH and a ticket of 0.069714507456060890 ETH, a 5% surcharge.
The ETH settlement discount is 90%, so the expected ETH-cashout value is
0.059755292105195049 ETH, or 85.7142857% of the ticket.  This is a model expectation,
not a win frequency.

The token route has a 92.5% ETH budget, 88.0952381% of the ticket, but it buys FWA
tokens and is not reported as liquid ETH return.  The primary ETH figure excludes VRF,
transaction gas, token rewards, NFT resale value, and other purchaser rewards.

Weighted win frequency is unknown. It must not be inferred from RTP: exact enumeration
requires a verified main-pool listing ABI, and the locally vendored custom-pool clone
ABI is not evidence for that tuple. A public-RPC enumeration attempt was rate limited.
