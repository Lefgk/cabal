#!/usr/bin/env bash
# Resume the tax flow from step 3. Dev already staked 10M via the prior run.
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

norm_key() { case "$1" in 0x*) printf '%s' "$1";; *) printf '0x%s' "$1";; esac; }
KD=$(norm_key "$(grep '^pk_618_sai=' .env | cut -d= -f2- | tr -d '"' | tr -d "'")")
KA=$(norm_key "$(grep '^pk=' .env | cut -d= -f2- | tr -d '"' | tr -d "'")")
DEV=$(cast wallet address --private-key "$KD")
ALT=$(cast wallet address --private-key "$KA")

echo "dev: $DEV"
echo "alt: $ALT"

cast_send_with_retry() {
  local KEY="$1"; shift
  local ADDR="$1"; shift
  local n1 n2 out rc
  n1=$(cast nonce --rpc-url "$RPC" "$ADDR")
  out=$(cast send --rpc-url "$RPC" --private-key "$KEY" --timeout 180 "$@" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    sleep 5
    n2=$(cast nonce --rpc-url "$RPC" "$ADDR")
    if [ "$n2" -gt "$n1" ]; then
      echo "[warn] cast errored but nonce advanced ($n1 -> $n2); assuming mined"
      return 0
    fi
    echo "[SEND FAILED for $ADDR]"; echo "$out" | tail -15; return 1
  fi
  echo "$out" | grep -E '^(transactionHash|status)'
}
send_dev() { cast_send_with_retry "$KD" "$DEV" "$@"; }
send_alt() { cast_send_with_retry "$KA" "$ALT" "$@"; }

bal() { cast call --rpc-url "$RPC" "$1" 'balanceOf(address)(uint256)' "$2"; }

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
  echo "TSTT supply : $(cast call --rpc-url "$RPC" "$TOKEN" 'totalSupply()(uint256)')"
  echo "dev staked  : $(cast call --rpc-url "$RPC" "$VAULT" 'stakedBalance(address)(uint256)' $DEV)"
  echo "alt staked  : $(cast call --rpc-url "$RPC" "$VAULT" 'stakedBalance(address)(uint256)' $ALT)"
  echo "alt TSTT    : $(bal $TOKEN $ALT)"
}

DL=$(( $(date +%s) + 3600 ))

snap "BEFORE (resume)"

# Ensure alt has 20M TSTT to work with. If alt already has >=12M, skip xfer.
ALT_CUR=$(bal $TOKEN $ALT)
ALT_DEC=$(cast --to-dec $ALT_CUR 2>/dev/null || echo "$ALT_CUR")
# Need at least 12M (1.2e25). Hex of 12M*1e18 = 0x9ed194db19b238c0000
NEED=$(cast --to-wei 12000000 ether)
if [ "$(cast --to-dec $ALT_CUR 2>/dev/null || echo 0)" -lt "$NEED" ] 2>/dev/null; then
  echo ""
  echo "=== 3. dev -> alt 20M TSTT ==="
  send_dev "$TOKEN" 'transfer(address,uint256)' "$ALT" 20000000000000000000000000
fi

echo ""
echo "=== 4. alt approves vault (idempotent) ==="
send_alt "$TOKEN" 'approve(address,uint256)' "$VAULT" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

echo ""
echo "=== 5. alt stakes 10M TSTT ==="
send_alt "$VAULT" 'stake(uint256)' 10000000000000000000000000

echo ""
echo "=== 6. alt approves router (idempotent) ==="
send_alt "$TOKEN" 'approve(address,uint256)' "$ROUTER" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

echo ""
echo "=== 7. alt BUY: 100 PLS -> TSTT via PulseX ==="
send_alt "$ROUTER" \
  'swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[],address,uint256)' \
  0 "[$WPLS,$TOKEN]" "$ALT" "$DL" \
  --value 100000000000000000000

echo ""
echo "=== 8. alt SELL: 1M TSTT -> PLS via PulseX ==="
send_alt "$ROUTER" \
  'swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)' \
  1000000000000000000000000 0 "[$TOKEN,$WPLS]" "$ALT" "$DL"

echo ""
echo "=== 9. dev calls vault.getReward() (autoProcess swaps PLS->pHEX) ==="
send_dev "$VAULT" 'getReward()'

snap "AFTER"
