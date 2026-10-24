# Draw Shapes and ENGINE: selected product and economic design

Owner's brief, prepared 2026-10-23, checked in verbatim on 2026-10-24 as the input to
[REVIEW](REVIEW.md) and [PLAN](PLAN.md). It is a proposal, not the current specification; `docs/SPEC.md`
still describes the deployed-candidate v1 behaviour until the plan's spec phase lands.

---

Numerical inputs are design decisions and modeled assumptions, not demonstrated demand, guaranteed returns, or deployed settings. No mainnet transactions were performed for this work.

## 1. The product

Launch a functioning FWA game using 5 ETH supplied by the creator. Run a finite 14 day ENGINE genesis at the same time. Every successful paid draw earns genesis tokens. Approximately 40 percent of ordinary prize outcomes are funded claims that purchase ENGINE. The other ordinary outcomes are redeemable ETH Shapes and packs. External trading becomes possible after 24 hours without opening original token inventory to public buyers.

After genesis, original issuance permanently ends. ENGINE remains an actual prize purchased with real ETH. All distributable game profit purchases and burns ENGINE. Public market fees fund locked liquidity, growing ETH GRAILs, and a permanent Punk acquisition and sponsorship pot.

No outside ETH depositors, capped founder note, creator token grant, additional operator fee, or staking emissions. The creator earns the actual mint fee on new Shapes.

The product deliberately recruits farmers during genesis. It does not promise that all farmers can sell profitably. The market must attract people willing to hold the asset, and the game must retain paid play after subsidies end.

## 2. The 5 ETH contribution

| Use | ETH |
| --- | --- |
| Ordinary pool | 4.00 |
| Maintenance | 0.30 |
| Additional treasury reserve | 0.45 |
| Protocol owned market liquidity | 0.25 |
| Total system capital | 5.00 |

This is a permanent contribution, not a redeemable creator loan. No personal withdrawal right over ordinary backing or the market reserve is created.

Deployment gas, acquisition of any required FWA creation tokens, security review, and other setup expenses are additional costs. The 5 ETH is not simultaneously an all inclusive launch expense budget.

The 0.25 ETH market allocation is actually available to sellers and can be lost to them. It is not prize backing or a token price guarantee.

Start with no externally purchased NFT and no mandatory 5 ETH GRAIL. The largest ordinary prize is a 0.5 ETH Shape. A funded 1 ETH GRAIL is the first prize funding milestone.

## 3. Exact ordinary opening board

| Backing / purchase budget | Ordinary ETH prizes | ENGINE claim packs | Total |
| --- | --- | --- | --- |
| 0.01 ETH | 30 | 20 | 50 |
| 0.02 ETH | 13 | 9 | 22 |
| 0.03 ETH | 8 | 5 | 13 |
| 0.05 ETH | 6 | 4 | 10 |
| 0.10 ETH | 2 | 2 | 4 |
| 0.50 ETH | 1 | 0 | 1 |
| Total | 60 | 40 | 100 |

Use the same underlying denomination structure for each payout mode. A 0.02 pack contains two 0.01 Shapes; a 0.03 pack contains three. ENGINE mode does not add an extra payout or another creator fee.

This inventory requires 2.73 ETH of backing and 0.148 ETH of initial Shape mint fees at the modeled 0.001 ETH fee. It leaves 1.122 ETH liquid within the 4 ETH ordinary allocation before additional implementation costs. Underlying Shape backing and pool cash are different forms of owned assets; initial mint fees are expenses.

Use fixed target depth and like for like replacement. Remove the old sampled replacement surprise upgrades from the initial engine profile. Random prize selection and random genesis rewards already provide sufficient variation. Do not enlarge the ordinary board merely because treasury capital increases.

FWA uses inverse assigned price weights. Thus 40 of 100 ENGINE listings produce about 40.10 percent of the initial selection probability, not an assumed exactly 40 percent.

