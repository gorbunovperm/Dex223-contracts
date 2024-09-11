// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.7.6;
pragma abicoder v2;

import './interfaces/IDex223Factory.sol';
import './interfaces/IDex223Autolisting.sol';
import '../interfaces/ITokenConverter.sol';
import '../interfaces/IERC20Minimal.sol';
import '../interfaces/ISwapRouter.sol';
import '../libraries/TickMath.sol';
import '../../tokens/interfaces/IERC223.sol';

interface IDex223Pool {
    function token0() external view returns (address, address);
    function token1() external view returns (address, address);
    function swapExactInput(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        bool prefer223,
        bytes memory data,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

contract MarginModule
{
    IDex223Factory public factory;
    ISwapRouter public router;

    mapping (uint256 => Order)    public orders;
    mapping (uint256 => Position) public positions;

    uint256 orderIndex;
    uint256 positionIndex;

    event NewOrder(address asset, uint256 orderID);

    struct Order
    {
        address owner;
        uint256 id;
        address[] whitelistedTokens;
        address whitelistedTokenList;
        uint256 interestRate;
        uint256 duration;
        address[] collateralAssets;
        uint256 minCollateralAmounts;
        address liquidationCollateral;
        uint256 liquidationCollateralAmount;

        address baseAsset;
        uint256 balance;

        uint8 state; // 0 - active
                     // 1 - disabled, alive
                     // 2 - disabled, empty

        uint16 currencyLimit;
    }

    struct Position
    {
        uint256 orderId;
        address owner;

        address[] assets;
        uint256[] balances;

        address[] whitelistedTokens;
        address whitelistedTokenList;

        uint256 deadline;

        address baseAsset;
        uint256 initialBalance;
        uint256 interest;
    }

    struct SwapCallbackData {
        bytes path;
        address payer;
    }

    constructor(address _factory, address _router) {
        factory = IDex223Factory(_factory);
        router = ISwapRouter(_router);
    }

    function createOrder(address[] memory tokens,
                         address listingContract,
                         uint256 interestRate,
                         uint256 duration,
                         address[] memory collateral,
                         uint256 minCollateralAmount,
                         address liquidationCollateral,
                         uint256 liquidationCollateralAmount,
                         address asset,
                         uint16 currencyLimit
                         ) public
    {
        Order memory _newOrder = Order(msg.sender,
                                orderIndex,
                                tokens,
                                listingContract,
                                interestRate,
                                duration,
                                collateral,
                                minCollateralAmount,
                                liquidationCollateral,
                                liquidationCollateralAmount,
                                asset,
                                0,
                                0,
                                currencyLimit);
        
        orderIndex++;
        orders[orderIndex] = _newOrder;

        emit NewOrder(asset, orderIndex);
    }

    function orderDeposit(uint256 orderId, uint256 amount) public payable
    {
        require(orders[orderId].owner == msg.sender);
        if(orders[orderId].baseAsset == address(0))
        {
            orders[orderId].balance += msg.value;
        }
        else 
        {
            // Remember the crrent balance of the contract
            uint256 _balance = IERC20Minimal(orders[orderId].baseAsset).balanceOf(address(this));
            IERC20Minimal(orders[orderId].baseAsset).transferFrom(msg.sender, address(this), amount);
            require(IERC20Minimal(orders[orderId].baseAsset).balanceOf(address(this)) >= _balance + amount);
            orders[orderId].balance += amount;
        }
    }

    function orderWithdraw() public
    {

    }

    function positionDeposit() public
    {

    }

    function positionWithdraw() public
    {

    }

    function positionClose() public 
    {

    }

    function takeLoan(uint256 _orderId, uint256 _amount, uint256 _collateralIdx, uint256 _collateralAmount) public
    {
        // Create a new position template.

        require(orders[_orderId].collateralAssets[_collateralIdx] != address(0));
        address[] memory _assets;
        uint256[] memory _balances;

        /*
    struct Position
    {
        uint256 orderId;
        address owner;

        address[] assets;
        uint256[] balances;

        address[] whitelistedTokens;
        address[] whitelistedTokenLists;

        uint256 deadline;

        address baseAsset;
        uint256 initialBalance;
        uint256 interest;
    }
    */
        Position memory _newPosition = Position(_orderId, 
                                                msg.sender,
                                                _assets,
                                                _balances,

                                                orders[_orderId].whitelistedTokens,
                                                orders[_orderId].whitelistedTokenList,

                                                orders[_orderId].duration,
                                                orders[_orderId].baseAsset,
                                                _amount,
                                                orders[_orderId].interestRate);
        positionIndex++;
        positions[positionIndex] = _newPosition;
        positions[positionIndex].assets.push(orders[_orderId].collateralAssets[_collateralIdx]);
        positions[positionIndex].balances.push(_collateralAmount);

        // Withdraw the tokens (collateral).

        IERC20Minimal(orders[_orderId].collateralAssets[_collateralIdx]).transferFrom(msg.sender, address(this), _collateralAmount);

        // Copy the balance loaned from "order" to the balance of a new "position"
        // ------------ removed in v2 as the values are filled during position creation ------------

        //positions[positionIndex].assets.push(orders[_orderId].baseAsset);
        //positions[positionIndex].balances.push(_amount);

        // Make sure position is not subject to liquidation right after it was created.
        // Revert otherwise.
        // This automatically checks if all the collateral that was paid satisfies the criteria set by the lender.

        require(!subjectToLiquidation(positionIndex));
    }

    function marginSwap(uint256 _positionId,
                        uint256 _assetId1,
                        uint256 _whitelistId1, // Internal ID in the whitelisted array. If set to 0
                                               // then the asset must be found in an auto-listing contract.
                        uint256 _whitelistId2,
                        uint256 _amount,
                        address _asset2,
                        uint24 _feeTier) public
    {
        // Only allow the owner of the position to perform trading operations with it.
        require(positions[_positionId].owner == msg.sender);
        address _asset1 = positions[_positionId].assets[_assetId1];
        
        // Check if the first asset is allowed within this position.
        if(_whitelistId1 != 0)
        {
            require(positions[_positionId].whitelistedTokens[_whitelistId1] == _asset1);
        }
        else 
        {
            require(IDex223Autolisting(positions[_positionId].whitelistedTokenList).isListed(_asset1));
        }
        
        // Check if the second asset is allowed within this position.
        if(_whitelistId2 != 0)
        {
            require(positions[_positionId].whitelistedTokens[_whitelistId2] == _asset2);
        }
        else 
        {
            require(IDex223Autolisting(positions[_positionId].whitelistedTokenList).isListed(_asset2));
        }

        // check if position has enough Asset1
        require(positions[_positionId].balances[_assetId1] >= _amount);
        
        // Perform the swap operation.
        // We only allow direct swaps for security reasons currently.

        require(factory.getPool(_asset1, _asset2, _feeTier) != address(0));
        
        // load & use IRouter interface for ERC-20.
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: _asset1, 
            tokenOut: _asset2,
            fee: _feeTier,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
            prefer223Out: false  // TODO should we be able to choose out token type ?
        });
        uint256 amountOut = ISwapRouter(router).exactInputSingle(swapParams);
        require(amountOut > 0);
        
        // TODO Check if we do not exceed the set currency limit.
        
        // add new (received) asset to Position
        positions[positionIndex].balances[_assetId1] -= _amount;
        positions[positionIndex].assets.push(_asset2);
        positions[positionIndex].balances.push(amountOut);
    }

