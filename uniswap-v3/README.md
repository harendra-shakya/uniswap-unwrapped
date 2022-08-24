NOTE: Make sure to understand uniswap v2 first before start understanding this or otherwise you won't understand many things. 

The main functionality which is added in v3 is concentrated liquidity. 

## Concentrated liquidity

- Concentrated liquidity means LPs can provide liquidity between any price range/tick.

- In v1 and v2, liquidity is always spread across [0, infinite], in v3 liquidity can be concentrated e.g. from range 2000 to 3000.

- Thus v3 results in higher capital efficient.

- Let's say if I provide liquidity in the range [1200, 2800] the capital efficiency will then be 4.24x higher than v2 with the range [0, infinite].

- As each tick has a different liquidity depth, the corresponding pricing function x * y = k also won’t be the same!

### Ticks

**Tick** - Ticks are the measure of upward and downward movement in price of a security. 1 tick is the 0.01% increase and decrease in price.

By slicing the price range [0, infinite] into numerous granulues ticks, trading in uniswap is highly similar to trading on order book exchange, with only three differences.

1. The price of each tick is predifined by the user instead of being proposed by the user.

2. Trades that happen within a tick still follows the pricing function of the AMM, while equation has to be updated once the price crosses tick.

3. Orders can be executed with any price within the price range, instead of being fulfilled at the same one price on order book exchanges.

With the tick design, Uniswap v3 possesses most of the merits of both AMM and an order book exchange!

### How the price to tick decided?

- Traditonally uses 1 cent but uniswap uses 0.01% so it's not the subration while calculates by division.

- Price range of ticks are decided by this equation

**p(i) = 1.0001^i**

- With this equation the prices can be recorded in index form instead of some crazy numbers such as 1.01215421210

e.g. when i = 1, p(1) = 1.0001; when i = 2, p(2) = 1.00020001.

p(2) / p(1) = 1.00020001 / 1.0001

## Core contracts

### 1. The Pool

- It is the core contract that holds all liquidity and lets you swap tokens.

- UniV3 uses some calculas.

- The continuous price curve uses is broken into ticks. Each of these ticks has a certain amount of liquidity, based on how much liquidity is assigned by liquidity provider.

- When you start a swap, the contract steps through each tick, beginning from current price and consumes liquidity from it.

- If your swap size is sufficient to consume all liquidity from your tick it moves the another tick. It keeps moving to next tick until

A) your desired token amount has been fulfilled and the swap succeeds,
or
B) the next tick is below your minimum specified price and your token output is not reached, so the swap fails.

#### Mint function

- Similar to v2 but you need to provide tickLower and tickUpper

- Two things to remember -

1. This is a low level function, you requires to call it from a smart contract.
2. This function does not mints ant nft, only creates the liquidity position.

### 2. Factory

- Deploys pools

### 3. Pool deployer

- The factory contact has some under-the-hood detail which most users don't need to interact with, so Uniswap v3 provides an high level interface contact, the pool deployer. This contract gives a very simple and easy way to deploy new pools with a high-level function call.

## Peripery contract

### 1. Non-fungible position Manager

- For calling low level mint function uniswap gives us this contract

- It servers two purpose-

1. Adding, removing and modifying liquidity positions in any uniswap pool.
2. Representing those liquidity positions as nfts.

- The owner of nft is then owner of liquidity position. If user sends nft to someone then he will be the owner.

### 2. Token Descriptor

- The art and detail is all generated on-chain by Nonfungible Token Position Descriptor contract.

### 3. Router

- A contract to use swap function.

### 4. Lenses

- Utility contract for retrieve the information from pools.

- The **Quotor** works like a skeleton router. It is designed to simulate swap call, for the purpuse of retrieving the output token amounts. This contract design is gas intensive and should not be use on chain but rather off chain.

- The **TickLens** is a tool to retrieve the liquidity at every tick for a given pool. This is used to populate the liquidity depth graphs you see on Uniswap info website

### 5. Staker

- This contact allows LPs to stake their LP nfts. 

- This contract is used to incentivise the LPs. They will be rewarded in UNI tokens.

Best resources - 
1. https://bowtiedisland.com/concentrated-liquidity-uniswap-v3-overview/
2. https://medium.com/taipei-ethereum-meetup/uniswap-v3-features-explained-in-depth-178cfe45f223