## 4. Ordinary pricing and costs

Use the existing listing formula with these proposed pricing inputs:

| Component | Basis points of backing |
| --- | --- |
| Ordinary retained surplus | 200 |
| Maintenance | 200 |
| Baseline GRAIL feed | 100 |

Add the actual underlying Shape mint allowance. FWA then applies its own actual fee and randomness quote. The inputs are neither shares of gross player spending nor assured profit percentages.

For the specified static board, assuming FWA's 5 percent additional fee split equally with the owner:

| Expected amount per successful draw | ETH |
| --- | --- |
| FWA game payment before randomness and wallet gas | 0.01777338 |
| Allocated prize backing / token purchase budget | 0.01489290 |
| Shape mint fee expense | 0.00128948 |
| Ordinary retained allocation | 0.00046713 |
| Maintenance allocation | 0.00046713 |
| Baseline GRAIL allocation | 0.00023356 |
| Of total backing, ENGINE purchase backing | 0.00595668 |

These are conditional static calculations with the target board maintained. They are not the measured profitability of the new implementation. The ordinary retained allocation remains subject to realized losses, execution expenses, and reserve requirements before it can be distributed.

The backing budget is about 83.79 percent of the game payment. Once ENGINE is purchased, its actual resale value varies. Do not present that percentage as a guaranteed return to player or include uncertain farming rewards in a guaranteed ETH return figure.

At the documented FWA randomness parameters and 0.25 gwei, the game payment plus randomness is approximately 0.01826088 ETH, before wallet gas or later ENGINE conversion gas. Actual onchain quotes must replace these assumptions at deployment.

The launch policy only accepts new draws under a 0.25 gwei transaction gas price cap and with adequate funded maintenance and inventory. This is an explicit low gas operating policy, not proof that the system works economically at every mainnet gas price. It does not restrict settlement of accepted draws or withdrawal of earned assets.

Keep at least 80 active ordinary outcomes before accepting more draw exposure, with additional allowance for outstanding requests. The sponsor probability constraint can be stricter. Benchmarks must include actual wrapper and listing gas, and keepers must be compensated from explicit funds rather than involuntary creator subsidies.

## 5. The ENGINE Pack

An ENGINE Pack is an ERC721 wrapper around actual ETH backed Shapes. Its redemption mode is fixed before it is listed.

A 0.05 ETH ENGINE Pack owns 0.05 ETH of actual Shape backing. The winner redeems that backing and uses it to purchase ENGINE. The player receives the purchased coins and no second 0.05 ETH payout.

The interface can estimate a token quantity but promises a purchase budget, not a fixed number of tokens. A swap must respect the user's minimum output and the protocol's execution constraints. Failed execution leaves the funded claim intact. Redemption is not performed as an arbitrary external swap inside FWA's randomness callback.

The wrapper offers an ETH exit 48 hours after the recorded award if it has not successfully settled into ENGINE. It is impossible to claim both forms. This avoids indefinite trapping and is explicitly included as a risk to assumed market purchase volumes.

Claim purchases receive the zero project fee only through an authenticated, single use game receipt. Merely minting a Shape or calling a router does not qualify. Transfer of the pack transfers its purchase claim but not the original player's separate genesis participation credit.

Claims outstanding at genesis close continue to use their funded ETH, but afterward buy existing circulated tokens rather than accessing original inventory.

## 6. Supply and genesis allocation

Maximum original supply is 1 billion ENGINE, all created into restricted custody at deployment. There is no subsequent mint authority.

| Initial allocation | Tokens |
| --- | --- |
| Gameplay purchase inventory | 900 million |
| Finite farming allocation | 100 million |
| Team, creator, presale or outside capital backer allocation | Zero |

The maximum is not a promise that 1 billion tokens will reach holders. All untouched purchase inventory is burned at genesis close. Empty epoch reward allocations are also burned. Earned claims are preserved.

