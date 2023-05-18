//import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IOneSplitAudit {
    function getExpectedReturn(
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 parts,
        uint256 flags
    ) external view returns (uint256 returnAmount, uint256[] memory distribution);
}

