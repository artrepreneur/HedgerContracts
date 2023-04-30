
// SPDX-License-Identifier: MIT
/*
* This is a solidity smart contract for a hedge fund. The contract uses the OpenZeppelin library to import ERC20 and AccessControl contracts, and also interfaces with Chainlink and UniswapV2Router02 for token swaps. The fund manager can add non-pool tokens and their corresponding price feeds to the contract, and users can deposit and withdraw USDT to and from the pool. The contract calculates the net asset value of the pool using Chainlink price feeds and the balances of non-pool tokens, and uses 1inch to swap non-pool tokens to USDT. The fund manager can also swap tokens using UniswapV2Router02. The contract also has role-based access control, with a DEFAULT_ADMIN_ROLE and a FUND_MANAGER_ROLE.
* Note that multichain portfolios are only possible by moving underlying liqduity through a
* stablecoin brigde, that is until teleport has the liquidity it needs.
*/


pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./FundBase.sol";
import "./IOneSplitAudit.sol"; // Make sure to import the IOneSplitAudit interface


contract HedgerDex is FundBase, AccessControl, ERC20("HedgerDex Token", "HDT") {
    bytes32 public constant FUND_MANAGER_ROLE = keccak256("FUND_MANAGER_ROLE");
    uint8 public constant DECIMALS = 18;
    uint256 public lockUpDuration;
    mapping(address => uint256) public balances;
    uint256 public totalBalance;
    uint256 public totalShares;
    mapping(address => uint256) public shareBalances;
    IERC20 public stablecoin;
    //address[] nonPoolTokens;

    event Deposit(address indexed sender, uint256 usdtAmount, uint256 poolTokensMinted, uint256 lockUpPeriodEnd);
    event Withdrawal(address indexed user, uint256 amount, uint256 shareAmount, uint256 fee);
    event TokenSwapped(address indexed token, uint256 fromAmount, address indexed toToken, uint256 toAmount);
    event FundManagerSet(address indexed oldFundManager, address indexed newFundManager);

    uint256 constant ETH_DECIMALS = 18;
    address public fundManagementWallet;
    address constant private ONEINCH_ROUTER = address(0x11111112542D85B3EF69AE05771c2dCCff4fAa26);
    address constant private ONEINCH_EXCHANGE = address(0x11111254369792b2Ca5d084aB5eEA397cA8fa48B);
    AggregatorV3Interface internal priceFeed = AggregatorV3Interface(0x3E7d1eAB13ad0104d2750B8863b489D65364e32D); //USDT
    AggregatorV3Interface internal ethPriceFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); // Ethereum price feed
    address public _stablecoin = address(0x3E7d1eAB13ad0104d2750B8863b489D65364e32D);
    address public _ethToken = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // Ethereum address on Ethereum mainnet
    IOneSplitAudit oneInchRouter = IOneSplitAudit(ONEINCH_ROUTER);

    // Definition for deposits
    mapping(address => uint256) deposits;
    //mapping(address => AggregatorV3Interface) public tokenPriceFeeds;
    mapping(address => uint256) lockUpPeriods;



    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(FUND_MANAGER_ROLE, msg.sender);
        stablecoin = IERC20(_stablecoin);
        
        // Initialize the non-pool tokens and token price feeds
        nonPoolTokens = [_stablecoin, _ethToken]; // Example list of non-pool tokens
        tokenPriceFeeds[_stablecoin] = priceFeed;
        tokenPriceFeeds[_ethToken] = ethPriceFeed;
    }

 


    modifier onlyAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Ownable");
        _;
    }
    
    mapping(address => uint256) public depositedAt; 

    
    function addLiquidity(uint256 _usdtAmount) public {
        require(_usdtAmount > 0, "Amount must be greater than zero");
        uint256 nav = getNav();//getNav();
        uint256 poolTokensToMint = (_usdtAmount * totalShares) / nav;
        uint256 fee = (_usdtAmount * 2) / 100;
        SafeERC20.safeTransferFrom(stablecoin, msg.sender, address(this), _usdtAmount);
        SafeERC20.safeTransfer(stablecoin, fundManagementWallet, fee);
        balances[msg.sender] += (_usdtAmount - fee);
        totalBalance += (_usdtAmount - fee);
        shareBalances[msg.sender] += poolTokensToMint;
        totalShares += poolTokensToMint;
        depositedAt[msg.sender] = block.timestamp;
        uint256 lockUpPeriodEnd = block.timestamp + lockUpDuration;
        lockUpPeriods[msg.sender] = lockUpPeriodEnd;
        emit Deposit(msg.sender, (_usdtAmount - fee), poolTokensToMint, lockUpPeriodEnd);
    }

    function removeLiquidity(uint256 _shareAmount) public {
        require(_shareAmount > 0, "Amount must be greater than zero");
        uint256 assetShareAmount = (_shareAmount * totalBalance) / totalShares;
        for (uint256 i = 0; i < nonPoolTokens.length; i++) {
            address token = nonPoolTokens[i];
            uint256 tokenAmount = (IERC20(token).balanceOf(address(this)) * assetShareAmount) / totalBalance;
            if (tokenAmount > 0) {
                swapTo1inch(token, address(stablecoin), tokenAmount, 0, 0);
            }
        }

        uint256 usdtAmount = (stablecoin.balanceOf(address(this)) * _shareAmount) / totalShares;
        bool canWithdraw = (block.timestamp >= lockUpPeriods[msg.sender]);
        uint256 fee = 0;
        if (!canWithdraw) {
            fee = (usdtAmount * 5) / 100;
        }

        balances[msg.sender] -= (usdtAmount);
        totalBalance -= (usdtAmount);
        uint256 deposit = deposits[msg.sender];
        uint256 shareBalance = shareBalances[msg.sender];
        uint256 initialDeposit = (deposit *  _shareAmount) / shareBalance;
        uint256 profit = usdtAmount - initialDeposit;
        uint256 fee20 = 0;
        fee20 = (profit * 20) / 100;
        fee += fee20;
        shareBalances[msg.sender] -= _shareAmount;
        totalShares -= _shareAmount;
        SafeERC20.safeTransfer(stablecoin, msg.sender, (usdtAmount - fee));
        SafeERC20.safeTransfer(stablecoin, fundManagementWallet, fee);
        emit Withdrawal(msg.sender, (usdtAmount - fee), _shareAmount, fee);
    }

     function swapTo1inch(address _fromToken, address _toToken, uint256 _amountIn, uint256 _amountOutMin, uint256 _maxPriceImpact) internal onlyRole(FUND_MANAGER_ROLE) {
        SafeERC20.safeApprove(IERC20(_fromToken), address(ONEINCH_ROUTER), _amountIn);
        if (!isNonPoolToken(_fromToken)) {
            nonPoolTokens.push(_fromToken);
        }
        require(getExpectedTokenPrice(_fromToken, 1) <= (1 + _maxPriceImpact) * getExpectedTokenPrice(_fromToken,_amountIn), "Price impact too high");
        (uint256 expectedSwap, uint256[] memory distribution) = oneInchRouter.getExpectedReturn(_fromToken, _toToken, _amountIn, 1, 0);
        bytes memory data = abi.encodeWithSignature("swap(address,address,uint256,uint256,uint256,address,address,bytes)", _fromToken, _toToken, _amountIn, _amountOutMin, 0, address(0), expectedSwap, "");
        (bool success, bytes memory result) = ONEINCH_EXCHANGE.call(data);
        require(success, "1inch swap failed");
        uint256 amountOut = abi.decode(result, (uint256));
        require(amountOut >= _amountOutMin, "Slippage too high");
        tokenPriceFeeds[_fromToken] = getTokenPriceFeed(_fromToken);
        emit TokenSwapped(_fromToken, _amountIn, _toToken, amountOut);
    }
    

    function setLockUpDuration(uint256 _duration) public onlyAdmin {
        lockUpDuration = _duration;
    }

}



