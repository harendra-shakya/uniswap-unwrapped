# Pools

There are 3 types of pools -

1. Plain pool
2. Lending pools
3. Meta pools

### Plain pools

- It's the simplest implementation of Curve, where all assets all assets in the pool are ordinary ERC-20 tokens.

### Lending Pools

- Some pools in curve are lending pools that means you can earn interest from lending as well as trading fees.

### MetaPools

- Metapools allow for one token to seemingly trade with another underlying base pool. e.g. we can create Gemini USD metapool: [GUSD, [3Pool]]

# Curve's AMM logic

### Constant sum formula

- imagine a exchange where 1 DAI = 1 USDC, this could be express as **x + y = C**
- but 1 USDC us not always equal to 1 DAI, there price might be $0.99 for 1 USDC and $1.01 for 1 DAI
- this will cause problem as everyone will sell their USDC for DAI with 2 cent of profit
    
### Constant product formula

- uniswap v2 uses **x * y = k**, which represents the less token there is the more expensive it gets
- but problem with that is that it might create so high slippage
- slippage refers to expected price vs the price that we got
- so for solving this problem, Curve finance combines **x + y = C** & **xy = K** 

## Let's create the formula

- constant sum formula = **x + y = D**

- constant product formula = **xy = (D/2)^2**

- The constant D has a meaning of total amount of coins when they have an equal price.

- **k = (D/2)^2**, you can also check this by putting different values for x and y

### After combining

- after combining the two equation above we will get the following formula, **x + y + xy = D + (D/2)^2**
- but its still not that effective as we thought of

### Making equation effective

- To make it more effective, we will multiply the **x + y = D** (constant sum) by a factor χ

- The point of χ is to give more importance to the low slippage part of the equation

- and we will get **χ(x + y) + xy = χD + (D/2)^2**

- so if χ is 0, **χ(x + y)** & **χD** cancels out, and we will get constant product formula

- and if χ is a very big number then the **xy** && **(D/2)^2** cancels out, and we get constant sum formula

- when χ is increases in number, the curve for this equation **χ(x + y) + xy = χD + (D/2)^2** flatens out (look at third graph for visualisation https://alvarofeito.com/articles/curve/#The-curve-compromise) (χ = chi)

### Normalizing

- but **χ** depends on the total number of coins in the pool. We want it to be normalized, so no-matter what depth the pool has, we can find it

- so we are multiplying **χ(x + y) = χD** by D, and we will get **Dχ(x + y) = χD^2**

- now new equation is **Dχ(x + y) + xy = χD^2 + (D/2)^2**

### Putting value of χ

- now putting **Axy/(D/n)^n** in place of **χ**

- and we will get **A2^2(x + y) + D = AD2^2 (D/2)^2 * D/xy**, this is the same equation mentioned in the curve's whitepaper (with different notations)

- when A = 0, you will get **constant product** **xy = k**

- and when A = infinite, you will get **constant sum** **x + y = C**

And we understood curve logic!!

Best resources -
1. https://curve.fi/files/stableswap-paper.pdf
2. https://alvarofeito.com/articles/curve/
3. https://www.youtube.com/watch?v=GuD3jkPgPgU&t=300s