A token may leave original custody only through an authenticated game prize purchase, a game profit purchase distributed as a genesis reward, or an earned farming allocation. Public buyers never purchase untouched original inventory.

The 100 million farming allocation is 10 percent of the maximum original supply. It can become a much larger proportion of final supply after untouched inventory is burned. This must be explicit in distribution reporting.

## 7. Every farmer participates

Genesis lasts 14 fixed 24 hour epochs, beginning only when the game is actually playable and its market is ready.

Each epoch has approximately 7.142857 million scheduled reward tokens. Integer rounding is assigned deterministically to the final epoch. Eighty percent is divided equally among successful paid draws. Twenty percent is divided by independently derived random bonus points:

| Probability per successful draw | Bonus points |
| --- | --- |
| 90 percent | 0 |
| 9 percent | 1 |
| 1 percent | 10 |

When an epoch has no bonus points, its bonus portion joins the equal allocation. When it has no successful draws, its scheduled token allotment burns rather than moving to a later jackpot.

All qualifying successful draws earn the equal allocation, including ordinary ETH outcomes. Wallet count does not increase rewards; paying for more real draws does. Every success in a batch counts. Refunds do not earn rewards. Recycling winnings through additional genuine paid plays is allowed.

Use the actual request acceptance time to assign epochs. Fix participant identity and terms before randomness. Do not let a keeper assign a favorable result to a less crowded epoch or discard an unfavorable result. Bonus randomness comes from the verified draw result with separate domain separation.

Claims open after the epoch closes and its requests resolve under the real FWA rules. Existing earned tokens remain claimable without an artificial expiry. Any pending request reserve at the final boundary is disclosed as an existing liability, not new future emissions. Operational pauses do not extend the genesis calendar.

During genesis, all actually distributable ordinary game surplus buys ENGINE for the epoch rewards. No simultaneous profit funded token burn is counted from that same ETH.

This reward program is intentionally more aggressive than a small purchase matched bonus. It needs real holding and trading demand. A quoted token price is not a promise that all earned balances can be sold at that price.

## 8. The canonical v4 market

The first 24 hours permit authenticated game buys and holder sells. From hour 24 through day 14, public buys are enabled for resale inventory only.

The hook maintains two accounting quantities inside the controlled market:

| Inventory balance | Rule |
| --- | --- |
| Original inventory | Never previously released through gameplay; only the game may purchase it |
| Resale inventory | Tokens previously released and subsequently sold back; any buyer may purchase it after hour 24 |

Tokens are fungible. This is an accounting rule, not a claim that individual ERC20 units carry identities. Game purchases consume resale inventory first. Only the excess releases original inventory. Public purchases are limited to the available resale balance and must receive an honest partial quote or revert without an execution fee on the unfilled amount.

Genesis transfers and liquidity modification are constrained so adding liquidity, withdrawing it, alternate routers, or another pool cannot bypass the primary issuance rule. Normal token transfers open after genesis. Later markets may not pay the canonical fee, so projections must not assume every ENGINE trade creates game revenue.

The opening price parameter is 0.00000005 ETH per ENGINE. That is a 50 ETH price reference against the maximum billion tokens, not an asserted circulating market capitalization or ETH redemption promise.

The initial primary position supplies tokens over a tenfold upward price range. The separately contributed 0.25 ETH supplies bid liquidity below the opening price, over a broad range. It is real market risk capital.

The public trading charge is 5 percent on the actual ETH side, for buys and sells. Authenticated game claim purchases, genesis reward purchases, and mature buybacks pay zero project charge. No Artcoins factory, external Artcoins fee split, or special creator swap fee is used.

## 9. Genesis closes permanently

At the deadline, original inventory access closes even if participation is disappointing. There is no extension and no later minting window.

The finalizer removes the controlled genesis positions, burns exactly the tracked original inventory never released, and preserves all actual market ETH and returned circulated tokens. It places those remaining assets into permanent positions meeting at the same marginal price. Remaining assets do not become creator income or game reserves.

