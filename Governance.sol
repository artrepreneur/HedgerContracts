pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./HedgerDex.sol";
import "./IHedgerDex.sol";



contract Governance is AccessControl {
    // Governance variables, structures, and events
    address public fundManagementWallet;
    uint256 public totalShares;
    IHedgerDex public hedgerDex;
    uint256 public constant VOTING_WINDOW = 3 days; // Define the voting window (e.g., 3 days)
    bytes32 public constant FUND_MANAGER_ROLE = keccak256("FUND_MANAGER_ROLE");
    address constant private ONEINCH_ROUTER = address(0x11111112542D85B3EF69AE05771c2dCCff4fAa26);
    address constant private ONEINCH_EXCHANGE = address(0x11111254369792b2Ca5d084aB5eEA397cA8fa48B);
    IOneSplitAudit oneInchRouter = IOneSplitAudit(ONEINCH_ROUTER);
   
    event ProposalCreated(uint256 indexed proposalId, string description, uint256 amount, address targetToken);
    event TokenSwapped(address indexed token, uint256 fromAmount, address indexed toToken, uint256 toAmount);


    constructor(IHedgerDex _hedgerDex) {
        hedgerDex = _hedgerDex;
    }

    // ...
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

    function getShareBalance(address account) public view returns (uint256) {
        return hedgerDex.shareBalances(account);
    }

    function getTotalSupply() public view returns (uint256) {
        return hedgerDex.totalSupply();
    }

    function getStablecoin() public view returns (address) {
        return hedgerDex.stablecoin();
    }

    function swapUsing1inch(address fromToken, address toToken, uint256 fromAmount, uint256 minReturn, uint256 maxPriceImpact) public {
        hedgerDex.swapTo1inch(fromToken, toToken, fromAmount, minReturn, maxPriceImpact);
    }

    function getTokenPrice(address _token) public view returns (uint256) {
        return hedgerDex.getExpectedTokenPrice(_token,1);
    }

    function getExpectedTokenPrice(address _token, uint256 amount) public view returns (uint256) {
        return hedgerDex.getExpectedTokenPrice(_token, amount);
    }
    

    function isNonPoolToken(address _token) public view returns (bool) {

        (address[] memory nonPoolTokens, uint256[] memory NPTbalances) = hedgerDex.getNonPoolTokenBalances();
        for (uint256 i = 0; i < nonPoolTokens.length; i++) {
    
            if (hedgerDex.nonPoolTokens(1) == _token) {
                return true;
            }
        }
        return false;
    }

    function swapTo1inch(address _fromToken, address _toToken, uint256 _amountIn, uint256 _amountOutMin, uint256 _maxPriceImpact) internal onlyRole(FUND_MANAGER_ROLE) {
        SafeERC20.safeApprove(IERC20(_fromToken), address(ONEINCH_ROUTER), _amountIn);

        // Add the new non-pool token to the array if it doesn't exist
        if (!hedgerDex.isNonPoolToken(_fromToken)) {
            // Replace the line causing the error in Governance.sol with this line
            hedgerDex.addNonPoolToken(_fromToken);
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


        address tokenPriceFeedAddress = hedgerDex.tokenPriceFeeds(_fromToken);
        AggregatorV3Interface tokenPriceFeed = AggregatorV3Interface(tokenPriceFeedAddress);
        hedgerDex.setTokenPriceFeed(_fromToken, tokenPriceFeed);



        // Emit an event to notify the contract owner of the output token balance update
        emit TokenSwapped(_fromToken, _amountIn, _toToken, amountOut);
    }

    function createProposal(string memory _description, uint256 _allocationAmount, address _targetToken) public {
        // Make sure the allocation amount is less than or equal to the stablecoin balance
        require(_allocationAmount <= IERC20( getStablecoin()).balanceOf(address(this)), "Insufficient stablecoin balance");

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
        uint256 voterBalance = getShareBalance(msg.sender); //balanceOf(msg.sender); 

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
        uint256 minVotesToPass = (getTotalSupply() * thresholdPercentage) / 100;

        // Make sure the proposal has enough votes in favor
        require(p.forVotes >= minVotesToPass, "Proposal does not meet the minimum threshold");

        // Get the current balance of stablecoin
        uint256 stablecoinBalance = IERC20(getStablecoin()).balanceOf(address(this));

        // Calculate the amount of targetToken to buy
        uint256 targetTokenAmount = (stablecoinBalance * p.allocationAmount) / totalShares;

        // Check current price of stablecoin
        uint256 maxPriceImpact = 2; // You can set your desired maximum price impact here
        require(getTokenPrice(getStablecoin()) <= (1 + maxPriceImpact) * getExpectedTokenPrice(getStablecoin(), stablecoinBalance), "Price impact too high");

        // Swap stablecoin for targetToken using 1inch
        swapTo1inch(getStablecoin(), p.targetToken, stablecoinBalance, targetTokenAmount, maxPriceImpact);

        // Mark the proposal as executed
        p.executed = true;
    }

}


