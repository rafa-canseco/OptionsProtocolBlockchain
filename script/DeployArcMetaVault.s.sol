// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ArcMetaVault} from "../src/vaults/ArcMetaVault.sol";

contract DeployArcMetaVault is Script {
    address public constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    uint64 public constant DEFAULT_EPOCH_DURATION = 1 days;

    ArcMetaVault public vault;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envOr("ARC_OWNER", deployer);
        address operator = vm.envOr("ARC_OPERATOR", deployer);
        address agent = vm.envOr("ARC_AGENT", operator);
        uint64 epochDuration = uint64(vm.envOr("ARC_EPOCH_DURATION", uint256(DEFAULT_EPOCH_DURATION)));

        vm.startBroadcast(deployerKey);
        vault = new ArcMetaVault(ARC_USDC, owner, operator, agent, epochDuration);
        vm.stopBroadcast();

        console.log("DEPLOYED:ArcMetaVault:%s", address(vault));
        console.log("CONFIG:ArcUSDC:%s", ARC_USDC);
        console.log("CONFIG:Owner:%s", owner);
        console.log("CONFIG:Operator:%s", operator);
        console.log("CONFIG:Agent:%s", agent);
        console.log("CONFIG:EpochDuration:%s", epochDuration);
    }
}
