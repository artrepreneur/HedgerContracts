
// SPDX-License-Identifier: MIT
/*
* This is a solidity smart contract for a hedge fund. The contract uses the OpenZeppelin library to import ERC20 and AccessControl contracts, and also interfaces with Chainlink and UniswapV2Router02 for token swaps. The fund manager can add non-pool tokens and their corresponding price feeds to the contract, and users can deposit and withdraw USDT to and from the pool. The contract calculates the net asset value of the pool using Chainlink price feeds and the balances of non-pool tokens, and uses 1inch to swap non-pool tokens to USDT. The fund manager can also swap tokens using UniswapV2Router02. The contract also has role-based access control, with a DEFAULT_ADMIN_ROLE and a FUND_MANAGER_ROLE.
* Note that multichain portfolios are only possible by moving underlying liqduity through a
* stablecoin brigde, that is until teleport has the liquidity it needs.
*/


pragma solidity ^0.8.0;

//import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
//import "@openzeppelin/contracts/utils/math/SafeMath.sol";


interface IOneSplitAudit {
    function getExpectedReturn(
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 parts,
        uint256 flags
    ) external view returns (uint256 returnAmount, uint256[] memory distribution);
}

contract HedgerDexToken is AccessControl, ERC20("HedgerDex Token", "HDT") {
    //using SafeERC20 for IERC20;
    //using SafeMath for uint256;

    bytes32 public constant FUND_MANAGER_ROLE = keccak256("FUND_MANAGER_ROLE");
    uint8 public constant DECIMALS = 18;
    uint256 public constant INITIAL_SHARE_PRICE = 10**DECIMALS;
    uint256 public lockUpDuration;
    mapping(address => uint256) public balances;
    uint256 public totalBalance;
    uint256 public totalShares;
    mapping(address => uint256) public shareBalances;
    IERC20 public stablecoin;
    address[] nonPoolTokens;
    event Deposit(address indexed sender, uint256 usdtAmount, uint256 poolTokensMinted, uint256 lockUpPeriodEnd);
    event Withdrawal(address indexed user, uint256 amount, uint256 shareAmount, uint256 fee);
    event Swap(address indexed user, uint256 amountIn, uint256 amountOut);
    event TokenSwapped(address indexed token, uint256 fromAmount, address indexed toToken, uint256 toAmount);
    event ProposalCreated(uint256 indexed proposalId, string description, uint256 amount, address targetToken);
    event FundManagerSet(address indexed oldFundManager, address indexed newFundManager);
    event AdminGranted(address to);
    event AdminRevoked(address to);
    uint256 constant ETH_DECIMALS = 18;
    address public fundManagementWallet;
    address constant private ONEINCH_ROUTER = address(0x11111112542D85B3EF69AE05771c2dCCff4fAa26);
    address constant private ONEINCH_EXCHANGE = address(0x11111254369792b2Ca5d084aB5eEA397cA8fa48B);
    address constant private UNISWAP_ROUTER = address(0xf164fC0Ec4E93095b804a4795bBe1e041497b92a);
    AggregatorV3Interface internal priceFeed = AggregatorV3Interface(0x3E7d1eAB13ad0104d2750B8863b489D65364e32D); //USDT
    AggregatorV3Interface internal ethPriceFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); // Ethereum price feed
    address public _stablecoin = address(0x3E7d1eAB13ad0104d2750B8863b489D65364e32D);
    address public _ethToken = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // Ethereum address on Ethereum mainnet
    IOneSplitAudit oneInchRouter = IOneSplitAudit(ONEINCH_ROUTER);
    uint256 public constant VOTING_WINDOW = 3 days; // Define the voting window (e.g., 3 days)


    // Definition for deposits
    mapping(address => uint256) deposits;
    mapping(address => AggregatorV3Interface) public tokenPriceFeeds;
    mapping(address => uint256) lockUpPeriods;

    struct Proposal {
        uint256 proposalID;
        string description;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 totalVotes;
        uint256 startTime;
        uint256 endTime;
        uint256 allocationAmount;
        address targetToken;
        bool executed;
        mapping(address => bool) hasVoted;
    }

    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;


    constructor() {//address _stablecoin
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

    function grantAdmin(address to) public onlyAdmin {
        grantRole(DEFAULT_ADMIN_ROLE, to);
        emit AdminGranted(to);
    }

    function revokeAdmin(address to) public onlyAdmin { 
        require(hasRole(DEFAULT_ADMIN_ROLE, to), "Ownable");
        revokeRole(DEFAULT_ADMIN_ROLE, to);
        emit AdminRevoked(to);
    }

    
    function addNonPoolToken(address _token, address _priceFeed) public onlyRole(FUND_MANAGER_ROLE) {
        // Add the token to the nonPoolTokens array if it doesn't already exist
        if (!isNonPoolToken(_token)) {
            nonPoolTokens.push(_token);
        }

        // Update the tokenPriceFeeds mapping
        tokenPriceFeeds[_token] = AggregatorV3Interface(_priceFeed);

    }

    function setLockUpDuration(uint256 _duration) public onlyAdmin {
        lockUpDuration = _duration;
    }

    function isNonPoolToken(address _token) public view returns (bool) {
        for (uint256 i = 0; i < nonPoolTokens.length; i++) {
            if (nonPoolTokens[i] == _token) {
                return true;
            }
        }
        return false;
    }

    function setFundManager(address _newFundManager) public onlyAdmin {
        address oldFundManager = fundManagementWallet;
        require(_newFundManager != address(0), "Invalid address");
        fundManagementWallet = _newFundManager;
        emit FundManagerSet(oldFundManager, _newFundManager);
    }

    mapping(address => uint256) public depositedAt; // Add this mapping to track deposit times

    function addLiquidity(uint256 _usdtAmount) public {
        require(_usdtAmount > 0, "Amount must be greater than zero");

        // Get the current net asset value of the pool from the oracle
        uint256 nav = getNav();

        // Calculate the amount of pool tokens to mint based on the net asset value and the amount of USDT being added
        uint256 poolTokensToMint = (_usdtAmount * totalShares) / nav;

        // Calculate the 2% fee
        uint256 fee = (_usdtAmount * 2) / 100;

        // Transfer USDT from the user to the fund
        SafeERC20.safeTransferFrom(stablecoin, msg.sender, address(this), _usdtAmount);


        // Transfer 2% fee to the fund management wallet
        SafeERC20.safeTransfer(stablecoin, fundManagementWallet, fee);

        // Increase the user's balance and the total pool balance
        balances[msg.sender] += (_usdtAmount - fee);
        totalBalance += (_usdtAmount - fee);

        // Increase the user's share balance and the total share balance
        shareBalances[msg.sender] += poolTokensToMint;
        totalShares += poolTokensToMint;

        // Record the deposit time for the user
        depositedAt[msg.sender] = block.timestamp;

        // Set the lock-up period for the new liquidity
        uint256 lockUpPeriodEnd = block.timestamp + lockUpDuration;
        lockUpPeriods[msg.sender] = lockUpPeriodEnd;

        // Emit an event to indicate the deposit and the amount of pool tokens minted
        emit Deposit(msg.sender, (_usdtAmount - fee), poolTokensToMint, lockUpPeriodEnd);
    }

    function getNav() public view returns (uint256) {
        // Get the latest price from the oracle
        (, int256 price, , , ) = priceFeed.latestRoundData();

        // Convert the price to a uint256 with the appropriate number of decimal places
        uint256 stablecoinNav = uint256(price) * (10 ** DECIMALS);

        // Calculate the total value of non-pool tokens in the contract
        uint256 nonPoolTokenNav = 0;
        for (uint256 i = 0; i < nonPoolTokens.length; i++) {
            address token = nonPoolTokens[i];
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            if (tokenBalance > 0) {
                (, int256 tokenPrice, , , ) = AggregatorV3Interface(tokenPriceFeeds[token]).latestRoundData();
                nonPoolTokenNav += uint256(tokenPrice) * tokenBalance;
            }
        }

        // Add the total value of non-pool tokens to the stablecoin NAV to get the total NAV
        uint256 nav = stablecoinNav + nonPoolTokenNav;

        return nav;
    }


    function removeLiquidity(uint256 _shareAmount) public {
        require(_shareAmount > 0, "Amount must be greater than zero");

        // Get the current net asset value of the pool from the oracle
        //uint256 nav = getNav();

        // Calculate the pro-rata share of each asset in the pool
        uint256 assetShareAmount = (_shareAmount * totalBalance) / totalShares;

        // Swap the pro-rata amount of assets back to USDT using 1inch
        for (uint256 i = 0; i < nonPoolTokens.length; i++) {
            address token = nonPoolTokens[i];
            uint256 tokenAmount = (IERC20(token).balanceOf(address(this)) * assetShareAmount) / totalBalance;
            if (tokenAmount > 0) {
                swapTo1inch(token, address(stablecoin), tokenAmount, 0, 0);
            }
        }

        // Calculate the amount of USDT to return to the user
        uint256 usdtAmount = (stablecoin.balanceOf(address(this)) * _shareAmount) / totalShares;

        // Check if the caller can withdraw without fees
        bool canWithdraw = (block.timestamp >= lockUpPeriods[msg.sender]);
        


        // Apply the 5% fee if the caller is not eligible for fee-less withdrawal
        uint256 fee = 0;
        if (!canWithdraw) {
            fee = (usdtAmount * 5) / 100;
        }

        // Decrease the user's balance and the total pool balance
        balances[msg.sender] -= (usdtAmount);
        totalBalance -= (usdtAmount);


        // Calculate the profit made since liquidity was initially added
        uint256 deposit = deposits[msg.sender];
        uint256 shareBalance = shareBalances[msg.sender];
        uint256 initialDeposit = (deposit *  _shareAmount) / shareBalance;
        uint256 profit = usdtAmount - initialDeposit;

        // Apply the 20% fee to the profit
        uint256 fee20 = 0;
        fee20 = (profit * 20) / 100;
        fee += fee20;

        // Decrease the user's share balance and the total share balance
        shareBalances[msg.sender] -= _shareAmount;
        totalShares -= _shareAmount;

        // Transfer USDT from the fund to the user, subtracting any applicable fee
        // Send the fee to the fund management wallet
        stablecoin.safeTransfer(msg.sender, (usdtAmount - fee));
        stablecoin.safeTransfer(fundManagementWallet, fee);

        // Emit an event to indicate the withdrawal, the amount of pool tokens redeemed, and any applicable fees
        emit Withdrawal(msg.sender, (usdtAmount - fee), _shareAmount, fee);
    }

    /*This function uses the Uniswap router to swap _amountIn of _fromToken for _toToken, and requires that the fund manager has the FUND_MANAGER_ROLE. The _data parameter is not used in this function, but can be included in case the fund manager wants to execute more complex trades.
     * Note that you will need to define UNISWAP_ROUTER as a constant in your contract and import the IUniswapV2Router02 interface from the UniswapV2Router02.sol file in the @uniswap/v2-periphery package. 
     * Additionally, you will need to make sure that the contract has approved the Uniswap router to spend the appropriate amount of _fromToken before calling the swapExactTokensForTokens function.
     * Swaps through a fund manager
    */
    /*function swapToUni(address _fromToken, address _toToken, uint256 _amountIn, uint256 _amountOutMin) public onlyRole(FUND_MANAGER_ROLE) {//, bytes memory _data
        IERC20(_fromToken).safeApprove(address(UNISWAP_ROUTER), _amountIn);
        
        // Prepare the path array for the swap
        address[] memory path = new address[](2);
        path[0] = _fromToken;
        path[1] = _toToken;

        uint[] memory amounts = IUniswapV2Router02(UNISWAP_ROUTER).swapExactTokensForTokens(
            _amountIn,
            _amountOutMin,
            path,
            address(this),
            block.timestamp
        );

        emit TokenSwapped(_fromToken, amounts[0], _toToken, amounts[1]);

        // Add the token to the nonPoolTokens array if it doesn't already exist
        bool tokenExists = false;
        for (uint256 i = 0; i < nonPoolTokens.length; i++) {
            if (nonPoolTokens[i] == _fromToken) {
                tokenExists = true;
                break;
            }
        }
        if (!tokenExists) {
            nonPoolTokens.push(_fromToken);
        }

        // Add the token to the tokenPriceFeeds mapping if it doesn't already exist
        if (address(tokenPriceFeeds[_fromToken]) == address(0)) {
            // Set the price feed for the token
            address tokenPriceFeed = getPriceFeedAddress(_fromToken);// get the address of the price feed for the token
            AggregatorV3Interface agg = AggregatorV3Interface(tokenPriceFeed);
            tokenPriceFeeds[_fromToken] = agg;
            // tokenPriceFeeds[_fromToken] = tokenPriceFeed;


        }
    }*/

    function getPriceFeedAddress(address _token) internal view returns (address) {
        // Get the address of the Chainlink aggregator for the token
        AggregatorV3Interface aggregator = AggregatorV3Interface(tokenPriceFeeds[_token]);
        address priceFeedAddress = address(aggregator);


        return priceFeedAddress;
    }

    function swapTo1inch(address _fromToken, address _toToken, uint256 _amountIn, uint256 _amountOutMin, uint256 _maxPriceImpact) internal onlyRole(FUND_MANAGER_ROLE) {
        IERC20(_fromToken).safeApprove(address(ONEINCH_ROUTER), _amountIn);

        // Add the new non-pool token to the array if it doesn't exist
        if (!isNonPoolToken(_fromToken)) {
            nonPoolTokens.push(_fromToken);
        }
        
        // Check current price of input token
        require(getTokenPrice(_fromToken) <= (1 + _maxPriceImpact) * getExpectedTokenPrice(_fromToken,_amountIn), "Price impact too high");

        // Prepare the 1inch swap parameters
        (uint256 expectedSwap, uint256[] memory distribution) = oneInchRouter.getExpectedReturn(_fromToken, _toToken, _amountIn, 1, 0);
        bytes memory data = abi.encodeWithSignature("swap(address,address,uint256,uint256,uint256,address,address,bytes)", _fromToken, _toToken, _amountIn, _amountOutMin, 0, address(0), expectedSwap, "");

        // Execute the swap on 1inch
        (bool success, bytes memory result) = ONEINCH_EXCHANGE.call(data);
        require(success, "1inch swap failed");
        uint256 amountOut = abi.decode(result, (uint256));
        require(amountOut >= _amountOutMin, "Slippage too high");

        // Update the non-pool token price feed mapping
        tokenPriceFeeds[_fromToken] = getTokenPriceFeed(_fromToken);
        
        // Emit an event to notify the contract owner of the output token balance update
        emit TokenSwapped(_fromToken, _amountIn, _toToken, amountOut);
    }

    function getEthPrice() public view returns (uint256) {
        (,int256 price,,,) = AggregatorV3Interface(ethPriceFeed).latestRoundData();
        return uint256(price) * (10 ** (18 - ETH_DECIMALS));
    }

    function getExpectedTokenPrice(address _token, uint256 _amount) internal view returns (uint256) {
        uint256 decimals = uint256(ERC20(_token).decimals());
        uint256 amountWithDecimals = _amount * 10**decimals;

        (uint256 expectedReturn, ) = IOneSplitAudit(ONEINCH_ROUTER).getExpectedReturn(_token, _ethToken, amountWithDecimals, 1, 0);

        uint256 expectedReturnWithDecimals = expectedReturn / 10**decimals;

        uint256 ethPrice = getEthPrice();

        uint256 tokenPrice = ethPrice * expectedReturnWithDecimals;

        return tokenPrice;
    }

    function swapOnPrice1inch(
        address _fromToken,
        address _toToken,
        uint256 _amountIn,
        uint256 _minAmountOut,
        uint256 _expectedPrice
    ) external {
        require(_expectedPrice > 0, "Invalid expected price");

        // Approve 1inch router to spend tokens
        IERC20(_fromToken).approve(address(oneInchRouter), _amountIn);

        // Call 1inch swap function with limit order
        /*(uint256 returnAmount,) = oneInchRouter.swap(
            _fromToken,
            _toToken,
            _amountIn,
            _minAmountOut,
            address(this),
            _expectedPrice,
            0
        );*/
        (uint256 returnAmount,) = oneInchRouter.getExpectedReturn(_fromToken, _toToken, _amountIn, 1, 0);


        // Ensure that the returned amount is greater than or equal to the minimum amount out
        require(returnAmount >= _minAmountOut, "Slippage limit reached");

        // Transfer swapped tokens to the caller
        IERC20(_toToken).safeTransfer(msg.sender, returnAmount);
    }

    function grantRole(bytes32 role, address account) public onlyRole(DEFAULT_ADMIN_ROLE) override {
        grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public onlyRole(DEFAULT_ADMIN_ROLE) override {
        revokeRole(role, account);
    }

    function getNonPoolTokenBalances() public view returns (address[] memory, uint256[] memory) {
        uint256[] memory NPTbalances = new uint256[](nonPoolTokens.length);

        for (uint256 i = 0; i < nonPoolTokens.length; i++) {
            address token = nonPoolTokens[i];
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            NPTbalances[i] = tokenBalance;
        }

        return (nonPoolTokens, NPTbalances);
    }

    function getTvl() public view returns (uint256) {
        uint256 tvl = 0;

        // Calculate the total value in stablecoins
        uint256 stablecoinBalance = stablecoin.balanceOf(address(this));
        (, int256 stablecoinPrice, , , ) = tokenPriceFeeds[address(stablecoin)].latestRoundData();
        tvl += uint256(stablecoinPrice) * stablecoinBalance;

        // Calculate the total value of non-pool tokens in the contract
        for (uint256 i = 0; i < nonPoolTokens.length; i++) {
            address token = nonPoolTokens[i];
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            if (tokenBalance > 0) {
                (, int256 tokenPrice, , , ) = AggregatorV3Interface(tokenPriceFeeds[token]).latestRoundData();
                uint256 decimals = uint256(ERC20(token).decimals());
                tvl += uint256(tokenPrice) * tokenBalance / (10 ** decimals);
            }
        }

        return tvl;
    }

    function getTokenPrice(address _token) public view returns (uint256) 
    {
        if (_token == address(stablecoin)) {
            // Stablecoin has a fixed price of 1
            return 10**uint256(ERC20(_token).decimals());
        } else {
            // Get the expected return from 1inch for swapping 1 token to _ethToken
            uint256 amountWithDecimals = 10**uint256(ERC20(_token).decimals());
            (uint256 expectedReturn, ) = IOneSplitAudit(ONEINCH_ROUTER).getExpectedReturn(_token, _ethToken, amountWithDecimals, 1, 0);

            // Calculate the token price based on the expected return from 1inch and the current ETH price
            uint256 expectedReturnWithDecimals = expectedReturn / 10**uint256(ERC20(_token).decimals());
            uint256 ethPrice = getEthPrice();
            uint256 tokenPrice = ethPrice * expectedReturnWithDecimals;

            return tokenPrice;
        }
    }


    function getTokenPriceFeed(address _token) internal view returns (AggregatorV3Interface) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(tokenPriceFeeds[_token]);
        require(address(priceFeed) != address(0), "Price feed not found");
        return priceFeed;
    }




    function createProposal(string memory _description, uint256 _allocationAmount, address _targetToken) public {
        // Make sure the allocation amount is less than or equal to the stablecoin balance
        require(_allocationAmount <= IERC20(stablecoin).balanceOf(address(this)), "Insufficient stablecoin balance");

        // Increment the proposal count
        proposalCount++;

        // Create a new proposal
        Proposal storage p = proposals[proposalCount];
        p.proposalID = proposalCount;
        p.description = _description;
        p.allocationAmount = _allocationAmount;
        p.targetToken = _targetToken;
        p.startTime =  block.timestamp;
        p.endTime = block.timestamp + VOTING_WINDOW;
        p.forVotes = 0;
        p.againstVotes = 0;

        // Emit an event
        emit ProposalCreated(proposalCount, _description, _allocationAmount, _targetToken);
    }

    // Modifier to check if the voting window is open for a proposal
    modifier isVotingOpen(uint256 _proposalId) {
        Proposal storage p = proposals[_proposalId];
        require(block.timestamp >= p.startTime, "Voting has not started");
        require(block.timestamp <= p.endTime, "Voting has ended");
        _;
    }


    

    function vote(uint256 _proposalId, bool _support) public {

        // Get the proposal
        Proposal storage p = proposals[_proposalId];

        // Make sure the proposal exists and hasn't already been executed
        require(bytes(p.description).length > 0, "Proposal does not exist");
        require(!p.executed, "Proposal has already been executed");

        // Get voter balance
        uint256 voterBalance = shareBalances[msg.sender]; //balanceOf(msg.sender); 

        // Make sure voter has right to vote on this proposal msg.sender must own at least 1 token
        require(voterBalance > 0, "You do not own any tokens");

        // Make sure the voter hasn't already voted
        require(!p.hasVoted[msg.sender], "Already voted on this proposal");

        // Update the vote count
        if (_support) {
            // vote with your balance
            p.forVotes += voterBalance;
        } else {
            p.againstVotes += voterBalance;
        }
        p.totalVotes += voterBalance;

        p.executed = true;
        
    }

    function executeProposal(uint256 _proposalId) public {
        // Get the proposal
        Proposal storage p = proposals[_proposalId];

        // Make sure the proposal exists and hasn't already been executed
        require(bytes(p.description).length > 0, "Proposal does not exist");
        require(!p.executed, "Proposal has already been executed");

        // Define the threshold percentage
        uint256 thresholdPercentage = 51;

        // Calculate the minimum number of votes needed to pass the proposal
        uint256 minVotesToPass = (totalSupply() * thresholdPercentage) / 100;

        // Make sure the proposal has enough votes in favor
        require(p.forVotes >= minVotesToPass, "Proposal does not meet the minimum threshold");

        // Get the current balance of stablecoin
        uint256 stablecoinBalance = IERC20(stablecoin).balanceOf(address(this));

        // Calculate the amount of targetToken to buy
        uint256 targetTokenAmount = (stablecoinBalance * p.allocationAmount) / totalShares;

        // Check current price of stablecoin
        uint256 maxPriceImpact = 0; // You can set your desired maximum price impact here
        require(getTokenPrice(stablecoin) <= (1 + maxPriceImpact) * getExpectedTokenPrice(stablecoin, stablecoinBalance), "Price impact too high");

        // Swap stablecoin for targetToken using 1inch
        swapTo1inch(stablecoin, p.targetToken, stablecoinBalance, targetTokenAmount, maxPriceImpact);

        // Mark the proposal as executed
        p.executed = true;
    }



   


  

}



