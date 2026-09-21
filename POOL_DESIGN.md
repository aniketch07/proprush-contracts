# WagerPool — Final Design (v2)

The agreed design after reviewing every edge case. Applies to the contracts in `src/`.

---

## Core invariant (the one rule everything hangs on)

> **Nobody can take money out of the pool except (a) the player themselves before the game locks, or (b) a settled match result. Every other path refunds the player.**

- A kick, leave, cancellation, or timeout **always refunds** — it never pays the kicker/canceller.
- The only way money changes hands to another player is a **settled result** of a match you agreed to play.
- Worst case for any player = "game cancelled, money back." Never robbery.

---

## Roles (3 separate people — this matters)

| Role | Who | Power |
|---|---|---|
| **Host** | Room creator | Lobby only: `join`, `start`, `kick`, `cancel`. **Zero money power after `start()`.** |
| **Keeper** | Game server | Only one who can `proposeResult` (name a winner). |
| **Resolver** | Platform multi-sig (NEUTRAL) | Settles disputes + timeouts. **Never the host** (host is a player with a conflict of interest). |

The factory assigns keeper + resolver. The host is just whoever calls `createPool`.

---

## State machine

```
              join() xN                  start()            proposeResult()
  Open ───────────────────────► Locked ─────────────────► Proposed
   │                             │                          │  (dispute window open)
   │ refund() / refundTimeout()  │                          │
   │ (money back to all)         │                          │ dispute()
   ▼                             ▼                          ▼
Refunded                      (no exit here —        Disputed ──► resolveDispute() (resolver)
 lobby cancelled)              money committed)                 Settled
   │                                                      │
   │                  finalize() (window passed)          │
   └──────────────────────────────────────────────────────┴──► Settled ──► winner claim()
```

`emergencyRefund()` (resolver) can void a **stuck** Locked/Proposed/Disputed pool after a long timeout — refunds everyone.

---

## Functions

| Function | Who | When | What it does |
|---|---|---|---|
| `join()` | any player | Open | Pay buy-in, enter pool |
| `leave()` | a player | Open | **Refund that player**, remove them |
| `kickPlayer(addr)` | host | Open | **Refund that player**, remove them (host never receives it) |
| `refund()` | host | Open | Cancel lobby, refund **all** |
| `refundAfterTimeout()` | anyone | Open, after `lobbyTimeout` | Refund all if host abandoned the lobby |
| `start()` | host | Open, ≥2 players | Lock the pool — money committed |
| `proposeResult(winner)` | keeper | Locked | Name the winner; must have joined. Window opens |
| `dispute()` | any player | Proposed, in window | Challenge the result |
| `resolveDispute(winner)` | **resolver** | Disputed | Fix or confirm the winner → Settled |
| `finalize()` | anyone | Proposed, window passed | Result becomes final |
| `emergencyRefund()` | resolver | Locked/Proposed/Disputed after `matchTimeout` | Refund all if the match is stuck |
| `claim()` | winner | Settled | Pull payout (95%) — fee (5%) to treasury |

---

## Every edge case → how it's handled

| # | Scenario | Handling |
|---|---|---|
| 1 | Player leaves lobby before start | `leave()` → **refund to player** |
| 2 | Host kicks player before start (any reason) | `kickPlayer()` → **refund to kicked player**, host gains nothing |
| 3 | Host never starts / abandons lobby | `refundAfterTimeout()` by anyone after X hrs → **all refunded** |
| 4 | Player rage-quits mid-game | **No refund.** Server settles result (quitter = bankrupt); stake → rightful winner |
| 5 | Player disconnects mid-game | Same as #4 — treated as forfeit, result settles |
| 6 | Cheating mid-game | **No kick, not even votes** (team decision). The game server (keeper) simply settles the match with the cheater disqualified/bankrupt → stake → rightful winner. Never to host. Wrong call → `dispute()` |
| 7 | Host tries to kick someone mid-game | **No such function exists.** Impossible |
| 8 | Host tries to steal the pool | Host has **zero** money power after `start()`. Can't refund, can't name winner (only keeper), can't resolve disputes (only resolver) |
| 9 | Keeper names a wrong winner | Players `dispute()` in window → resolver fixes |
| 10 | Wrongly kicked/disqualified player | `dispute()` → resolver reviews → refund if unjust |
| 11 | 3 friends collude, kick innocent **in lobby** | Innocent gets **refunded**. Colluders gain nothing from the kick |
| 12 | 3 friends collude to steal **mid-game** | Innocent can `dispute()` → resolver. Residual risk = plain collusion (exists in all money games); handled by trusted private rooms / random matchmaking / bans, **not the contract** |
| 13 | Host starts, then everyone vanishes (stuck match) | Resolver `emergencyRefund()` after long timeout → all refunded |
| 14 | Winner claims twice | `claimed` flag blocks it |
| 15 | Non-winner tries to claim | Only `winner` can `claim()` |
| 16 | Random address tries to `proposeResult` | Only keeper |
| 17 | Winner wasn't a real player | `proposeResult` requires the winner to have `joined` |
| 18 | Reentrancy / callback attack | Pull payments + `ReentrancyGuard` on every money function |

---

## What changes from the current v1 code

1. **New functions:** `leave()`, `kickPlayer()`, `refundAfterTimeout()`, `emergencyRefund()`, `lobbyTimeout`/`matchTimeout` state.
2. **Resolver role replaces host for disputes:** `resolveDispute` becomes resolver-only; factory sets resolver (default = its own owner = platform). Host no longer resolves.
3. **No refund after start:** `refund()`/`kickPlayer()`/`leave()` all require `Open`. Once `Locked`, host has no money functions.
4. **Anti-collusion default:** kicks only exist in the lobby and always refund the victim.

## What stays OFF-chain (Sahitya's side)

- Anti-cheat detection + the final match result. The game server is the keeper — it
  penalizes cheaters simply by **settling the result** (cheater = bankrupt/last).
  No "kick" mechanism is needed at all.
- Matchmaking rules to prevent coordinated collusion in public lobbies.
- (Optional, only if ever wanted) an in-app vote for *consensus only* before the
  server penalizes someone — purely a UI signal, never touches the contract.

## Not in v1 (future)

- Keeper **bond** + slashing (aligns the server's incentive).
- **Result hash** (server commits final game state so a wrong result is provable).
- On-chain vote-to-forfeit (gas-heavy, unnecessary while the dispute window exists).
- External audit before mainnet.