Earned but unclaimed farming tokens are not burned. The ordinary prize claims remain fully funded. Pending request allocations are resolved within the existing committed program rather than creating another period of reward eligibility.

From that point, every ENGINE prize purchase, public buy, and buyback uses circulating tokens. A holder sale adds existing tokens to liquidity. No unissued stock remains available to future buyers.

This inventory separation and cutover is the most important new implementation requirement. It needs actual v4 fork tests. The economic model implements continuous liquidity equations and ledger conservation, not production Solidity, fee routing compatibility, or MEV security.

## 10. The permanent cash policy

After resolving accepted obligations and restoring defined operating coverage, allocate public market fee receipts as follows:

| Destination | Share of collected market fees | Equivalent share of gross eligible trading at 5 percent |
| --- | --- | --- |
| Locked protocol liquidity | 10 percent | 0.50 percent |
| GRAIL fund | 45 percent | 2.25 percent |
| Punk fund | 45 percent | 2.25 percent |

Before the first 1 ETH GRAIL and its mint cost are funded, its priority is the entire 90 percent prize portion. After that milestone, the normal allocation starts. Required reserve repair can delay these discretionary allocations.

The small retained GRAIL feed from gameplay preserves baseline progression when token trading is quiet. Market income buys stronger and more frequent headline opportunities. Maintain one active ETH headline, with future growth and replacement resources separately tracked, rather than filling the board with more large items that increase its quote.

After genesis, 100 percent of truly distributable game surplus purchases and burns ENGINE. There are no continuing free rewards, staking emissions, or founder payment claims.

ENGINE prize purchases transfer tokens to players. They are genuine purchases but those players can resell. Profit funded burns permanently remove acquired tokens. Report the two separately.

Fees paid by player sales of game prizes are economic recycling of those payouts, not proof of independent new funding. Game purchases are not charged a fee merely to manufacture a flattering revenue loop.

## 11. Punk acquisition and sponsorship

The Punk fund exists whether or not a sponsor participates. It can acquire a correctly priced Punk outright once an executable acquisition is covered. No guaranteed acquisition date or future NFT appreciation is assumed.

At launch, support one optional active sponsorship. Use a posted collection offer with a conservative reference price P, never above 30 ETH for the first offer. This is a maximum program input, not a statement of current Punk value. Select the actual posted P from verified executable market evidence and freeze it for an accepted deal.

The initial posted offer is:

| Term | Selected policy |
| --- | --- |
| Asset | Verified Wrapped CryptoPunk |
| Minimum funded Punk pot before accepting | 1 ETH |
| Maximum chance on an accepted eligible draw | 1 in 100,000 |
| Compensation for a completed eligible draw while active | 2 × P / 100,000 ETH |
| Cumulative compensation ceiling | 1.5 × P |
| Sponsor voluntary reclaim | After 30 days, while unwon and not fully compensated, respecting pending requests |
| Early win | Winner receives NFT; earned credit survives; future unpaid compensation ends |
| Full cap reached | Sponsor loses payment and reclaim rights; prize becomes protocol owned |

For P = 30 ETH, payment is 0.0006 ETH per eligible draw and the cap is 45 ETH. One thousand draws while the asset remains active generate 0.6 ETH compensation. The maximum probability of an award within those 1,000 draws is approximately 0.995 percent. A win can still occur immediately.

Compensation is reserved from the Punk pot before accepting the related risk and paid on settlement. It is never drawn from your mint income or counted simultaneously as buyback profit. Prior accumulated pot funds support these earned payments, not a signup windfall.

When further exposure cannot be funded, stop accepting it, settle pending requests, and remove or return the prize under the contract's disclosed termination rule. Do not expose the sponsor to further draws while promising unfunded payments. The ordinary game can resume without that asset.

