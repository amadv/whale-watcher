#!/bin/bash
# =============================================================
# whale_watch.sh — BTC / ETH / SOL whale monitor
# Free APIs only. No paid keys required except ETHERSCAN_KEY
# (free signup at etherscan.io/apis)
#
# SETUP:
#   export ETHERSCAN_KEY=your_free_key_here
#   chmod +x whale_watch.sh
#   ./whale_watch.sh
#
# WHAT IT DOES:
#   Polls BTC via mempool.space (no key needed)
#   Polls ETH via Etherscan free tier (free key)
#   Polls SOL via public Solana RPC (no key needed)
#   Fetches USD prices from CoinGecko (no key needed)
#   Emits structured events to stdout for Claude to monitor
# =============================================================

WHALES_FILE="$(dirname "$0")/whales.json"
SEEN_FILE="/tmp/whale_watch_seen.txt"
POLL_INTERVAL=60  # seconds between full poll cycles
touch "$SEEN_FILE"

# ── colours ──────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log() { echo -e "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }
err() { log "${RED}[ERROR]${RESET} $*" >&2; }

# ── price cache ───────────────────────────────────────────────
BTC_PRICE=0; ETH_PRICE=0; SOL_PRICE=0
PRICE_FETCH_AT=0

fetch_prices() {
  local now; now=$(date +%s)
  # refresh every 5 minutes
  if (( now - PRICE_FETCH_AT < 300 )); then return; fi
  local resp
  resp=$(curl -sf --max-time 10 \
    "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum,solana&vs_currencies=usd" 2>/dev/null)
  if [[ -n "$resp" ]]; then
    BTC_PRICE=$(echo "$resp" | jq -r '.bitcoin.usd // 0')
    ETH_PRICE=$(echo "$resp" | jq -r '.ethereum.usd // 0')
    SOL_PRICE=$(echo "$resp" | jq -r '.solana.usd // 0')
    PRICE_FETCH_AT=$now
    log "${CYAN}[PRICES]${RESET} BTC=\$${BTC_PRICE}  ETH=\$${ETH_PRICE}  SOL=\$${SOL_PRICE}"
  fi
}

usd_value() {
  local chain=$1 amount=$2
  case $chain in
    BTC) echo "$(echo "scale=0; $amount * $BTC_PRICE / 100000000" | bc 2>/dev/null || echo 0)" ;;
    ETH) echo "$(echo "scale=0; $amount * $ETH_PRICE / 1000000000000000000" | bc 2>/dev/null || echo 0)" ;;
    SOL) echo "$(echo "scale=0; $amount * $SOL_PRICE / 1000000000" | bc 2>/dev/null || echo 0)" ;;
  esac
}

severity() {
  local usd=$1
  local alert;   alert=$(jq -r '.thresholds.alert_usd'         "$WHALES_FILE")
  local high;    high=$(jq -r  '.thresholds.high_priority_usd' "$WHALES_FILE")
  local crit;    crit=$(jq -r  '.thresholds.critical_usd'      "$WHALES_FILE")
  if   (( usd >= crit  )); then echo "CRITICAL"
  elif (( usd >= high  )); then echo "HIGH"
  elif (( usd >= alert )); then echo "ALERT"
  else echo "LOW"
  fi
}

emit() {
  # $1=chain $2=label $3=tier $4=txid $5=usd $6=direction $7=address $8=extra
  local chain=$1 label=$2 tier=$3 txid=$4 usd=$5 dir=$6 addr=$7 extra=${8:-}
  local sev; sev=$(severity "$usd")
  local colour="$GREEN"
  [[ "$sev" == "HIGH"     ]] && colour="$YELLOW"
  [[ "$sev" == "CRITICAL" ]] && colour="$RED$BOLD"

  # dedup — skip if we've seen this txid before
  if grep -qF "$txid" "$SEEN_FILE" 2>/dev/null; then return; fi
  echo "$txid" >> "$SEEN_FILE"

  log "${colour}[$sev]${RESET} ${BOLD}${chain}${RESET} | ${label} (${tier}) | \$$(printf '%\047d' "$usd") | ${dir} | tx: ${txid:0:20}… ${extra}"
}

