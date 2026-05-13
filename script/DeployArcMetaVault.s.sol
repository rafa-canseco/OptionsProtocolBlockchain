// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ArcMetaVault} from "../src/vaults/ArcMetaVault.sol";

/**
 * @title DeployArcMetaVault
 * @notice Deploys the Arc MetaVault implementation behind an ERC1967 UUPS proxy.
 *
 * Required env:
 * - PRIVATE_KEY
 * - ARC_USDC
 *
 * Optional env:
 * - ARC_OWNER (defaults to deployer)
 * - ARC_OPERATOR (defaults to deployer)
 * - ARC_AGENT (defaults to deployer)
 * - ARC_EPOCH_DURATION (defaults to 1 days)
 */
contract DeployArcMetaVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address usdc = vm.envAddress("ARC_USDC");
        address owner = _envAddressOr("ARC_OWNER", deployer);
        address operator = _envAddressOr("ARC_OPERATOR", deployer);
        address agent = _envAddressOr("ARC_AGENT", deployer);
        uint256 epochDurationValue = _envUintOr("ARC_EPOCH_DURATION", 1 days);
        require(epochDurationValue <= type(uint64).max, "epoch duration too large");
        uint64 epochDuration = uint64(epochDurationValue);

        vm.startBroadcast(deployerKey);

        ArcMetaVault implementation = new ArcMetaVault();
        ArcMetaVault proxy = ArcMetaVault(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(ArcMetaVault.initialize, (usdc, owner, operator, agent, epochDuration))
                )
            )
        );

        vm.stopBroadcast();

        console.log("DEPLOYED:ArcMetaVaultImplementation:%s", address(implementation));
        console.log("DEPLOYED:ArcMetaVault:%s", address(proxy));
        console.log("CONFIG:USDC:%s", usdc);
        console.log("CONFIG:Owner:%s", owner);
        console.log("CONFIG:Operator:%s", operator);
        console.log("CONFIG:Agent:%s", agent);
        console.log("CONFIG:EpochDuration:%s", epochDuration);
    }

    function _envAddressOr(string memory key, address fallbackValue) internal view returns (address value) {
        try vm.envAddress(key) returns (address envValue) {
            value = envValue;
        } catch {
            value = fallbackValue;
        }
    }

    function _envUintOr(string memory key, uint256 fallbackValue) internal view returns (uint256 value) {
        try vm.envUint(key) returns (uint256 envValue) {
            value = envValue;
        } catch {
            value = fallbackValue;
        }
    }
}
