// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library FundConstants {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant ERC7540_REQUEST_ID = 0;

    bytes4 internal constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 internal constant ERC7540_OPERATOR_INTERFACE_ID = 0xe3bc4e65;
    bytes4 internal constant ERC7540_REDEEM_INTERFACE_ID = 0x620ee8e4;
    bytes4 internal constant ERC7575_VAULT_INTERFACE_ID = 0x2f0a18c5;

    uint64 internal constant UPGRADER_ROLE = 1;
    uint64 internal constant ACCOUNTING_ROLE = 2;
    uint64 internal constant ALLOCATOR_ROLE = 3;
    uint64 internal constant PROCESSOR_ROLE = 4;
    uint64 internal constant CURATOR_ROLE = 5;
    uint64 internal constant GUARDIAN_ROLE = 6;
    uint64 internal constant REPORTER_ROLE = 7;

    uint32 internal constant CORE_UPGRADE_DELAY = 72 hours;
    uint32 internal constant ADAPTER_UPGRADE_DELAY = 48 hours;
    uint32 internal constant CURATOR_DELAY = 24 hours;
}