# ── BTC via mempool.space ─────────────────────────────────────
watch_btc() {
  local addrs; addrs=$(jq -r '.btc[] | "\(.address)|\(.label)|\(.tier)"' "$WHALES_FILE")
  while IFS='|' read -r addr label tier; do
    local resp
    resp=$(curl -sf --max-time 15 "https://mempool.space/api/address/${addr}/txs" 2>/dev/null)
    [[ -z "$resp" ]] && continue

    # look at latest 3 txs
    local count; count=$(echo "$resp" | jq 'length')
    local limit=$(( count < 3 ? count : 3 ))

    for i in $(seq 0 $(( limit - 1 ))); do
      local txid; txid=$(echo "$resp" | jq -r ".[$i].txid")
      local confirmed; confirmed=$(echo "$resp" | jq -r ".[$i].status.confirmed")

      # sum vout value to this address
      local recv; recv=$(echo "$resp" | jq -r \
        ".[$i].vout[] | select(.scriptpubkey_address==\"$addr\") | .value" 2>/dev/null | \
        awk '{s+=$1} END{print int(s)}')
      recv=${recv:-0}

      # sum vin value from this address (spent)
      local sent; sent=$(echo "$resp" | jq -r \
        ".[$i].vin[] | select(.prevout.scriptpubkey_address==\"$addr\") | .prevout.value" 2>/dev/null | \
        awk '{s+=$1} END{print int(s)}')
      sent=${sent:-0}

      local net=$(( recv - sent ))
      local abs_net=$(( net < 0 ? -net : net ))
      [[ $abs_net -eq 0 ]] && continue

      local usd; usd=$(usd_value BTC "$abs_net")
      local dir="IN"; (( net < 0 )) && dir="OUT"
      local conf_flag=""; [[ "$confirmed" == "false" ]] && conf_flag=" [UNCONFIRMED]"

      emit "BTC" "$label" "$tier" "$txid" "$usd" "$dir" "$addr" "$conf_flag"
    done
  done <<< "$addrs"
}

# ── ETH via Etherscan ─────────────────────────────────────────
watch_eth() {
  if [[ -z "$ETHERSCAN_KEY" ]]; then
    err "ETHERSCAN_KEY not set — skipping ETH. Get free key: https://etherscan.io/apis"
    return
  fi

  local addrs; addrs=$(jq -r '.eth[] | "\(.address)|\(.label)|\(.tier)"' "$WHALES_FILE")
  while IFS='|' read -r addr label tier; do
    sleep 0.3  # stay under 5 req/s free limit

    local resp
    resp=$(curl -sf --max-time 15 \
      "https://api.etherscan.io/api?module=account&action=txlist&address=${addr}&sort=desc&offset=3&page=1&apikey=${ETHERSCAN_KEY}" \
      2>/dev/null)
    [[ -z "$resp" ]] && continue

    local status; status=$(echo "$resp" | jq -r '.status')
    [[ "$status" != "1" ]] && continue

    echo "$resp" | jq -c '.result[]' | while read -r tx; do
      local txid; txid=$(echo "$tx" | jq -r '.hash')
      local value; value=$(echo "$tx" | jq -r '.value')
      local from;  from=$(echo  "$tx" | jq -r '.from' | tr '[:upper:]' '[:lower:]')
      local to;    to=$(echo    "$tx" | jq -r '.to'   | tr '[:upper:]' '[:lower:]')
      local lo_addr; lo_addr=$(echo "$addr" | tr '[:upper:]' '[:lower:]')

      [[ "$value" == "0" ]] && continue

      local usd; usd=$(usd_value ETH "$value")
      local dir="IN"
      [[ "$from" == "$lo_addr" ]] && dir="OUT"

      emit "ETH" "$label" "$tier" "$txid" "$usd" "$dir" "$addr"
    done
  done <<< "$addrs"
}

