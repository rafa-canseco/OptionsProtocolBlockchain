// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/MarginPool.sol";
import "../src/core/AddressBook.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MarginPoolTest is Test {
    AddressBook public addressBook;
    MarginPool public pool;
    MockERC20 public usdc;

    address public controller = address(0xC0DE);
    address public user = address(0xBEEF);

    function setUp() public {
        addressBook = AddressBook(
            address(
                new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this))))
            )
        );
        addressBook.setController(controller);

        pool = MarginPool(
            address(
                new ERC1967Proxy(
                    address(new MarginPool()), abi.encodeCall(MarginPool.initialize, (address(addressBook)))
                )
            )
        );

        usdc = new MockERC20("USDC", "USDC");

        // Give user some USDC and approve pool
        usdc.mint(user, 10_000e6);
        vm.prank(user);
        usdc.approve(address(pool), type(uint256).max);
    }

    function test_controllerCanTransferToPool() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        assertEq(usdc.balanceOf(address(pool)), 1000e6);
        assertEq(usdc.balanceOf(user), 9000e6);
    }

    function test_controllerCanTransferToUser() public {
        // First deposit
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        // Then withdraw
        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 500e6);

        assertEq(usdc.balanceOf(address(pool)), 500e6);
        assertEq(usdc.balanceOf(user), 9500e6);
    }

    function test_nonControllerCannotTransferToPool() public {
        vm.prank(user);
        vm.expectRevert(MarginPool.OnlyController.selector);
        pool.transferToPool(address(usdc), user, 1000e6);
    }

    function test_nonControllerCannotTransferToUser() public {
        vm.prank(user);
        vm.expectRevert(MarginPool.OnlyController.selector);
        pool.transferToUser(address(usdc), user, 1000e6);
    }

    function test_getStoredBalance() public {
        assertEq(pool.getStoredBalance(address(usdc)), 0);

        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        assertEq(pool.getStoredBalance(address(usdc)), 1000e6);
    }
}
