pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';

/* libraries/UQ112x112 -> 

 * Solidity doesn't support floating point numbers so uniswap uses bunary point format to encode and manipulate data

 * And if you're wondering why solidity doesn't support floating point numbers then open your browser console and calculate `0.1 + 0.2`. This will eventually cause rounding errors

 * It means 112 bits uses for left of the decimal and 112 uses as a right of decimal, which is total 224 bits.

 * 224 leaves 32 bits from 256 bits (which is max capacity of a storage slot)

 * Price could fit in 224 bit but accumulation not. The extra 32 bits is for price accumulation.

 * Reserves are also using this format, so both reserves can fit in 224 bits and 32 bits is lefts for timestamp.

 * Timestamp could be bigger than 32 bits that's why they mod it by 2**32, so it can fit in 32 bits even after 100 years. (check `_update` function)

 * They are saving 3 variables in a single storage slot for saving gas as we know storage is so expensive(look at line 35, 36, 37)

 * Ethereum storage: https://programtheblockchain.com/posts/2018/03/09/understanding-ethereum-smart-contract-storage/

 * Uniswap v2 whitepaper: https://uniswap.org/whitepaper.pdf

 * /// QUESTION ////
  * 1. And why it is required to store timestamp with reserves ??
 
 * Idk about them, if you know then please fork and write.

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
    uint112 private reserve1;   // supply of token1           //               |----> these 3 variables uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast;                      //   --------------

    uint public price0CumulativeLast; // used to hold cumulative price
    uint public price1CumulativeLast; // same but for token1
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event
    // * It's the constant product formula

    uint private unlocked = 1; // is being used in lock modifier to protect reentrancy attack 

    /* A reentrancy attack occurs when a function makes an external call to another untrusted contract. 
     * Then the untrusted contract makes a recursive call back to the original function in an attempt to drain funds.
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
     * Due to a bug in openzeppelin contracts, every token which got affected returns nothing (it supposed to return a bool) on `transfer` function, e.g. tokens like TUSD, BNB etc.
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
                        * So we are checking `data.length == 0`, if `data/length = 0` it does mean that tranfer function of bad token returned nothing (if success), and uniswap will accept this token.

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

    /*
     *
     */

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        // * `balance0 <= uint112(-1)` -> this is checking the balance should NOT be greater than 112 bits, it is protecting against overflow
        // * `uint112(-1)` is maximum value of uint112
        // * balance0 & reserve0 both mean the same thing here as balance is the balance of the contract and reserves are added as same as balance
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        /* we divide any number it will be same as original
         * e.g. 5000 % 2**32 = 5000 (check in your console)
         * but it's valid if value is smaller than 2**32
         * the value of 2**32 is 4294967296
         * `4294967296 - 1` is allowed but if we use 4294967296 or greater, the value will be reset (try it yourself on browser console)
         * that's why they are modding it by 2**32, so if the value is greater than this, it gets reset.
         */
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
            // https://docs.uniswap.org/protocol/V2/concepts/core-concepts/oracles
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
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        // * Liquidity provider adding amount0 for token0
        uint amount1 = balance1.sub(_reserve1);
        // * same but for token1

        bool feeOn = _mintFee(_reserve0, _reserve1); // calculating protocol fee (it is off currently)
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // * `totalSupply` is coming from `UniswapV2ERC20`

        if (_totalSupply == 0) {
            // * This will be mostly used in beginning as total supply is 0 in beginning
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
           _mint(address(0), MINIMUM_LIQUIDITY);
           /* minting tokens to address(0)
            * to permanently lock the first MINIMUM_LIQUIDITY tokens
            * total supply will be increase to MINIMUM_LIQUIDITY from 0 so we can prevet division by zero
            */
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
            /* `amount0 / reserves` is percentage
             * `amount0.mul(_totalSupply) / _reserve0` is percentage of `_totalSupply`
             * so it is taking minimum of both token
             */
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1); // line 142
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

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
