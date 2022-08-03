pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';

/* What is libraries/UQ112x112 ? 

 * Solidity doesn't support floating point numbers so uniswap uses binary point format to encode and manipulate data

 * And if you're wondering why solidity doesn't support floating point numbers then open your browser console and calculate `0.1 + 0.2`.
   This will eventually cause rounding errors

 * UQ112x112 means 112 bits uses for left of the decimal and 112 uses for right of the decimal, which is total 224 bits.
   224 leaves 32 bits from 256 bits(which is max capacity of a storage slot)

 * Price could fit in 224 bits but accumulation not. The extra 32 bits is for price accumulation.

 * Reserves are also using this format, so both reserves can fit in 224 bits and 32 bits is lefts for timestamp.

 * Timestamp could be bigger than 32 bits that's why they mod it by 2**32, so it can fit in 32 bits even after 100 years. (check `_update` function)

 * They are saving 3 variables (reserve0 + reserve1 + blockTimestampLast) in a single storage slot for saving gas as we know storage is so expensive
 
 * Ethereum storage: https://programtheblockchain.com/posts/2018/03/09/understanding-ethereum-smart-contract-storage/

 * Uniswap v2 whitepaper: https://uniswap.org/whitepaper.pdf (2.2.1 Precision)

 */

import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol'; // it is for flash swaps

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10**3;
    // the purpose of `MINIMUM_LIQUIDITY` is to prevent division by zero.

    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)'))); // it is a function selector https://docs.soliditylang.org/en/v0.8.15/abi-spec.html?highlight=function%20selector#function-selector

    address public factory; // address of the factory contract which creates pai contract
    address public token0; // address of a token of this pair
    address public token1; // address of another token of this pair

    uint112 private reserve0;    // supply of token0           //  -------------
    uint112 private reserve1;   // supply of token1           //               |----> these 3 variables stored in single storage slot
    uint32  private blockTimestampLast;                      //   --------------

    uint public price0CumulativeLast; // used to hold cumulative price
    uint public price1CumulativeLast; // same but for token1
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event
    // * It's the constant product formula

    uint private unlocked = 1; // is being used in lock modifier to protect reentrancy attack 

    /* A reentrancy attack occurs when a function makes an external call to another untrusted contract. 
     * Then the untrusted contract makes a recursive call back to the original function in an attempt to drain funds.
     * https://hackernoon.com/hack-solidity-reentrancy-attack
     */
     
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    /* _safeTransfer ->
     * Due to a bug in openzeppelin contracts
       every token which got affected returns nothing (it supposed to return a bool) on `transfer` function, e.g. tokens like TUSD, BNB etc.
     * so to check the success of every token we are wrapping it into a function
     * More info: https://soliditydeveloper.com/safe-erc20 (must read)

     * For understanding we are calling
        * Good token -> which implements erc20 standard correctly, returns bool
        * Bad token -> which doesn't implement erc20 standard correctly, and returns nothing

     * Deconstructuring -

        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        // * Here we are calling tranfer function with selector

        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
        // * `success` -> means succes of calling function from `token.call`

        // * `data.length == 0` -> 
                        * (for bad token) 
                        * This is the case where a token doesn't returns nothing while calling tranfer function due to that bug
                        * So we are checking `data.length == 0`,
                          if `data.length = 0` it does mean that tranfer function of bad token returned nothing (if success), and uniswap will accept this token.

        // * `abi.decode(data, (bool))` -> 
                        * (for good token) 
                        * we are decoding the returned data which is a bool and cheching if it's true

    
     * We need `success` & `abi.decode(data (bool))` or `success` & `data.length == 0` for verifying success.
     */

    event Mint(address indexed sender, uint amount0, uint amount1);
    // emitted when deposit liquidity
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    // emitted when withdraw liquidity
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    // * emitted every time tokens are added or withdrawn regardless of reason, to provide the latest reserve information (and therefore exchange rate)


    constructor() public {
        factory = msg.sender;
        // * as we know factory contract is creating this pair contract
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        // * could only be called by factory contract
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        // * `balance0 <= uint112(-1)` -> this is checking the balance should NOT be greater than 112 bits, it is protecting against overflow
        // * `uint112(-1)` is maximum value of uint112
        // * balance0 & reserve0 both mean the same thing here as balance is the balance of the contract and reserves are added as same as balance
        // * reserve is just not updated yet, and reserve is required to calculate price0CumulativeLast
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        /* we divide any number it will be same as original
         * e.g. 5000 % 2**32 = 5000 (check in your console)
         * but it's valid if value is smaller than 2**32
         * the value of 2**32 is 4294967296
         * `4294967296 - 1` is allowed but if we use 4294967296 or greater, the value will be reset (try it yourself on browser console)
         * that's why they are modding it by 2**32, so if the value is greater than this, it gets reset.
          Note: Always double check what I am writing. This is what I can understand
         */
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            /* this `timeElapsed > 0` making sure to protect against flash loan attacks
             * only first transaction of a block will trigger this if statement
             * transactions after that (in the same block) will have 0 timeElapsed
             * as blockTimestampLast is getting updated in last of `_update` function
             * so no one can manipulate price of a asset with flash loans
             */
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
            /* uniswap is also a price oracle
             * It is a Time Weighted Average Price Oracle (TWAP).
             * Uniswap calculates the price everytime a swap happens
             * it calculates average price of security over a specified amount of time
             * it is using price0CumulativeLast for calculating price 
             * `price0CumulativeLast` is accumulating price of assets so later we can calculate the price of a asset
             * UQ112x112 library is for encoding floating point numbers as solidity only support intergers
             * `UQ112x112.encode(_reserve1)` is encoding so floating point numbers don't cause any problem
             * `(UQ112x112.encode(_reserve1).uqdiv(_reserve0)` is dividing it by reserve of another token coz it's how a AMM works.
             * multiplying `timeElapsed` as it is needed for mathematical formula
             * Please look at this for clear understanding https://docs.uniswap.org/protocol/V2/concepts/core-concepts/oracles (must read)
             * with `price0CumulativeLast` & timeStamp we can calculate average price across any time interval.
             */

        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        // * updating reserves
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {   
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                // * `rootK` ----------> this is root of current constant 
                uint rootKLast = Math.sqrt(_kLast);
                // * `rootKLast`-------> this is root of previous contant (constant = reserve0 * reserve1)
                if (rootK > rootKLast) {
                // * so if current root constant is greater than previous root constant then it's true
                // *  `_kLast` is getting updated in the last of `mint` and `burn` function if fee is on
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    // * this formula is mentioned here https://docs.uniswap.org/whitepaper.pdf (2.4 Protocol fee)
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
            // * If protocol fee is off, they are setting kLast = 0;
            // * Maybe they are doing it coz if they turn off fee they want kLast to be 0 for the next time when they turn on
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        /* steps -
         * 1. liquidity provider uses router contract to deposit liquidity
         * 2. Router contract sends assets of liquidity provider to this address
         * 3. Then we calculate liquidity tokens to be minted
         * 4. And mint liquidity tokens for liquidity provider
         * 5. Update the reserves with `_update` function
         */
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        // * reserve0 and balance is the same thing, it's just reserves are not updated yet
        // * so reserve0 and balance0 supposed to be same but it's not as reserves are not updated yet
        // * so we are subracting `reserve0` from `balance0` so we can get the amount.
        uint amount1 = balance1.sub(_reserve1);
        bool feeOn = _mintFee(_reserve0, _reserve1);
        /* uniswap v2 includes 0.05% protocol fee that can be turned on and off
         * if the fee address is set, the protocol can earn 1/6 cut of 0.3%,
         * it means traders still have to pay 0.3% but liquidity providers will receive 0.25% and 0.05% will be earned by protocol 
         * collecting 0.05% on every trade will impose additional gas cost 
         * that's why uniswap collects accumulated fees when liquidity is deposited or withdrawn.
         */
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // * `totalSupply` is coming from `UniswapV2ERC20`
        // * by gas savings they mean, that they are storing it in memory so there will be no need to read it from storage variable

        if (_totalSupply == 0) {
            // * This will be mostly used in beginning as total supply is 0 in beginning
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            // * uniswap v2 initially mints shares equal to geometric mean of amounts deposited
            // * please refer to https://docs.uniswap.org/whitepaper.pdf (3.4 Initialization of liquidity token supply)
            // * subtracting MINIMUM_LIQUIDITY as we are minting it here
           _mint(address(0), MINIMUM_LIQUIDITY);
           /* minting tokens to address(0)
            * to permanently lock the first MINIMUM_LIQUIDITY tokens
            * total supply will be increase to MINIMUM_LIQUIDITY from 0 so we can prevent division by zero
            */
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
            /* totalSupply is total liquidity all liquidity providers has added
             * `amount0` ------------> amount that a liquidity provider is entering
             * `_reserve0` ----------> total reserves (balance of a asset without including amount which is being deposited)
             * `_totalSupply` -------> total supply of liquidity tokens
             * `amount0 / reserves` ----------> % of amount of a asset a liquidity provider is adding
             * `amount0.mul(_totalSupply) / _reserve0` -------------> * multiplying it by `_totalSupply`
                                                                      * it is how many liquidity tokens you should get
             *  QUESTION left: What are they taking minimum from both?
             */
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1); // updating reserves and price0CumulativeLast
        if (feeOn) kLast = uint(reserve0).mul(reserve1);
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        /* steps -
         * 1. liquidity provider uses router contract to withdraw liquidity
         * 2. Router contract sends liquidity tokens of liquidity provider to this address
         * 3. Then we burn that liquidity tokens
         * 4. And send assets back to liquidity provider
         * 5. Update the reserves with `_update` function
         */

        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];
        /* from router contract `removeLiquidity` function, user transfers his liquidity token
         * and then we are chechking balance of this contract with `balanceOf[address(this)]`
         * balanceOf is coming from ERC20 contract
         */

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        /* liquidity tokens are working as shares, as your 1000 tokens will not become 1500.
         * but you are getting the % value of total pool 
         * `liquidity` ------------> liquidity tokens that a liquidity provider has
         * `_totalSupply` ---------> total supply of liquidity tokens
         * `balance0` -------------> balance of a specific asset
         * liquidity / _totalSupply ---------> how much % of liquidity tokens they have
         * liquidity.mul(balance1) / _totalSupply ------------> * multiplying it by balance of the asset
                                                                * then liquidity provider will get their original + fee amount
         */
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        // * buring the liquidity tokens as you are withdrawing it
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        // * transferring the asset amounts to liquidity provider  
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        // * again updating the balance so we can update reserves in `_update` function 

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        // Note: First read swap functions in periphery contract to understand this clearly
        /* steps -
         * 1. trader uses router contract to swap tokens
         In periphery contract - 
         * 2. sends tokenA to this contract
         * 3. calculates tokenOut
         * 4. Then iterate over path array and swap tokens untill desired token come
         In core contract
         * 5. then we sends the token to trader
         * 6. Update the reserves with `_update` function
         */
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        // * More info: https://soliditydeveloper.com/stacktoodeep 
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        // * only one token will be transfer as by reading periphery contract we know amount of one token will be 0
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data); // * this function is for flash swaps
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        // * now reading the balance again to update reserve
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        /* `amount0In`  -------------------> amount which user sent to us
         * `balance0 > _reserve0` ---------> token which is sent to user by us will have 0 amountIn
         * `balance0`   -------------------> current balance of token
         * `_reserve0`  -------------------> balance before user sending amount
         * `amount0Out` -------------------> amount which it being sent to user
                                             subtracting it from reserve as we need to find amountIn, and update reserve
         */
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));  
        /* they can not do something like this
           balance * 0.3/100
           that's why they are first multiplying it by 1000 and subracting amountIn * 3 (3 from 0.3% fee)
         */
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        // * this require statement is for checking that contract has enough funds for next time or not
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /* somtimes reserves goes out of sync with contract balance
       that's why we have `skim` and `sync` functions
     * `skin` -> you transfer extra amount to `to` address
     * `sync` -> you uses `_update` function to make them sync
     */

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