    struct SwapData {
        address pool;
        address tokenIn;
        address tokenIn223;
        address tokenOut;
        uint24 fee;
        bool zeroForOne;
        bool prefer223Out;
        uint160 sqrtPriceLimitX96;
    }

    function resolveTokenOut(
        bool prefer223Out,
        address pool,
        address tokenIn,
        address tokenOut
    ) private view returns (address) {
        if (prefer223Out) {
            (address _token0_erc20, address _token0_erc223) = IDex223Pool(pool).token0();
            (, address _token1_erc223) = IDex223Pool(pool).token1();

            return (_token0_erc20 == tokenIn) ? _token1_erc223 : _token0_erc223;
        } else {
            return tokenOut;
        }
    }
    
    function executeSwapWithDeposit(
        uint256 amountIn,
        address recipient,
        SwapCallbackData memory data,
        SwapData memory swapData
    ) private returns (uint256 amountOut) {
        bytes memory _data = abi.encodeWithSignature(
            "swap(address,bool,int256,uint160,bool,bytes)",
            recipient,
            swapData.zeroForOne,
            amountIn.toInt256(),
            swapData.sqrtPriceLimitX96 == 0
                ? (swapData.zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : swapData.sqrtPriceLimitX96,
            swapData.prefer223Out,
            data
        );

        address _tokenOut = resolveTokenOut(swapData.prefer223Out, swapData.pool, swapData.tokenIn, swapData.tokenOut);

        (bool success, bytes memory data) = _tokenOut.call(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, recipient));

        bool tokenNotExist = (success && data.length == 0);

        uint256 balance1before = tokenNotExist ? 0 : abi.decode(data, (uint));
        require(IERC223(SwapData.tokenIn223).transfer(swapData.pool, amountIn, _data));

        return uint256(IERC20Minimal(_tokenOut).balanceOf(recipient) - balance1before);
    }

