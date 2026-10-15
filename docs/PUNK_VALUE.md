# Punk value from native market data

Question: can the value of a CryptoPunk be read from chain data well enough to set sponsor deal terms?
Sources at mainnet block 26,170,000: CryptoPunksMarket `0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB` (`punksOfferedForSale`,
`punkBids`, `punkIndexToAddress`), CryptoPunksData `0x16F5A35647D6F03D5D3da7b35409D65ba03aF3B2` (`punkAttributes`),
Wrapped Cryptopunks `0xb7F7F6C52F2e2fdb1963Eab30438024864c313F6`.

Data files: `evidence/punks/market-26170000.csv` (every punk with an open public ask or a bid: 1,155 rows),
`evidence/punks/wrapped-26170000.csv` (373 wrapped punks). An ask is an offer with `isForSale` and `onlySellTo == 0`.

## Asks by type (ETH)

| type | count | floor ask | median ask |
|---|---|---|---|
| Alien | 1 | 5000.000 | 5000.000 |
| Ape | 1 | 1250.000 | 1250.000 |
| Female 1 | 126 | 32.730 | 78.070 |
| Female 2 | 119 | 32.720 | 88.880 |
| Female 3 | 112 | 33.890 | 99.470 |
| Female 4 | 47 | 42.600 | 98.000 |
| Male 1 | 201 | 31.490 | 80.000 |
| Male 2 | 182 | 35.000 | 100.000 |
| Male 3 | 253 | 36.970 | 101.000 |
| Male 4 | 95 | 36.980 | 100.000 |
| Zombie | 10 | 480.000 | 1443.500 |

Female 1-4 and Male 1-4 floors fall between 31.5 and 42.6 ETH. Alien and Ape have one ask each, Zombie ten, so those three
types have no usable floor.

## Bids by type (ETH)

| type | count | max bid | median bid |
|---|---|---|---|
| Ape | 1 | 0.000 | 0.000 |
| Female 1 | 3 | 0.010 | 0.000 |
| Female 3 | 2 | 30.700 | 15.350 |
| Female 4 | 1 | 34.500 | 34.500 |
| Male 1 | 3 | 32.800 | 31.100 |
| Male 2 | 1 | 0.020 | 0.020 |
| Male 3 | 1 | 45.000 | 45.000 |
| Male 4 | 2 | 45.000 | 22.500 |

14 punks have a bid. Seven are real (29.9 to 45.0 ETH). Seven are dust (0.02 ETH or less). The seven real bids sit at 0.8 to 1.2
times the floor ask of their type; five of those punks also carry an ask, 1.0 to 1.4 times the bid (3739: 32.8 vs 33.5,
4064: 29.9 vs 32.7, 7517: 31.1 vs 35.5; 5170 and 8264: 45.0 vs 65.0).

## Accessory multipliers

