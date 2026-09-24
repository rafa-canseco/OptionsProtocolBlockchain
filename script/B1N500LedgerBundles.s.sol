// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PairRoutingSwapRouter} from "../src/routers/PairRoutingSwapRouter.sol";

interface IB1N500Whitelist {
    function whitelistUnderlying(address asset) external;
    function whitelistCollateral(address asset) external;
    function whitelistProduct(address underlying, address strikeAsset, address collateralAsset, bool isPut) external;
}

interface IB1N500SettlerRouter {
    function setSwapRouter(address router) external;
}

/// @notice Deterministic unsigned calldata for the two Ledger-signed B1N-500 activation bundles.
/// @dev This contract has no broadcast path and never handles a private key.
contract B1N500LedgerBundles {
    uint256 public constant CHAIN_ID = 8453;

    address public constant OWNER = 0xC217A5B774cd17388a7C2782f0Cc3F4aaf8a29a7;
    address public constant WHITELIST = 0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A;
    address public constant SETTLER = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;
    address public constant FACADE = 0xFcecd17d0f5e15ed881974a2602c1833C418e28e;

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address public constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    address public constant CBZEC = 0xB2000000000000000000008501b13360000cb2EC;
    address public constant CBHYPE = 0xB200000000000000000000451d033a5000cb479e;
    address public constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;

    address public constant NVDAC_ADAPTER = 0xE2562017C63C5B7EcD6F91F4C1510367bcF6284D;
    address public constant CBHYPE_ADAPTER = 0xc76287aB15C8ced24f4164CF88B4094B6DC1c039;

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
    }

    function bundle1() external pure returns (Transaction[] memory txs) {
        txs = new Transaction[](20);

        txs[0] = _tx(WHITELIST, abi.encodeCall(IB1N500Whitelist.whitelistUnderlying, (NVDAC)));
        txs[1] = _tx(WHITELIST, abi.encodeCall(IB1N500Whitelist.whitelistCollateral, (NVDAC)));
        txs[2] = _tx(WHITELIST, abi.encodeCall(IB1N500Whitelist.whitelistProduct, (NVDAC, USDC, USDC, true)));
        txs[3] = _tx(WHITELIST, abi.encodeCall(IB1N500Whitelist.whitelistProduct, (NVDAC, USDC, NVDAC, false)));
        txs[4] = _tx(WHITELIST, abi.encodeCall(IB1N500Whitelist.whitelistUnderlying, (CBHYPE)));
        txs[5] = _tx(WHITELIST, abi.encodeCall(IB1N500Whitelist.whitelistCollateral, (CBHYPE)));
        txs[6] = _tx(WHITELIST, abi.encodeCall(IB1N500Whitelist.whitelistProduct, (CBHYPE, USDC, USDC, true)));
        txs[7] = _tx(WHITELIST, abi.encodeCall(IB1N500Whitelist.whitelistProduct, (CBHYPE, USDC, CBHYPE, false)));

        txs[8] = _activate(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        txs[9] = _activate(USDC, WETH, PairRoutingSwapRouter.SwapKind.ExactOutput);
        txs[10] = _activate(CBBTC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        txs[11] = _activate(USDC, CBBTC, PairRoutingSwapRouter.SwapKind.ExactOutput);
        txs[12] = _activate(CBZEC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        txs[13] = _activate(USDC, CBZEC, PairRoutingSwapRouter.SwapKind.ExactOutput);
        txs[14] = _activate(VVV, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        txs[15] = _activate(USDC, VVV, PairRoutingSwapRouter.SwapKind.ExactOutput);

        txs[16] = _propose(NVDAC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, NVDAC_ADAPTER);
        txs[17] = _propose(USDC, NVDAC, PairRoutingSwapRouter.SwapKind.ExactOutput, NVDAC_ADAPTER);
        txs[18] = _propose(CBHYPE, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, CBHYPE_ADAPTER);
        txs[19] = _propose(USDC, CBHYPE, PairRoutingSwapRouter.SwapKind.ExactOutput, CBHYPE_ADAPTER);
    }

    function bundle2() external pure returns (Transaction[] memory txs) {
        txs = new Transaction[](5);
        txs[0] = _activate(NVDAC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        txs[1] = _activate(USDC, NVDAC, PairRoutingSwapRouter.SwapKind.ExactOutput);
        txs[2] = _activate(CBHYPE, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        txs[3] = _activate(USDC, CBHYPE, PairRoutingSwapRouter.SwapKind.ExactOutput);
        txs[4] = _tx(SETTLER, abi.encodeCall(IB1N500SettlerRouter.setSwapRouter, (FACADE)));
    }

    function rollback() external pure returns (Transaction memory) {
        return
            _tx(
                SETTLER,
                abi.encodeCall(IB1N500SettlerRouter.setSwapRouter, (0x2626664c2603336E57B271c5C0b26F421741e481))
            );
    }

    function _activate(address tokenIn, address tokenOut, PairRoutingSwapRouter.SwapKind kind)
        private
        pure
        returns (Transaction memory)
    {
        return _tx(FACADE, abi.encodeCall(PairRoutingSwapRouter.activateRoute, (tokenIn, tokenOut, kind)));
    }

    function _propose(address tokenIn, address tokenOut, PairRoutingSwapRouter.SwapKind kind, address adapter)
        private
        pure
        returns (Transaction memory)
    {
        return _tx(FACADE, abi.encodeCall(PairRoutingSwapRouter.proposeRoute, (tokenIn, tokenOut, kind, adapter)));
    }

    function _tx(address to, bytes memory data) private pure returns (Transaction memory) {
        return Transaction({to: to, value: 0, data: data});
    }
}
