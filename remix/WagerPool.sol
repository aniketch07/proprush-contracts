// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.7.0/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.7.0/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.7.0/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WagerPool
 * @notice The "money box" for ONE match. Created by the WagerPoolFactory.
 *
 * ── Lifecycle ────────────────────────────────────────────────────────
 *   Open      → players join(); leave()/kick/refund all return money (lobby)
 *   Locked    → host start()ed the match. Money is committed from here on.
 *   Proposed  → keeper proposeResult(winner); dispute window opens
 *   Settled   → result final → winner claim()s (95%), platform fee → treasury (5%)
 *   Disputed  → a player challenge()d; NEUTRAL resolver decides
 *   Refunded  → everyone got their buy-in back
 *
 * ── Roles ───────────────────────────────────────────────────────────
 *   host     → lobby powers ONLY (join, start, kick in lobby, cancel). After
 *              start() the host has ZERO power over the money.
 *   keeper   → the game server. The ONLY address that can name a winner.
 *   resolver → NEUTRAL platform address. Resolves disputes and stuck matches.
 *              Never the host (the host is a player with a conflict of interest).
 *
 * ── The invariant ───────────────────────────────────────────────────
 *   Nobody can take money except (a) a player themselves before start
 *   (leave / kicked / cancelled → refund) or (b) a settled match result.
 *   Every other path refunds the player. Kicks always refund the victim.
 */
