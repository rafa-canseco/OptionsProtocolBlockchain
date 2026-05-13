// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BaseVaultAdapter} from "../src/adapters/BaseVaultAdapter.sol";

contract DeployBaseVaultAdapter is Script {
    function run() external returns (BaseVaultAdapter adapter, address implementation) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address addressBook = vm.envAddress("BASE_ADDRESS_BOOK");
        address batchSettler = vm.envAddress("BASE_BATCH_SETTLER");
        address usdc = vm.envAddress("BASE_USDC");
        address owner = vm.envOr("BASE_ADAPTER_OWNER", deployer);
        address operator = vm.envOr("BASE_ADAPTER_OPERATOR", deployer);
        address agent = vm.envOr("BASE_ADAPTER_AGENT", deployer);

        vm.startBroadcast(deployerKey);

        BaseVaultAdapter adapterImpl = new BaseVaultAdapter();
        bytes memory initData =
            abi.encodeCall(BaseVaultAdapter.initialize, (addressBook, batchSettler, usdc, owner, operator, agent));
        ERC1967Proxy proxy = new ERC1967Proxy(address(adapterImpl), initData);

        vm.stopBroadcast();

        adapter = BaseVaultAdapter(address(proxy));
        implementation = address(adapterImpl);

        console.log("DEPLOYED:BaseVaultAdapterImplementation:%s", implementation);
        console.log("DEPLOYED:BaseVaultAdapter:%s", address(adapter));
        console.log("CONFIG:AddressBook:%s", addressBook);
        console.log("CONFIG:BatchSettler:%s", batchSettler);
        console.log("CONFIG:USDC:%s", usdc);
        console.log("CONFIG:Owner:%s", owner);
        console.log("CONFIG:Operator:%s", operator);
        console.log("CONFIG:Agent:%s", agent);
    }
}
