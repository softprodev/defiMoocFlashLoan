//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    address public constant userToLiquidate = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
    address public constant usdtAddr = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant wbtcAddr = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant wethAddr = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant uniswapV2FactoryAddr = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address public constant aaveLendingPoolAddr = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address public constant wbtcWethSushiSwapPool = 0xCEfF51756c56CeFFCA006cD410B03FFC46dd3a58;
    address public owner;
    uint8 public constant usdtDecimals = 6;
    uint8 public constant wbtcDecimals = 8;
    uint8 public constant wethDecimals = 18;

    
    // --- Hardcoded liquidation parameters ---- //
    uint public constant usdtToBorrow = 2916378221684;


    modifier onlyOwner {
        require(msg.sender == owner, "ERROR: Operate can only be called by the contract owner");
        _;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        owner = msg.sender;
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    receive() external payable {}

    // required by the testing script, entry for your liquidation call
    function operate() onlyOwner external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        //    *** Your code here ***

        // 1. get the target user account data & make sure it is liquidatable
        ILendingPool aaveLendingPool = ILendingPool(aaveLendingPoolAddr);
        uint256 healthFactor;
        (, , , , , healthFactor) = aaveLendingPool.getUserAccountData(userToLiquidate);
        // Ensure that liqudation is possible
        require(healthFactor / 10 ** health_factor_decimals == 0, "User is not liquidatable");

        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        // We want to borrow USDT from the Uniswap V2 USDT/WETH pair
        IUniswapV2Factory uniswapV2Factory = IUniswapV2Factory(uniswapV2FactoryAddr);
        address wethUsdtPairAddr = uniswapV2Factory.getPair(wethAddr, usdtAddr);
        IUniswapV2Pair wethUsdtPair = IUniswapV2Pair(wethUsdtPairAddr);

        // So now, we can go ahead and take out a flash loan for the desired amount of USDT
        wethUsdtPair.swap(0, usdtToBorrow, address(this), abi.encode("flash loan"));
        // Now program execution switches to uniswapV2Call
        // Below this line, we are assuming that UniswapV2Call and the swap (function) have executed

        // 3. Convert the profit into ETH and send back to sender
        IWETH weth = IWETH(wethAddr);
        weth.withdraw(weth.balanceOf(address(this)));
        console.log("The amount of ETH in our contract is %d\n", address(this).balance);
        payable(msg.sender).transfer(address(this).balance);
        console.log("The NEW amount of ETH in our contract is %d\n", address(this).balance);

        // END TODO
    }

    // required by the swap
    function uniswapV2Call(
        address,
        uint256,
        uint256 usdtFlashSwapped,
        bytes calldata
    ) external override {
        // TODO: implement your liquidation logic
        // In this function, we can assume that we have been given the desired amount of USDT

        // 2.0. security checks and initializing variables
        //    *** Your code here ***

        // 2.1 liquidate the target user
        {
        IERC20 usdt = IERC20(usdtAddr);
        // console.log("The amount of usdt is %d\n", usdt.balanceOf(address(this)) / 10 ** usdtDecimals );
        // console.log("The amount of usdt is %d\n", usdt.balanceOf(address(this)) );
        // console.log("The amount of usdt is %d\n", usdtFlashSwapped );
        ILendingPool aaveLendingPool = ILendingPool(aaveLendingPoolAddr);
        // We need to approve Aave to spend our usdt
        usdt.approve(aaveLendingPoolAddr, usdtFlashSwapped);
        aaveLendingPool.liquidationCall(wbtcAddr, usdtAddr, userToLiquidate, usdtFlashSwapped, false);
        }

        // --- Common vars for 2.2, 2.3 --- //
        IUniswapV2Factory uniswapV2Factory = IUniswapV2Factory(uniswapV2FactoryAddr);
        uint112 wethReserve;
        uint112 wbtcReserve;
        uint112 usdtReserve;
        IERC20 weth = IERC20(wethAddr);

        // 2.2 swap WBTC for other things or repay directly
        // So at this point we have our WBTC and we want to swap it for WETH
        {
        IERC20 wbtc = IERC20(wbtcAddr);
        uint256 balanceOfWbtc = wbtc.balanceOf(address(this));
        console.log("The amount of WBTC is %d\n", wbtc.balanceOf(address(this)) / 10 ** wbtcDecimals);

        // Let's swap all of our WBTC for WETH using Sushiswap (deeper liquidity is available)
        address wbtcWethPairAddr = wbtcWethSushiSwapPool;
        IUniswapV2Pair wbtcWethPair = IUniswapV2Pair(wbtcWethPairAddr);
        // wbtc.approve(wbtcWethPairAddr, balanceOfWbtc);
        wbtc.transfer(wbtcWethPairAddr, balanceOfWbtc);

        // How much WETH should we expect out?
        (wbtcReserve, wethReserve,) = wbtcWethPair.getReserves();
        uint256 wethToExepctToReceive = getAmountOut(balanceOfWbtc, wbtcReserve, wethReserve);
        
        wbtcWethPair.swap(0, wethToExepctToReceive, address(this), "");
        // Let's check how much WETH we now have
        console.log("The amount of WETH is %d\n", weth.balanceOf(address(this)) / 10 ** wethDecimals);
        }

        // 2.3 repay
        // Well, how much WETH do we need to give back in the pool in order to maintain the invariant x*y=k?
        address wethUsdtPairAddr = uniswapV2Factory.getPair(wethAddr, usdtAddr);
        IUniswapV2Pair wethUsdtPair = IUniswapV2Pair(wethUsdtPairAddr);
        (wethReserve, usdtReserve,) = wethUsdtPair.getReserves();
        uint256 wethToPayBack = getAmountIn(usdtFlashSwapped, wethReserve, usdtReserve);
        weth.transfer(wethUsdtPairAddr, wethToPayBack);
        console.log("The new amount of WETH is %d\n", weth.balanceOf(address(this)) / 10 ** wethDecimals);
    }
}
