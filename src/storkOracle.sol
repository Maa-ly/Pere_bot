// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@storknetwork/stork-evm-sdk/IStork.sol";
import "@storknetwork/stork-evm-sdk/StorkStructs.sol";

contract StorkOracle {
    address public stork;

    error InvalidAddress();
}
