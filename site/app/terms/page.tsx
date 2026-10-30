import { OPERATOR, CONTACT, TERMS_VERSION } from "../lib/legal";

export default function Terms() {
  return (
    <>
      <h1>Terms of Use</h1>
      <p className="note">Version {TERMS_VERSION}. Operated by {OPERATOR}.{CONTACT ? ` Contact: ${CONTACT}.` : ""}</p>
      <h2>1. What this is</h2>
      <p>This site is an interface to smart contracts on Ethereum. Draw Shapes is a game of chance: you pay ETH for a
        random draw from a board of Shapes (ERC-721 tokens that each hold ETH and can be burned for it). Draws run on a
        Fake World Assets (FWA) V2 pool with Chainlink VRF. You can also play through FWA's own site.</p>
      <h2>2. Risk</h2>
      <p>A pull costs more than the average prize is worth. Most pulls win the smallest prize, which is worth about two
        thirds of the ticket. Expect to lose money over time. Never play with money you cannot afford to lose.</p>
      <h2>3. ENGINE</h2>
      <p>ENGINE is an ERC-20 token earned by playing during genesis. The game spends realised profit it can spare buying
        ENGINE and burning it; there may be none. ENGINE gives no claim on the game's ETH or prizes, no share of revenue
        or profit, and no right to anything. Its price
        can fall to zero. During genesis the canonical ENGINE pool refuses public buys; sells are always possible. ENGINE
        can be traded elsewhere, and a won Shape can be bought on secondary markets and converted.</p>
      <h2>4. Who can move the game's funds</h2>
      <p>The game's contracts have no withdraw function. Governance, a timelock controlled by the operator, chooses the
        active game contract, the buyback's profit sources, promotion budgets and the modules that set prices and
        policy. Governance can therefore direct the game's ETH to any contract it registers. The timelock's delay is
        the only notice of such a change, and at launch the delay is zero. The operator's own income is the Shapes mint
        fee on each prize minted. No independent audit has been done.</p>
      <h2>5. Eligibility</h2>
      <p>You must be 18 or older and legally able to play games of chance where you are. You are responsible for that.
        You may not use the site if you are a sanctioned person or in a sanctioned region.</p>
      <h2>6. No warranty</h2>
      <p>The site and contracts are provided as is. Blockchain transactions are final. The operator is not liable for
        losses from using them, from bugs, from third-party contracts (FWA, Chainlink, Uniswap, Shapes) or from network
        conditions, to the extent the law allows.</p>
      <h2>7. Changes</h2>
      <p>These Terms may change. When they change materially, the site asks every wallet to accept them again.</p>
    </>
  );
}