At the static opening board, an assigned value around 16.93 ETH produces approximately 1 in 100,000 odds. The live guard uses actual weights and pending exposure, not this static estimate. If ordinary inventory depletes, replenish it or stop accepting sponsored draws rather than silently increasing sponsor risk.

An outright purchase is preferred over accepting a new sponsorship when the treasury can buy an acceptable NFT at a lower fully funded cost. An existing sponsorship is not retroactively repriced or subordinated.

The posted deal is an offer, not evidence a holder will accept it. Baseline launch does not depend on acceptance.

## 12. Creator income and modeled activity

No additional operator charge is introduced. Real newly minted Shapes generate creator fees. The model assumes replacement mints rather than reusing existing stock, so actual revenue can be lower when inventory is reused.

| Paid draws per day | 14 day creator gross mint fees | 14 day ENGINE prize purchases | Post genesis monthly ordinary retained allocation |
| --- | --- | --- | --- |
| 100 | 1.805 ETH | 8.339 ETH | 1.401 ETH |
| 300 | 5.416 ETH | 25.018 ETH | 4.204 ETH |
| 750 | 13.540 ETH | 62.545 ETH | 10.510 ETH |

The last column is a static contribution estimate before additional unmodeled costs or reserve repairs, not a forecast of executed burns. During genesis, actual eligible surplus instead funds rewards.

At 300 daily draws, the modeled genesis additionally spends about 1.814 ETH on rewards from ordinary surplus after recovering the 0.148 ETH opening mint expense. That is distinct from the 25.018 ETH of prize backing purchases.

Gross mint income is not personal net profit. The creator supplies the 5 ETH and pays separate setup costs. Initial fees funded by the creator's own contribution are not new outside income. No personal recovery of the original contribution is promised.

## 13. Stress test results

The attached code runs 38 small scenarios using continuous concentrated liquidity mathematics. It uses the exact proposed static board, 40.10 percent ENGINE selection probability, the actual modeled backing, a 100 million finite bonus, 0.25 ETH market seed, and public resale access after one day.

It asserts ETH and token custody conservation after each modeled day. It does not fabricate ETH to fill sales. It does not assume that rewards generate more draws. External buyers in the test retain what they buy, and their budgets are independent assumptions.

| Draws/day | Immediate farmer sale fraction | Outside buying budget/day after day one | Market ETH after day 14 | End spot / initial spot |
| --- | --- | --- | --- | --- |
| 100 | 80 percent | 0 | 0.131 | 0.196 |
| 300 | 80 percent | 0 | 1.697 | 0.728 |
| 300 | 80 percent | 0.25 ETH | 4.582 | 0.968 |
| 300 | 95 percent | 0 | 0.135 | 0.096 |
| 300 | 95 percent | 0.25 ETH | 0.538 | 0.412 |
| 750 | 80 percent | 0 | 9.329 | 1.150 |

With 300 daily draws, 80 percent selling, 0.25 ETH daily outside budgets, and only half of ENGINE backing actually converted, the model ends with 2.248 ETH in the market and a spot price ratio of 0.796. Unconverted backing remains a funded claim; it is not treated as an executed purchase.

In the 300 draw / 80 percent sale / no outside buying case, final supply is approximately 133.59 million tokens. The scheduled 100 million reward allocation is therefore roughly 75 percent of final supply, despite being 10 percent of the original maximum. This is an economically important distinction.

The results support the chosen mechanism under specific activity and retention assumptions. They also show a market that can collapse under low activity or near universal selling. The design protects funded game liabilities from that market loss; it does not guarantee a token price or a profitable farming exit.

The model excludes actual v4 integer rounding, deployed callbacks, claim execution gas, MEV, slippage limits, random ordinary board paths, changing GRAIL inventory, and real demand feedback. It does not replace the actual five ETH opening fork test.

## 14. Why people might participate

Players receive funded prize opportunities. Farmers compete for a finite token allocation earned by every successful paid draw, with random larger allocations. Early players get original access before public resale buying opens.

