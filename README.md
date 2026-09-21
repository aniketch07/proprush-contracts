# PropRush — Smart Contracts

The "money box" for the PropRush Monopoly game. Built with [Foundry](https://book.getfoundry.sh/)
on Base. Full design + every edge case: **[POOL_DESIGN.md](./POOL_DESIGN.md)**.

## Contracts

| Contract | What it is | Count |
|---|---|---|
| `src/WagerPool.sol` | The money box for **one match**. Buy-ins in, winner out (95%), platform 5%. | One per game |
| `src/WagerPoolFactory.sol` | The pool maker. Frontend calls this to deploy a `WagerPool` per room. | 1 (deployed once) |
| `src/MockUSDC.sol` | **Fake** USDC (6 decimals) for testing. Not part of the product. | testnet only |

## Roles

| Role | Who | Power |
|---|---|---|
| **host** | Room creator | Lobby only — `kickPlayer`, `refund`, `start`. **Zero money power after `start()`.** |
| **keeper** | Game server | Only address that can `proposeResult` (name a winner). |
| **resolver** | Platform multi-sig (**neutral**) | Resolves disputes + voids stuck matches. **Never the host.** |

## The invariant

> Nobody can take money except (a) a player themselves before `start()` — leave / kicked /
> cancelled → refund — or (b) a settled match result. Every other path refunds.

## Money flow

```
join() pays buyIn ─▶ WagerPool (escrow holds all buy-ins)
                        │
host start() ───────────┤  money is now COMMITTED (host has no power)
                        │
keeper proposeResult() ─┤  dispute window opens
                        │
finalize() / resolver ──┤  result final
                        │
winner claim() ─────────┴▶ winner 95%  ·  treasury 5%
```

## Functions

| Function | Who | When |
|---|---|---|
| `join()` | player | Open |
| `leave()` | player | Open — refunds them |
| `kickPlayer(addr)` | host | Open — refunds the victim (host gets nothing) |
| `refund()` | host | Open — refunds everyone (cancel lobby) |
| `refundAfterTimeout()` | anyone | Open, after `lobbyTimeout` — rescues an abandoned lobby |
| `start()` | host | Open, ≥2 players — locks the pool |
| `proposeResult(winner)` | keeper | Locked — winner must have joined |
| `dispute()` | player | Proposed, within window |
| `resolveDispute(winner)` | **resolver** | Disputed |
| `finalize()` | anyone | Proposed, window passed |
| `emergencyRefund()` | **resolver** | after `matchTimeout` — voids a stuck match |
| `claim()` | winner | Settled — pulls the payout |

## Development

```bash
forge build    # compile
forge test     # 44 tests
forge fmt      # format
```

## Local deploy

```bash
anvil                                                                  # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2
```

## Base Sepolia (testnet)

```bash
cp .env.example .env      # then put PRIVATE_KEY in it (fresh throwaway wallet!)
forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify
```

Get free test ETH: https://www.alchemy.com/faucets/base-sepolia

The script deploys **MockUSDC + WagerPoolFactory** by default and prints both addresses.
Set `USDC_ADDRESS` in `.env` to use real USDC instead. See `.env.example` for all options.

## Base mainnet (later, real money)

1. Set `USDC_ADDRESS` to the real USDC contract
2. Point `--rpc-url base`
3. **Get an external audit first**

## Testing in Remix

`remix/` has paste-ready copies (OpenZeppelin imported via GitHub URL, no setup).

## Notes / future work

- **Resolver liveness:** a `Disputed` pool can only be settled by the resolver. If the
  resolver goes permanently offline, those funds are frozen. Planned fix: after a long
  grace period, let anyone refund a disputed pool so money can never be stuck forever.
- **Keeper bond + result hash:** commit the final game state on-chain so a wrong result is
  provably detectable, and slash a bonded keeper that lies.
- **Collusion:** 3 friends splitting a pot is a matchmaking/trust problem, not a contract
  one. Handled with trusted private rooms + random matchmaking for public games.
