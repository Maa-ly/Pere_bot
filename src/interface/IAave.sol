// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

interface IAavePool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;

    function getReserveNormalizedIncome(address asset) external view returns (uint256);
    function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);

    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
    function FLASHLOAN_PREMIUM_TO_PROTOCOL() external view returns (uint128);
}

interface IAaveFlashLoanSimpleReceiver {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);
}
