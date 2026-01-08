// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IStork} from "@storknetwork/stork-evm-sdk/IStork.sol";

contract StorkOracle {
    IStork public stork;

    error InvalidAddress();
}
