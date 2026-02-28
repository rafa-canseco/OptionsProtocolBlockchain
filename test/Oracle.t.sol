// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/Oracle.sol";
import "../src/core/AddressBook.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockChainlinkFeed {
    int256 public price;

    constructor(int256 _price) {
        price = _price;
    }

    function setPrice(int256 _price) external {
        price = _price;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}

contract OracleTest is Test {
    AddressBook public addressBook;
    Oracle public oracle;
    MockChainlinkFeed public ethFeed;

    address public weth = address(0x1111);
    uint256 public expiry;

    function setUp() public {
        vm.warp(1700000000);

        addressBook = AddressBook(
            address(
                new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this))))
            )
        );

        oracle = Oracle(
            address(
                new ERC1967Proxy(
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), address(this)))
                )
            )
        );

        ethFeed = new MockChainlinkFeed(2087e8); // $2087 in 8 decimals

        oracle.setPriceFeed(weth, address(ethFeed));

        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;
    }

    function test_getLivePrice() public view {
        uint256 price = oracle.getPrice(weth);
        assertEq(price, 2087e8);
    }

    function test_revertNoFeed() public {
        vm.expectRevert(Oracle.FeedNotSet.selector);
        oracle.getPrice(address(0xDEAD));
    }

    function test_setExpiryPrice() public {
        oracle.setExpiryPrice(weth, expiry, 2100e8);

        (uint256 price, bool isSet) = oracle.getExpiryPrice(weth, expiry);
        assertEq(price, 2100e8);
        assertTrue(isSet);
    }

    function test_expiryPriceNotSetByDefault() public view {
        (uint256 price, bool isSet) = oracle.getExpiryPrice(weth, expiry);
        assertEq(price, 0);
        assertFalse(isSet);
    }

    function test_cannotSetExpiryPriceTwice() public {
        oracle.setExpiryPrice(weth, expiry, 2100e8);

        vm.expectRevert(Oracle.PriceAlreadySet.selector);
        oracle.setExpiryPrice(weth, expiry, 2200e8);
    }

    function test_cannotSetZeroPrice() public {
        vm.expectRevert(Oracle.InvalidPrice.selector);
        oracle.setExpiryPrice(weth, expiry, 0);
    }

    function test_onlyOwnerCanSetFeed() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.setPriceFeed(weth, address(ethFeed));
    }

    function test_onlyOwnerCanSetExpiryPrice() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.setExpiryPrice(weth, expiry, 2100e8);
    }

    function test_differentExpiriesDifferentPrices() public {
        oracle.setExpiryPrice(weth, expiry, 2100e8);
        oracle.setExpiryPrice(weth, expiry + 7 days, 2200e8);

        (uint256 price1,) = oracle.getExpiryPrice(weth, expiry);
        (uint256 price2,) = oracle.getExpiryPrice(weth, expiry + 7 days);

        assertEq(price1, 2100e8);
        assertEq(price2, 2200e8);
    }
}