# ── SOL via public RPC ────────────────────────────────────────
watch_sol() {
  local RPC="${SOLANA_RPC:-https://api.mainnet-beta.solana.com}"
  local addrs; addrs=$(jq -r '.sol[] | "\(.address)|\(.label)|\(.tier)"' "$WHALES_FILE")

  while IFS='|' read -r addr label tier; do
    sleep 0.5  # public RPC rate limit courtesy

    # get latest 3 signatures
    local sigs_resp
    sigs_resp=$(curl -sf --max-time 15 "$RPC" \
      -H "Content-Type: application/json" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getSignaturesForAddress\",
           \"params\":[\"$addr\",{\"limit\":3}]}" 2>/dev/null)
    [[ -z "$sigs_resp" ]] && continue

    echo "$sigs_resp" | jq -r '.result[]? | "\(.signature)|\(.err // "ok")"' | \
    while IFS='|' read -r sig err_val; do
      [[ "$err_val" != "ok" && "$err_val" != "null" ]] && continue

      # fetch full tx
      local tx_resp
      tx_resp=$(curl -sf --max-time 15 "$RPC" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTransaction\",
             \"params\":[\"$sig\",{\"encoding\":\"json\",\"maxSupportedTransactionVersion\":0}]}" \
        2>/dev/null)
      [[ -z "$tx_resp" ]] && continue

      # find this address's account index
      local acct_idx
      acct_idx=$(echo "$tx_resp" | jq -r \
        ".result.transaction.message.accountKeys | to_entries[] | select(.value==\"$addr\") | .key" 2>/dev/null | head -1)
      [[ -z "$acct_idx" ]] && continue

      # pre/post balance delta in lamports
      local pre;  pre=$(echo  "$tx_resp" | jq -r ".result.meta.preBalances[$acct_idx]  // 0")
      local post; post=$(echo "$tx_resp" | jq -r ".result.meta.postBalances[$acct_idx] // 0")
      local delta=$(( post - pre ))
      local abs_delta=$(( delta < 0 ? -delta : delta ))
      [[ $abs_delta -lt 10000000 ]] && continue  # ignore <0.01 SOL

      local usd; usd=$(usd_value SOL "$abs_delta")
      local dir="IN"; (( delta < 0 )) && dir="OUT"

      emit "SOL" "$label" "$tier" "$sig" "$usd" "$dir" "$addr"
    done
  done <<< "$addrs"
}

# ── housekeeping ──────────────────────────────────────────────
trim_seen() {
  # keep last 5000 txids to avoid unbounded growth
  local lines; lines=$(wc -l < "$SEEN_FILE")
  if (( lines > 5000 )); then
    tail -n 4000 "$SEEN_FILE" > "${SEEN_FILE}.tmp" && mv "${SEEN_FILE}.tmp" "$SEEN_FILE"
  fi
}

# ── main loop ─────────────────────────────────────────────────
log "${BOLD}🐋 Whale Watcher starting up${RESET}"
log "Watching ${CYAN}$(jq '.btc|length' "$WHALES_FILE") BTC${RESET}, ${CYAN}$(jq '.eth|length' "$WHALES_FILE") ETH${RESET}, ${CYAN}$(jq '.sol|length' "$WHALES_FILE") SOL${RESET} addresses"
log "Alert threshold: \$$(jq -r '.thresholds.alert_usd' "$WHALES_FILE" | xargs printf '%\047d')"
log "Poll interval: ${POLL_INTERVAL}s — press Ctrl+C to stop"
echo "---"

while true; do
  fetch_prices
  watch_btc
  watch_eth
  watch_sol
  trim_seen
  sleep "$POLL_INTERVAL"
done
