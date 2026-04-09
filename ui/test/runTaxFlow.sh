#!/usr/bin/env bash
# One-shot end-to-end tax + staking activity against live PulseChain.
# Stakes from dev + alt wallets, runs a buy/sell through PulseX to fire
# all 5 taxes, then triggers the vault's PLS→pHEX conversion + drip.
#
# Usage (from repo root):
#   bash ui/test/runTaxFlow.sh
#
# Reads pk_618_sai (dev) and pk (alt) from .env. Never prints key material.

set -euo pipefail

RPC=${RPC:-https://rpc.pulsechain.com}
TOKEN=0x1745A8154C134840e4D4F6A84dD109902d52A33b
VAULT=0x57124b4E6b44401D96D3b39b094923c5832dC769
DAO=0xE27E3963cDF3B881a467f259318ca793076B42A1
ROUTER=0x165C3410fC91EF562C50559f7d2289fEbed552d9
WPLS=0xA1077a294dDE1B09bB078844df40758a5D0f9a27
PHEX=0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39
ZKP=0x90F055196778e541018482213Ca50648cEA1a050
DEAD=0x000000000000000000000000000000000000dEaD

norm_key() {
  local k="$1"
  case "$k" in 0x*) printf '%s' "$k";; *) printf '0x%s' "$k";; esac
}

KD=$(norm_key "$(grep '^pk_618_sai=' .env | cut -d= -f2- | tr -d '"' | tr -d "'")")
KA=$(norm_key "$(grep '^pk=' .env | cut -d= -f2- | tr -d '"' | tr -d "'")")

DEV=$(cast wallet address --private-key "$KD")
ALT=$(cast wallet address --private-key "$KA")

echo "dev: $DEV"
echo "alt: $ALT"

send_dev() {
  local out; out=$(cast send --rpc-url "$RPC" --private-key "$KD" "$@" 2>&1) || { echo "[dev SEND FAILED]"; echo "$out" | tail -20; return 1; }
  echo "$out" | grep -E '^(transactionHash|status)'
}
send_alt() {
  local out; out=$(cast send --rpc-url "$RPC" --private-key "$KA" "$@" 2>&1) || { echo "[alt SEND FAILED]"; echo "$out" | tail -20; return 1; }
  echo "$out" | grep -E '^(transactionHash|status)'
}

bal()    { cast call --rpc-url "$RPC" "$1" 'balanceOf(address)(uint256)' "$2"; }
totsup() { cast call --rpc-url "$RPC" "$1" 'totalSupply()(uint256)'; }
vview()  { cast call --rpc-url "$RPC" "$VAULT" "$1"; }

DL=$(( $(date +%s) + 1200 ))
MAX=0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

snap() {
  echo ""
  echo "── $1 ──"
  echo "totalStaked : $(cast call --rpc-url "$RPC" "$VAULT" 'totalStaked()(uint256)')"
  echo "rewardRate  : $(cast call --rpc-url "$RPC" "$VAULT" 'rewardRate()(uint256)')"
  echo "periodFinish: $(cast call --rpc-url "$RPC" "$VAULT" 'periodFinish()(uint256)')"
  echo "vault PLS   : $(cast balance --rpc-url "$RPC" $VAULT)"
  echo "vault pHEX  : $(bal $PHEX $VAULT)"
  echo "DAO WPLS    : $(bal $WPLS $DAO)"
  echo "ZKP @ dead  : $(bal $ZKP $DEAD)"
  echo "TSTT supply : $(totsup $TOKEN)"
}

snap "BEFORE"

echo ""
echo "=== 1. dev approves vault ==="
send_dev "$TOKEN" 'approve(address,uint256)' "$VAULT" "$MAX"

echo ""
echo "=== 2. dev stakes 10M TSTT ==="
send_dev "$VAULT" 'stake(uint256)' 10000000000000000000000000

echo ""
echo "=== 3. dev -> alt 20M TSTT (tax-exempt as creator) ==="
send_dev "$TOKEN" 'transfer(address,uint256)' "$ALT" 20000000000000000000000000

echo ""
echo "=== 4. alt approves vault ==="
send_alt "$TOKEN" 'approve(address,uint256)' "$VAULT" "$MAX"

echo ""
echo "=== 5. alt stakes 10M TSTT ==="
send_alt "$VAULT" 'stake(uint256)' 10000000000000000000000000

echo ""
echo "=== 6. alt approves router ==="
send_alt "$TOKEN" 'approve(address,uint256)' "$ROUTER" "$MAX"

echo ""
echo "=== 7. alt BUY: 100 PLS -> TSTT via PulseX ==="
send_alt "$ROUTER" \
  'swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[],address,uint256)' \
  0 "[$WPLS,$TOKEN]" "$ALT" "$DL" \
  --value 100000000000000000000

echo ""
echo "=== 8. alt SELL: 2M TSTT -> PLS via PulseX ==="
send_alt "$ROUTER" \
  'swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)' \
  2000000000000000000000000 0 "[$TOKEN,$WPLS]" "$ALT" "$DL"

echo ""
echo "=== 9. dev calls vault.getReward() — normal user action; autoProcess"
echo "       modifier swaps accumulated PLS -> pHEX + starts 7d drip ==="
send_dev "$VAULT" 'getReward()'

snap "AFTER"

echo ""
echo "=== Summary ==="
DEV_STAKED=$(cast call --rpc-url "$RPC" "$VAULT" 'stakedBalance(address)(uint256)' "$DEV")
ALT_STAKED=$(cast call --rpc-url "$RPC" "$VAULT" 'stakedBalance(address)(uint256)' "$ALT")
DEV_EARNED=$(cast call --rpc-url "$RPC" "$VAULT" 'earned(address)(uint256)' "$DEV")
ALT_EARNED=$(cast call --rpc-url "$RPC" "$VAULT" 'earned(address)(uint256)' "$ALT")
echo "dev staked : $DEV_STAKED"
echo "alt staked : $ALT_STAKED"
echo "dev earned : $DEV_EARNED (pHEX, 8d)"
echo "alt earned : $ALT_EARNED (pHEX, 8d)"
