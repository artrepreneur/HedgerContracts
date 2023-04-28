// IHedgerDex.sol
pragma solidity ^0.8.0;
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IHedgerDex {
    function shareBalances(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function stablecoin() external view returns (address);
    function swapTo1inch(address fromToken, address toToken, uint256 fromAmount, uint256 minReturn, uint256 maxPriceImpact) external;
    function getTokenPrice(address token) external view returns (uint256);
    function getExpectedTokenPrice(address token, uint256 amount) external view returns (uint256);
    function tokenPriceFeeds(address token) external view returns (address);
    function getTokenPriceFeed(address token) external view returns (AggregatorV3Interface);
    function isNonPoolToken(address token) external view returns (bool);
    function nonPoolTokens(uint256 index) external view returns (address);
    function setTokenPriceFeed(address token, AggregatorV3Interface priceFeed) external;
    function getNonPoolTokenBalances() external view returns (address[] memory, uint256[] memory);
    function addNonPoolToken(address token) external;

}