contract WagerPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status { Open, Locked, Proposed, Disputed, Settled, Refunded }

    // ────────────────────────────── State ──────────────────────────────
    IERC20 public immutable usdc;          // settlement token
    address public immutable factory;      // who created us
    address public immutable host;         // room creator — lobby powers only
    address public immutable keeper;       // game server — names the winner
    address public immutable resolver;     // NEUTRAL — resolves disputes & stuck matches
    address public immutable treasury;     // platform 5% fee goes here

    uint256 public immutable buyIn;        // entry fee per player
    uint16  public immutable feeBps;       // platform fee in basis points (500 = 5%)
    uint8   public immutable maxPlayers;
    uint256 public immutable disputeWindow; // seconds a proposed result can be disputed
    uint256 public immutable lobbyTimeout;  // seconds after which anyone can refund an abandoned lobby
    uint256 public immutable matchTimeout;  // seconds after which resolver can void a stuck match

    uint256 public immutable createdAt;     // when the pool was created (lobby refund clock)
    uint256 public startedAt;               // when the match started (emergency clock)

    Status public status;
    address public winner;
    uint256 public proposalTime;

    address[] public players;
    mapping(address => bool) public joined;
    bool public claimed;

    // ────────────────────────────── Events ─────────────────────────────
    event PoolJoined(address indexed player);
    event PoolStarted(address indexed host);
    event PlayerRemoved(address indexed player);
    event ResultProposed(address indexed winner);
    event ResultDisputed(address indexed player);
    event ResultResolved(address indexed winner);
    event ResultFinalized(address indexed winner);
    event Claimed(address indexed winner, uint256 amount);
    event PoolRefunded();

    // ──────────────────────────── Modifiers ────────────────────────────
    modifier onlyFactory() {
        require(msg.sender == factory, "WagerPool: not factory");
        _;
    }

    modifier onlyHost() {
        require(msg.sender == host, "WagerPool: not host");
        _;
    }

    modifier onlyKeeper() {
        require(msg.sender == keeper, "WagerPool: not keeper");
        _;
    }

    modifier onlyResolver() {
        require(msg.sender == resolver, "WagerPool: not resolver");
        _;
    }

    modifier onlyJoinedPlayer() {
        require(joined[msg.sender], "WagerPool: not a player");
        _;
    }

    // ─────────────────────────── Constructor ───────────────────────────
    constructor(
        address _usdc,
        address _host,
        address _keeper,
        address _resolver,
        address _treasury,
        uint256 _buyIn,
        uint16 _feeBps,
        uint8 _maxPlayers,
        uint256 _disputeWindow,
        uint256 _lobbyTimeout,
        uint256 _matchTimeout
    ) {
        require(_usdc != address(0), "WagerPool: zero usdc");
        require(_host != address(0), "WagerPool: zero host");
        require(_keeper != address(0), "WagerPool: zero keeper");
        require(_resolver != address(0), "WagerPool: zero resolver");
        require(_buyIn > 0, "WagerPool: zero buyIn");
        require(_feeBps <= 10_000, "WagerPool: feeBps > 100%");
        require(_maxPlayers >= 2, "WagerPool: need >= 2 players");

        usdc = IERC20(_usdc);
        factory = msg.sender;
        host = _host;
        keeper = _keeper;
        resolver = _resolver;
        treasury = _treasury;
        buyIn = _buyIn;
        feeBps = _feeBps;
        maxPlayers = _maxPlayers;
        disputeWindow = _disputeWindow;
        lobbyTimeout = _lobbyTimeout;
        matchTimeout = _matchTimeout;
        createdAt = block.timestamp;

        status = Status.Open;
    }

    // ─────────────────────── Lobby: join & refunds ─────────────────────

    /// @notice Join the pool. Player must approve this contract to spend `buyIn` first.
    function join() external nonReentrant {
        require(status == Status.Open, "WagerPool: not open");
        require(!joined[msg.sender], "WagerPool: already joined");
        require(players.length < maxPlayers, "WagerPool: pool full");

        joined[msg.sender] = true;
        players.push(msg.sender);

        usdc.safeTransferFrom(msg.sender, address(this), buyIn);

        emit PoolJoined(msg.sender);
    }

    /// @notice A player leaves the lobby → they get their buy-in back.
    ///         The host cannot leave (they must cancel the lobby with refund()).
    function leave() external nonReentrant {
        require(status == Status.Open, "WagerPool: not open");
        require(msg.sender != host, "WagerPool: host must refund instead");
        require(joined[msg.sender], "WagerPool: not a player");

        _removePlayer(msg.sender);
    }

    /// @notice Host removes a player from the lobby → that player is refunded.
    ///         The host NEVER receives this money (kick = refund victim).
    function kickPlayer(address player) external nonReentrant onlyHost {
        require(status == Status.Open, "WagerPool: not open");
        require(player != host, "WagerPool: cannot kick host");
        require(joined[player], "WagerPool: not a player");

        _removePlayer(player);
    }

    /// @notice Host cancels the whole lobby → everyone refunded.
    function refund() external nonReentrant onlyHost {
        require(status == Status.Open, "WagerPool: not refundable");
        _refundAll();
    }

    /// @notice If the host abandons the lobby (never starts), anyone can refund
    ///         everyone after `lobbyTimeout` has passed. Protects stuck money.
    function refundAfterTimeout() external nonReentrant {
        require(status == Status.Open, "WagerPool: not open");
        require(block.timestamp >= createdAt + lobbyTimeout, "WagerPool: lobby timeout not reached");
        _refundAll();
    }

    /// @notice Host locks the pool when the match starts. After this point the
    ///         host has ZERO money power — no kick, no refund, nothing.
    function start() external onlyHost {
        require(status == Status.Open, "WagerPool: not open");
        require(players.length >= 2, "WagerPool: need >= 2 players");

        startedAt = block.timestamp;
        status = Status.Locked;
        emit PoolStarted(msg.sender);
    }

    // ─────────────────────── Result & dispute flow ─────────────────────

    /// @notice Game server names the winner. NOT final — dispute window opens.
    function proposeResult(address _winner) external onlyKeeper {
        require(status == Status.Locked, "WagerPool: not locked");
        require(joined[_winner], "WagerPool: winner did not join");

        winner = _winner;
        proposalTime = block.timestamp;
        status = Status.Proposed;
        emit ResultProposed(_winner);
    }

    /// @notice Any player can dispute a proposed result during the window.
    function dispute() external onlyJoinedPlayer {
        require(status == Status.Proposed, "WagerPool: nothing to dispute");
        require(block.timestamp <= proposalTime + disputeWindow, "WagerPool: window over");

        status = Status.Disputed;
        emit ResultDisputed(msg.sender);
    }

    /// @notice NEUTRAL resolver fixes/confirms the winner of a disputed result.
    ///         NOT the host — the host is a player and can't be the judge.
    function resolveDispute(address _winner) external onlyResolver {
        require(status == Status.Disputed, "WagerPool: not disputed");
        require(joined[_winner], "WagerPool: winner did not join");

        winner = _winner;
        status = Status.Settled;
        emit ResultResolved(_winner);
    }

    /// @notice Anyone can finalize once the dispute window passed (no dispute).
    function finalize() external {
        require(status == Status.Proposed, "WagerPool: nothing to finalize");
        require(block.timestamp >= proposalTime + disputeWindow, "WagerPool: window not over");

        status = Status.Settled;
        emit ResultFinalized(winner);
    }

    /// @notice If a started match is stuck (nobody settled for `matchTimeout`),
    ///         the resolver voids it and everyone is refunded.
    function emergencyRefund() external nonReentrant onlyResolver {
        require(
            status == Status.Locked || status == Status.Proposed || status == Status.Disputed,
            "WagerPool: not stuck"
        );
        require(block.timestamp >= startedAt + matchTimeout, "WagerPool: match timeout not reached");
        _refundAll();
    }

    /// @notice Winner pulls their payout. Platform fee goes to treasury.
    function claim() external nonReentrant {
        require(status == Status.Settled, "WagerPool: not settled");
        require(msg.sender == winner, "WagerPool: not the winner");
        require(!claimed, "WagerPool: already claimed");

        claimed = true;

        uint256 totalPool = buyIn * players.length;
        uint256 platformFee = (totalPool * feeBps) / 10_000;
        uint256 payout = totalPool - platformFee;

        usdc.safeTransfer(treasury, platformFee);
        usdc.safeTransfer(winner, payout);

        emit Claimed(winner, payout);
    }

    // ─────────────────────────── Internal helpers ──────────────────────

    /// Remove one player from the array (swap-pop) and refund exactly their buy-in.
    function _removePlayer(address player) private {
        joined[player] = false;
        uint256 n = players.length;
        for (uint256 i = 0; i < n; i++) {
            if (players[i] == player) {
                players[i] = players[n - 1];
                players.pop();
                break;
            }
        }
        usdc.safeTransfer(player, buyIn); // refund the victim — never the kicker
        emit PlayerRemoved(player);
    }

    /// Refund every remaining player and mark the pool Refunded (terminal).
    function _refundAll() private {
        status = Status.Refunded;
        uint256 n = players.length;
        for (uint256 i = 0; i < n; i++) {
            usdc.safeTransfer(players[i], buyIn);
        }
        emit PoolRefunded();
    }

    // ───────────────────────────── View helpers ─────────────────────────

    function playerCount() external view returns (uint256) {
        return players.length;
    }

    function getPlayers() external view returns (address[] memory) {
        return players;
    }

    function isJoined(address player) external view returns (bool) {
        return joined[player];
    }

    function poolValue() external view returns (uint256) {
        return buyIn * players.length;
    }

    function payoutAmount() external view returns (uint256) {
        uint256 total = buyIn * players.length;
        return total - ((total * feeBps) / 10_000);
    }

    function feeAmount() external view returns (uint256) {
        return (buyIn * players.length * feeBps) / 10_000;
    }

    function poolBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
