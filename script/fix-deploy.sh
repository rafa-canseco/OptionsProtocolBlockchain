#!/usr/bin/env bash
set -o pipefail

# Parse .env (fish format)
while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    if [[ "$line" =~ ^set\ -x\ ([A-Z_]+)\ (.+)$ ]]; then
        export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    fi
done < "$(cd "$(dirname "$0")/.." && pwd)/.env"

PK="$PRIVATE_KEY"
RPC="$BASE_SEPOLIA_RPC_URL"
DEPLOYER="0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382"

# Existing contracts (second set, confirmed on-chain)
ADDRESSBOOK="0x2530248C7F5fD76edCA8706225747cD914bD5Bc7"
CONTROLLER="0x54Dd9eBF1eC5D1a9DFd66bF84e23bA7b097C4cfe"
MARGINPOOL="0xDBF9BD7b51287DF4C04375e6299F4A1713FD2155"
FACTORY="0x235B51B00Ea8C989D10537CBd4A27E315d4aA0F2"
ORACLE="0xA4d4D2ac1b14E1031F8ae16553Df95C20C9cAfe0"
WHITELIST="0x510A4CC3d9BFf05d6BcBc05c26cBcE8Ab6ee7d20"
SETTLER="0x409f4C0c8b91FeaE64F54617481668e9d8cFb658"
PRICESHEET="0xE26ECA2365E0eb56099ef04984B22c1049434C43"

deploy() {
    local label="$1" contract="$2"; shift 2
    echo "  $label..."
    forge create --rpc-url "$RPC" --private-key "$PK" --broadcast "$contract" "$@" 2>&1 | tee /tmp/fc.txt || true
    ADDR=$(grep "Deployed to:" /tmp/fc.txt | awk '{print $3}')
    if [ -z "$ADDR" ]; then echo "  FAILED: $label"; exit 1; fi
    echo "  OK: $ADDR"
}

send() {
    local label="$1" to="$2" sig="$3"; shift 3
    echo "  $label..."
    cast send --private-key "$PK" --rpc-url "$RPC" "$to" "$sig" "$@" > /dev/null 2>&1 || echo "    WARN: $label may have failed"
}

echo "=== Fix Deploy: 5 mocks + reconfig ==="
echo "Nonce: $(cast nonce $DEPLOYER --rpc-url "$RPC")"
echo ""

# 1. Deploy missing mocks (LETH already deployed)
echo "[1/3] Deploying mocks..."
LETH="0x931927a1B911D72862518e0Ea3815D335df87919"
echo "  LETH: $LETH (already deployed)"
LUSD="0xDa97d8aec7aAD92F9Cba114Abd97a259FdCBC0e3"
echo "  LUSD: $LUSD (already deployed)"
deploy "Feed" "src/mocks/MockChainlinkFeed.sol:MockChainlinkFeed" --constructor-args 250000000000
FEED="$ADDR"
deploy "Aave" "src/mocks/MockAavePool.sol:MockAavePool"
AAVE="$ADDR"
deploy "Router" "src/mocks/MockSwapRouter.sol:MockSwapRouter" --constructor-args "$FEED" "$LETH" "$LUSD"
ROUTER="$ADDR"

# 2. Reconfigure with new mock addresses
echo ""
echo "[2/3] Configuring..."
send "whitelistUnderlying(LETH)" "$WHITELIST" "whitelistUnderlying(address)" "$LETH"
send "whitelistCollateral(LUSD)" "$WHITELIST" "whitelistCollateral(address)" "$LUSD"
send "whitelistCollateral(LETH)" "$WHITELIST" "whitelistCollateral(address)" "$LETH"
send "whitelistProduct(PUT)"     "$WHITELIST" "whitelistProduct(address,address,address,bool)" "$LETH" "$LUSD" "$LUSD" true
send "whitelistProduct(CALL)"    "$WHITELIST" "whitelistProduct(address,address,address,bool)" "$LETH" "$LUSD" "$LETH" false
send "setPriceFeed"              "$ORACLE"    "setPriceFeed(address,address)" "$LETH" "$FEED"
send "setAavePool"               "$SETTLER"   "setAavePool(address)" "$AAVE"
send "setSwapRouter"             "$SETTLER"   "setSwapRouter(address)" "$ROUTER"
send "mint LUSD"                 "$LUSD"      "mint(address,uint256)" "$DEPLOYER" 1000000000000
send "mint LETH"                 "$LETH"      "mint(address,uint256)" "$DEPLOYER" 1000000000000000000000

# 3. Print all addresses
echo ""
echo "[3/3] Done!"
echo ""
echo "DEPLOYED:LETH:$LETH"
echo "DEPLOYED:LUSD:$LUSD"
echo "DEPLOYED:MockChainlinkFeed:$FEED"
echo "DEPLOYED:MockAavePool:$AAVE"
echo "DEPLOYED:MockSwapRouter:$ROUTER"
echo "DEPLOYED:AddressBook:$ADDRESSBOOK"
echo "DEPLOYED:Controller:$CONTROLLER"
echo "DEPLOYED:MarginPool:$MARGINPOOL"
echo "DEPLOYED:OTokenFactory:$FACTORY"
echo "DEPLOYED:Oracle:$ORACLE"
echo "DEPLOYED:Whitelist:$WHITELIST"
echo "DEPLOYED:BatchSettler:$SETTLER"
echo "DEPLOYED:PriceSheet:$PRICESHEET"
echo ""
echo "Nonce: $(cast nonce $DEPLOYER --rpc-url "$RPC")"
