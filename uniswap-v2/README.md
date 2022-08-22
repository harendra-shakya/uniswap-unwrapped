## What does uniswap do?

- Basically there are two types of users liquidity providers and traders

- Liquidity providers provide liquidity to the pool and in return they get third token that represents the partial ownership of the pool called liquidity token.

- Traders can swap tokens means then can provide a token and receive another token. The exchange rate is determined by the relative number of tokens in the pool e.g. pool has 8 USDC & 10 DAI then the value of USDC will be high. The pool takes a small percent as a reward for the liquidity pool.

- When liquidity providers want their assets back they can burn the liquidity token and receive back their assets, including the share of reward.

## Contracts

- Uniswap v2 is divided into 2 contracts, a core and a periphery. The division allow the core contract, which holds all assets and therefore it needed to be secure, to be simpler and easier audit. All the extra functionality required by traders can then be provided by periphery contracts.

## DATA AND CONTROL FLOWS

- Trader/liquidity provider interacts with periphery contract not with main core contract directly

## Swap

### Caller

1. Approve periphery contract to use trader's tokens
2. Trader uses router contract to swap tokens

### In the periphery contract (UniswapV2Router02.sol)

3. Sends tokenA to core contract
4. Calculates tokenOut
5. Then iterate over path array and swap tokens untill desired token come

### In the core contract (UniswapV2Pair.sol)

6. Then we sends the token to trader
7. Update the reserves with `_update` function

## Add Liquidity

### Caller

1. Approve periphery contract to use liquidity provider's tokens
2. Liquidity provider uses router contract to add liquidity

### In the periphery contract (UniswapV2Router02.sol)

3. Sends assets of liquidity provider to core contract

### In the core contract (UniswapV2Pair.sol)

3. Calculate liquidity tokens to be minted
4. Mint liquidity tokens for liquidity provider
5. Update the reserves with `_update` function

## Remove Liquidity

### Caller

1. Approve periphery contract to use liquidity provider's tokens
2. Liquidity provider uses router contract to withdraw liquidity

### In the periphery contract (UniswapV2Router02.sol)

3. Sends liquidity tokens of liquidity provider to core contract

### In the core contract (UniswapV2Pair.sol)

4. Burn liquidity tokens
5. Send assets back to liquidity provider
6. Update the reserves with `_update` function

## Resources I used -
- [Uniswap V2 docs](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/swaps)

- [Uniswap V2 whitepaper](https://docs.uniswap.org/whitepaper.pdf)

- [UNISWAP-V2 CONTRACT WALK-THROUGH](https://ethereum.org/en/developers/tutorials/uniswap-v2-annotated-code/)

- [Web3 Blockchain Developer](https://www.youtube.com/c/Web3BlockchainDeveloper) (All Solidity Study Groups)
