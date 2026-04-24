# 🐋 Whale Watcher

Monitor BTC, ETH, and SOL whale wallets using 100% free APIs inside a Claude Code session.

## Files

```
whale_watcher/
├── whale_watch.sh   # main polling script — Claude monitors this
├── whales.json      # whale address list with labels + alert thresholds
├── CLAUDE.md        # session instructions for Claude Code
└── README.md        # this file
```

## Quick Start

### 1. Get a free Etherscan API key
Go to https://etherscan.io/apis → "Get API Key" (free, instant)

### 2. Set it in your shell
```bash
export ETHERSCAN_KEY=YourKeyHere
```

### 3. Make the script executable
```bash
chmod +x whale_watch.sh
```

### 4. Open a Claude Code session and run:
```
Monitor whale_watch.sh and alert me on significant whale moves. Follow CLAUDE.md.
```

Claude Code will start `whale_watch.sh` as a background Monitor process and react
to events as they stream in.

---

## APIs Used (all free)

| Chain | API | Key Required |
|---|---|---|
| BTC | mempool.space REST | ❌ None |
| ETH | Etherscan v1 | ✅ Free signup |
| SOL | Solana public RPC | ❌ None |
| Prices | CoinGecko simple price | ❌ None |

## Optional: Better Solana RPC

The public Solana RPC can be rate-limited. For more reliable polling, get a free
key from Helius (https://helius.dev, 100k req/day free) and set:
```bash
export SOLANA_RPC=https://mainnet.helius-rpc.com/?api-key=YOUR_KEY
```

## Customizing Alerts

Edit `whales.json` to:
- Add/remove addresses
- Change `alert_usd`, `high_priority_usd`, `critical_usd` thresholds
- Add your own watched wallets

## Adding Your Own Wallets

```json
{ "address": "YOUR_ADDRESS_HERE", "label": "My Watch Wallet", "tier": "whale" }
```

Supported tiers: `exchange`, `founder`, `whale`, `market_maker`, `bankrupt_estate`,
`government`, `dormant_threat`, `stablecoin`

## Notes

- ETH free tier: 5 req/s, 100k req/day — the script paces itself with sleeps
- BTC mempool.space: no rate limits documented, script polls 3 txs per address
- Seen txids are tracked in `/tmp/whale_watch_seen.txt` to avoid duplicate alerts
- Script auto-trims seen list at 5000 entries
