// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { WagerPool } from "./WagerPool.sol";

/**
 * @title WagerPoolFactory
 * @notice The "pool maker". One single instance, deployed once.
 *         Every room  →  one new WagerPool  →  money held & settled there.
 */
contract WagerPoolFactory is Ownable {
    // Globals every new pool inherits (owner can update them)
    address public usdc;            // settlement token
    address public keeper;          // game server that submits results
    address public treasury;        // platform fee recipient
    address public resolver;        // NEUTRAL dispute resolver (platform multi-sig)
    uint256 public disputeWindow;   // seconds a proposed result can be disputed
    uint256 public lobbyTimeout;    // seconds before an abandoned lobby can be refunded
    uint256 public matchTimeout;    // seconds before a stuck match can be voided by resolver

    WagerPool[] public pools;
    mapping(address => bool) public isPool;

    event PoolCreated(address indexed pool, address indexed host, uint256 buyIn, uint8 maxPlayers, uint16 feeBps);

    constructor(
        address _usdc,
        address _keeper,
        address _treasury,
        address _resolver,
        uint256 _disputeWindow,
        uint256 _lobbyTimeout,
        uint256 _matchTimeout
    ) Ownable(msg.sender) {
        _setUsdc(_usdc);
        _setKeeper(_keeper);
        _setTreasury(_treasury);
        _setResolver(_resolver);
        disputeWindow = _disputeWindow;
        lobbyTimeout = _lobbyTimeout;
        matchTimeout = _matchTimeout;
    }

    /// @notice Deploy a new WagerPool. Caller (msg.sender) becomes the host.
    function createPool(uint256 buyIn, uint8 maxPlayers, uint16 feeBps) external returns (WagerPool pool) {
        require(buyIn > 0, "Factory: zero buyIn");
        require(maxPlayers >= 2, "Factory: need >= 2 players");
        require(feeBps <= 10_000, "Factory: feeBps > 100%");
        require(usdc != address(0), "Factory: usdc not set");

        pool = new WagerPool({
            _usdc: usdc,
            _host: msg.sender,
            _keeper: keeper,
            _resolver: resolver,
            _treasury: treasury,
            _buyIn: buyIn,
            _feeBps: feeBps,
            _maxPlayers: maxPlayers,
            _disputeWindow: disputeWindow,
            _lobbyTimeout: lobbyTimeout,
            _matchTimeout: matchTimeout
        });

        pools.push(pool);
        isPool[address(pool)] = true;

        emit PoolCreated(address(pool), msg.sender, buyIn, maxPlayers, feeBps);
    }

    // ─────────────────────────── Admin setters ─────────────────────────

    function setUsdc(address _usdc) external onlyOwner {
        _setUsdc(_usdc);
    }

    function setKeeper(address _keeper) external onlyOwner {
        _setKeeper(_keeper);
    }

    function setTreasury(address _treasury) external onlyOwner {
        _setTreasury(_treasury);
    }

    function setResolver(address _resolver) external onlyOwner {
        _setResolver(_resolver);
    }

    function setDisputeWindow(uint256 _disputeWindow) external onlyOwner {
        disputeWindow = _disputeWindow;
    }

    function setLobbyTimeout(uint256 _lobbyTimeout) external onlyOwner {
        lobbyTimeout = _lobbyTimeout;
    }

    function setMatchTimeout(uint256 _matchTimeout) external onlyOwner {
        matchTimeout = _matchTimeout;
    }

    function _setUsdc(address _usdc) private {
        require(_usdc != address(0), "Factory: zero usdc");
        usdc = _usdc;
    }

    function _setKeeper(address _keeper) private {
        require(_keeper != address(0), "Factory: zero keeper");
        keeper = _keeper;
    }

    function _setTreasury(address _treasury) private {
        require(_treasury != address(0), "Factory: zero treasury");
        treasury = _treasury;
    }

    function _setResolver(address _resolver) private {
        require(_resolver != address(0), "Factory: zero resolver");
        resolver = _resolver;
    }

    // ───────────────────────────── View helpers ─────────────────────────

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function getPools() external view returns (WagerPool[] memory) {
        return pools;
    }
}