Multiplier = median over asked punks carrying the accessory of (ask / floor ask of the punk's type). Accessories with at least
5 asks: 82. Top 20 shown; the full list is the output of `punk_value.py`.

| accessory | asks | multiplier |
|---|---|---|
| Pilot Helmet | 7 | 27.19 |
| Beanie | 11 | 13.36 |
| Hoodie | 34 | 8.84 |
| Pink With Hat | 12 | 6.42 |
| Top Hat | 22 | 6.21 |
| Dark Hair | 16 | 5.99 |
| Welding Goggles | 10 | 5.38 |
| 3D Glasses | 45 | 5.26 |
| Pigtails | 18 | 5.23 |
| Pipe | 50 | 4.53 |
| VR | 53 | 4.46 |
| Big Beard | 15 | 4.29 |
| Smile | 26 | 4.16 |
| Regular Shades | 64 | 3.92 |
| Choker | 14 | 3.79 |
| Small Shades | 48 | 3.57 |
| Cowboy Hat | 22 | 3.57 |
| Clown Nose | 33 | 3.56 |
| Shadow Beard | 67 | 3.38 |
| Front Beard | 25 | 3.37 |

Median ask / type floor over all asks (k): 2.69. The median multiplier of a common accessory (Earring, 279 asks: 2.60) equals k,
so a multiplier measures the general ask markup, plus a premium for rare traits (Pilot Helmet, Beanie, Hoodie, Top Hat).

## Rule error

Error = |rule / ask - 1| over every asked punk. "in-sample" fits on all asks; "leave-one-out" refits without the punk being
evaluated. Rules:

- A: `floor(type)`
- B: `floor(type) x product(min(multiplier, 5))` (the rule in the brief)
- C: `floor(type) x k`
- D: `floor(type) x k x product(min(multiplier / k, 5))` (multiplier divided by k so the markup is counted once)

| rule | asks | fit | n | median | p90 |
|---|---|---|---|---|---|
| A floor(type) | all | in-sample | 1147 | 62.8% | 92.5% |
| B floor x multipliers (cap 5) | all | in-sample | 1147 | 440.1% | 1995.2% |
| C floor x k | all | in-sample | 1147 | 52.7% | 103.6% |
| D floor x k x (multiplier / k) | all | in-sample | 1147 | 43.7% | 115.0% |
| A floor(type) | all | leave-one-out | 1145 | 62.8% | 92.5% |
| B floor x multipliers (cap 5) | all | leave-one-out | 1145 | 447.3% | 2167.2% |
| C floor x k | all | leave-one-out | 1145 | 52.6% | 102.0% |
| D floor x k x (multiplier / k) | all | leave-one-out | 1145 | 50.1% | 129.4% |
| A floor(type) | <= 20x floor | in-sample | 1066 | 59.3% | 87.7% |
| B floor x multipliers (cap 5) | <= 20x floor | in-sample | 1066 | 387.5% | 1516.0% |
| C floor x k | <= 20x floor | in-sample | 1066 | 43.7% | 89.2% |
| D floor x k x (multiplier / k) | <= 20x floor | in-sample | 1066 | 37.9% | 93.1% |
| A floor(type) | <= 20x floor | leave-one-out | 1064 | 59.4% | 87.7% |
| B floor x multipliers (cap 5) | <= 20x floor | leave-one-out | 1064 | 387.1% | 1616.0% |
| C floor x k | <= 20x floor | leave-one-out | 1064 | 43.7% | 88.4% |
| D floor x k x (multiplier / k) | <= 20x floor | leave-one-out | 1064 | 44.4% | 110.4% |

## Conclusion

1. Rule B (floor x product of multipliers) fails: median error 440% to 447%. Each multiplier already contains the 2.7x ask
   markup, so a punk with three accessories is valued near 2.7^3 times floor.
2. Rule A (floor of type) has median error 63% and p90 93%. Asks sit above the floor by a median of 2.7x, so rule A is a floor
   estimate of the value, the lower bound of what an owner wants.
3. Accessory detail adds little: rule D improves on rule C in-sample (44% vs 53%) and loses the gain out of sample (50% vs 53%
   median, p90 129% vs 102%). The ask data does not support per-accessory pricing beyond a handful of premium traits.
4. Real bids cluster at the type floor (0.8 to 1.2 times), the level at which buyers are standing. Deal terms
   should anchor on `floor(type)` for the Male 1-4 and Female 1-4 types and be set by hand for Alien, Ape, Zombie and any
   punk carrying a premium trait (Pilot Helmet, Beanie, Hoodie, Top Hat, Pink With Hat).

Recommended rule: `value = floor(type)` with `floor` read as the lowest open ask of the type at deal time, with a manual
override list for premium traits and the three rare types. Rule C (`floor x 2.69`) fits asks better but measures wishes, not
what a punk sells for.

## Wrapped punks

373 wrapped punks (Male 1: 100, Female 1: 81, Male 2: 53, Female 2: 44, Male 3: 36, Female 3: 35, Female 4: 14, Male 4: 8,
Ape 1, Zombie 1). One has a standing native bid: #2756, 0.0001 ETH. The median bid over floor is therefore 0.00 and carries no
signal. The market records the wrapper contract as owner of every wrapped punk, so a native bid on one targets the
wrapper address. Wrapped punks trade as ERC-721 tokens on venues this survey does not read.

## Known gaps

- Asks are owner wishes. Median ask is 2.7 times the type floor, 42% of asks are round numbers in ETH, 50 asks exceed
  1,000 ETH, and one ask is a placeholder of about 1e42 ETH.
- Bids are rare: 14 punks, 7 of them dust.
- Only the public market state at one block is read. Sale history (`PunkBought` logs) is not read, so clearing prices,
  time-to-sell and the ask-to-sale discount are unmeasured.
- Offers and bids on NFT marketplaces for wrapped punks are unread.
- The Male and Female 1-4 split follows the first item of `punkAttributes`. Floors differ by up to 35% between the tones
  (31.5 to 42.6 ETH).
- Alien, Ape and Zombie floors derive from 1, 1 and 10 asks.
- The multiplier fit uses the same asks as the evaluation (in-sample) or leave-one-out; no held-out period exists.

## Reproduce

```
export F="--fork-url https://gateway.tenderly.co/public/mainnet --fork-block-number 26170000"
for s in 0 2500 5000 7500; do START=$s END=$((s+2500)) forge script script/survey/PunkSurvey.s.sol --sig "market()" $F; done
forge script script/survey/PunkSurvey.s.sol --sig "wrapped()" $F
python3 script/survey/punk_value.py evidence/punks/market-26170000.csv evidence/punks/wrapped-26170000.csv
```

`PunkSurvey.s.sol` reads the first storage slot of each struct in `punksOfferedForSale` (mapping slot 12) and `punkBids`
(mapping slot 13) through `vm.load`, and calls the full getters only for set flags. Chunk 0 truncates the market CSV.