Buyers can acquire the positions farmers choose to sell. They know the exact emissions endpoint, see a real game operating, and can evaluate its capacity to produce future buys and burns.

Holders receive neither treasury redemption rights nor a promised dividend. Their thesis is future independent prize demand, actual game funded purchases, a hard end to original distribution, and a functioning market. The first two require market behavior; the latter two can be enforced by contracts.

ENGINE outcomes create larger gross purchase flow than operating surplus alone. This makes the game relevant to the coin after farming ends. It does not make all prize purchase volume permanent buy pressure.

A game with no sustained paid demand cannot be repaired by token distribution alone. A market with everyone selling and nobody valuing future ownership cannot fund profitable exits for everyone. These risks remain explicit rather than being masked by locks or an asserted price floor.

## 15. Upgrade and trust policy

Use a fixed hook address with a narrowly upgradeable policy module, a multisig, and a 72 hour public timelock. Supply ceiling, issuance deadline, earned prize rights, genesis attribution, and protocol liquidity custody must be enforced outside the replaceable module.

The normal fee can be reduced within the disclosed bound but cannot exceed 5 percent through an upgrade. Emergency powers can stop new risk, not confiscate earned assets or erase claims. A pause does not reset genesis.

After genesis, do not retain a discretionary transfer lock. Claims and existing circulation must remain usable even if new play pauses. Other markets may exist and can reduce canonical fee capture.

An orderly permanent shutdown is announced at least 30 days in advance unless required to stop new unsafe risk. Accepted draws and credited claims settle first. Unwon sponsored assets return under their agreements. Remaining protocol owned prize assets are redeemed only after obligations are discharged. Residual game ETH is committed to bounded public market purchases and burns, not a personal creator refund. Locked market liquidity is not emptied to pay the creator.

## 16. Delivery boundaries

Keep the original FWA game integration and the useful foreign NFT work from the current engine branch. Remove outside founder finance from this release. Add the revised pack mode, genesis distribution, primary/resale inventory accounting, custom market policy, and finite liquidity transition.

No staking, perpetual emissions, token holder odds advantages, multiple games, or multiple simultaneous sponsor agreements in the first release.

Existing mainnet contracts must be tested on real forks without replacing them with mocks. Verify the actual live FWA edge, VRF settings, Shape fee, request limits, and deployment access. Publish true player costs rather than only a favorable opening quote.

The required launch checks include a five ETH opening with actual inventory, delayed maintenance, an early maximum prize, delayed ENGINE claims, every genesis boundary, private and public swap authentication, exact primary quota enforcement, holder sales through alternate paths, pending rewards at close, liquidity migration, and sponsor early win or funding exhaustion.

The custom resale quota and original inventory burn are new and have not been implemented by the modeling work. A failure there would invalidate the launch promise, so they require explicit tests and independent review.

Legal review of paid chance games, token distribution, and sponsor arrangements is a prerequisite. Using NFTs and ETH does not by itself remove applicable requirements.

## Sources and evidence

The arithmetic is reproducible with check_design.py, board_economics.json, and the scenario outputs in the companion model archive. selected_design.json contains the chosen inputs. DECISION_REGISTER.md records the choices and tradeoffs.

Existing pricing formula: ripe0x/draw-shapes, commit 2c70c15acf8d3fd364b815a2e60b73d2483027ec, src/lib/PricingLib.sol, listing price and weight functions.

FWA primary documentation: https://v1.fwa.fun/docs/custom-standard, https://v1.fwa.fun/docs/custom-settings, https://www.fwa.fun/docs/community-pools, https://v1.fwa.fun/docs/fwa-rewards.

Uniswap primary documentation: https://developers.uniswap.org/docs/protocols/v4/concepts/hooks, https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting.

Randomness integrity: https://docs.chain.link/vrf/v2-5/security.
