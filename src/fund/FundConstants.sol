// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library FundConstants {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant SHARE_SCALE = 1e18;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint256 internal constant ERC7540_REQUEST_ID = 0;
    uint8 internal constant SHARE_DECIMALS = 18;
    uint16 internal constant MAX_BATCH_CONTROLLERS = 64;
    uint16 internal constant MAX_PROCESSING_PAGE = 16;
    bytes32 internal constant INITIAL_POSITIONS_HASH = keccak256("b1nary Fund Positions");
    bytes32 internal constant IDLE_COMPONENT_ID = keccak256("IDLE_ACCOUNTING_ASSET");

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
