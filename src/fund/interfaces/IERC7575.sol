// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IERC7575 is IERC4626 {
    function share() external view returns (address shareTokenAddress);
}
