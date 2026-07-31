// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Controller} from "../../src/core/Controller.sol";
import {OTokenFactory} from "../../src/core/OTokenFactory.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {B1N394Base} from "./B1N394Base.sol";

/// @notice Rotates the V1 core operator surfaces consumed by Base Sepolia staging.
contract RotateB1N394CoreOperators is B1N394Base {
    address private constant RETIRING_SIGNER = 0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382;
    address private constant CONTROLLER = 0xD52EFbBaA1b02BA65A7f0A1604A5dFb4C4dB1572;
    address private constant OTOKEN_FACTORY = 0x193ED89eB64d0179b4dB08E87E541b7b3c30002A;
    address private constant ORACLE = 0xF95CC4aED4a0bD68e0F1BE7c779BC281189F8187;

    function run() external {
        _requireBaseSepolia();
        address governance = vm.envAddress("B1N394_NEW_GOVERNANCE");
        address operator = vm.envAddress("B1N394_NEW_OPERATOR");
        require(
            governance != address(0) && operator != address(0) && governance != operator, "B1N394: operator identities"
        );
        require(OTokenFactory(OTOKEN_FACTORY).operator() == RETIRING_SIGNER, "B1N394: factory operator");
        require(Oracle(ORACLE).operator() == RETIRING_SIGNER, "B1N394: oracle operator");
        require(BatchSettler(BATCH_SETTLER).operator() == RETIRING_SIGNER, "B1N394: settler operator");
        require(Controller(CONTROLLER).partialPauser() == RETIRING_SIGNER, "B1N394: partial pauser");

        vm.startBroadcast(governance);
        OTokenFactory(OTOKEN_FACTORY).setOperator(operator);
        Oracle(ORACLE).setOperator(operator);
        BatchSettler(BATCH_SETTLER).setOperator(operator);
        Controller(CONTROLLER).setPartialPauser(operator);
        vm.stopBroadcast();

        require(OTokenFactory(OTOKEN_FACTORY).operator() == operator, "B1N394: new factory operator");
        require(Oracle(ORACLE).operator() == operator, "B1N394: new oracle operator");
        require(BatchSettler(BATCH_SETTLER).operator() == operator, "B1N394: new settler operator");
        require(Controller(CONTROLLER).partialPauser() == operator, "B1N394: new partial pauser");
    }
}
