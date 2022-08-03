pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo; // address for protocol fee
    address public feeToSetter; // address allowed to to `feeTo`

    mapping(address => mapping(address => address)) public getPair; // to get pair
    address[] public allPairs; // to store all pairs

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    // * this function is for creating new pools/pair
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        // * `bytecode` --> to create contract we need code of the contract
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        // * enconding tokens
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
            // * creating contract with opcodes
        }
        IUniswapV2Pair(pair).initialize(token0, token1); // using `initialize` function in IUniswapV2Pair
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
        /* uniswap v2 includes 0.05% protocol fee that can be turned on and off
         * if the fee address is set, the protocol can earn 1/6 cut of 0.3%,
         * it means traders still have to pay 0.3% but liquidity providers will receive 0.25% and 0.05% will be earned by protocol 
         * collecting 0.05% on every trade will impose additional gas cost 
         * that's why uniswap collects accumulated fees when liquidity is deposited or withdrawn.
         */
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
