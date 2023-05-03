pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./IOneSplitAudit.sol"; // Make sure to import the IOneSplitAudit interface

contract FundBase {
    using SafeERC20 for IERC20;

     // State variables
    address[] public nonPoolTokens;
    mapping(address => AggregatorV3Interface) public tokenPriceFeeds;
    AggregatorV3Interface internal priceFeed = AggregatorV3Interface(0x3E7d1eAB13ad0104d2750B8863b489D65364e32D); //USDT
    AggregatorV3Interface internal ethPriceFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); // Ethereum price feed
    address constant private ONEINCH_ROUTER = address(0x11111112542D85B3EF69AE05771c2dCCff4fAa26);
    address public _ethToken;
    uint8 public constant DECIMALS = 18;
    uint8 public constant ETH_DECIMALS = 18;

    
    // Utility functions
    function getNonPoolTokenBalances() public view returns (address[] memory, uint256[] memory) {
        uint256[] memory NPTbalances = new uint256[](nonPoolTokens.length);

        for (uint256 i = 0; i < nonPoolTokens.length; i++) {
            address token = nonPoolTokens[i];
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            NPTbalances[i] = tokenBalance;
        }

        return (nonPoolTokens, NPTbalances);
    }

    function isNonPoolToken(address _token) public view returns (bool) {
        for (uint256 i = 0; i < nonPoolTokens.length; i++) {
            if (nonPoolTokens[i] == _token) {
                return true;
            }
        }
        return false;
    }

    function getTokenPriceFeed(address _token) internal view returns (AggregatorV3Interface) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(tokenPriceFeeds[_token]);
        require(address(priceFeed) != address(0), "Price feed not found");
        return priceFeed;
    }

    function getNav() public view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        uint256 stablecoinNav = uint256(price) * (10 ** DECIMALS);
        uint256 nonPoolTokenNav = 0;
        for (uint256 i = 0; i < nonPoolTokens.length; i++) {
            address token = nonPoolTokens[i];
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            if (tokenBalance > 0) {
                (, int256 tokenPrice, , , ) = AggregatorV3Interface(tokenPriceFeeds[token]).latestRoundData();
                nonPoolTokenNav += uint256(tokenPrice) * tokenBalance;
            }
        }
        uint256 nav = stablecoinNav + nonPoolTokenNav;
        return nav;
    }

     // Price and expected token price calculation
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

    function _setTokenPriceFeed(address token, AggregatorV3Interface priceFeed) internal {
        tokenPriceFeeds[token] = priceFeed;
    }

    function _addNonPoolToken(address _token) internal {
        require(!isNonPoolToken(_token), "Token is already a non-pool token");
        nonPoolTokens.push(_token);
    }

 
}