    function marginSwap223(uint256 _positionId,
        uint256 _assetId1,
        uint256 _whitelistId1, // Internal ID in the whitelisted array. If set to 0
    // then the asset must be found in an auto-listing contract.
        uint256 _whitelistId2,
        uint256 _amount,
        address _asset2, // TODO can it be ERC20 ?
        uint24 _feeTier) public
    {
        // Only allow the owner of the position to perform trading operations with it.
        require(positions[_positionId].owner == msg.sender);
        address _asset1 = positions[_positionId].assets[_assetId1];

        // Check if the first asset is allowed within this position.
        if(_whitelistId1 != 0)
        {
            require(positions[_positionId].whitelistedTokens[_whitelistId1] == _asset1);
        }
        else
        {
            require(IDex223Autolisting(positions[_positionId].whitelistedTokenList).isListed(_asset1));
        }

        // Check if the second asset is allowed within this position.
        if(_whitelistId2 != 0)
        {
            require(positions[_positionId].whitelistedTokens[_whitelistId2] == _asset1);
        }
        else
        {
            require(IDex223Autolisting(positions[_positionId].whitelistedTokenList).isListed(_asset2));
        }

        // check if position has enough Asset1
        require(positions[_positionId].balances[_assetId1] >= _amount);

        // Perform the swap operation.
        // We only allow direct swaps for security reasons currently.

        
        address pool = factory.getPool(_asset1, _asset2, _feeTier); 
        require(pool != address(0));
        
        address _asset1_20;
        address _asset2_20;

        // we need to use ERC20 version of Asset1 and Asset2 
        (address token0_20, address token0_223) = IDex223Pool.token0();
        (address token1_20, ) = IDex223Pool.token1();
        if (token0_223 == _asset1) {
            _asset1_20 = token0_20;
            _asset2_20 = token1_20;
        } else {
            _asset2_20 = token0_20;
            _asset1_20 = token1_20;            
        }

        SwapData memory swapData = SwapData({
            pool: pool,
            tokenIn: _asset1_20,
            tokenIn223: _asset1,
            tokenOut: _asset2_20,
            fee: _feeTier,
            zeroForOne: (_asset1_20 < _asset2_20),
            prefer223Out: true,
            sqrtPriceLimitX96: 0
        });

        SwapCallbackData memory data = SwapCallbackData({path: abi.encodePacked(_asset1_20, _feeTier, _asset2_20), payer: address(this)});
        
        uint256 amountOut = executeSwapWithDeposit(
            _amount,
            address(this),
            data,
            swapData
        );
        require(amountOut > 0);

        // TODO Check if we do not exceed the set currency limit.

        // add new (received) asset to Position
        positions[positionIndex].balances[_assetId1] -= _amount;
        positions[positionIndex].assets.push(_asset2);
        positions[positionIndex].balances.push(amountOut);
    }

    function subjectToLiquidation(uint256 _positionId) public returns (bool)
    {
        // Always returns false for testing reasons.
        return false;
    }

    function liquidate() public 
    {
        // 
    }

}
