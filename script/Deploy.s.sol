// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { MockUSDC } from "../src/MockUSDC.sol";
import { WagerPoolFactory } from "../src/WagerPoolFactory.sol";

/**
 * @title Deploy
 * @notice Deploys MockUSDC (unless a real USDC address is supplied) + WagerPoolFactory.
 *
 * ── Base Sepolia (testnet) ──────────────────────────────────────────
 *   forge script script/Deploy.s.sol \
 *     --rpc-url base_sepolia \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * ── Base mainnet (real money, later) ────────────────────────────────
 *   Set USDC_ADDRESS to the real USDC contract and use --rpc-url base.
 *
 * All values are optional and default to the deployer address, so a solo
 * testnet deploy works with only PRIVATE_KEY set.
 */
contract Deploy is Script {
    // Defaults (seconds)
    uint256 constant DEFAULT_DISPUTE_WINDOW = 10 minutes; // players can dispute a result
    uint256 constant DEFAULT_LOBBY_TIMEOUT = 1 hours;     // abandoned lobby -> anyone refunds
    uint256 constant DEFAULT_MATCH_TIMEOUT = 24 hours;    // stuck match -> resolver voids

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Roles — default to the deployer so testnet works out of the box.
        address keeper = vm.envOr("KEEPER_ADDRESS", deployer);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        address resolver = vm.envOr("RESOLVER_ADDRESS", deployer);

        // Leave USDC_ADDRESS unset to deploy MockUSDC (test money).
        address usdc = vm.envOr("USDC_ADDRESS", address(0));

        uint256 disputeWindow = vm.envOr("DISPUTE_WINDOW_SECONDS", DEFAULT_DISPUTE_WINDOW);
        uint256 lobbyTimeout = vm.envOr("LOBBY_TIMEOUT_SECONDS", DEFAULT_LOBBY_TIMEOUT);
        uint256 matchTimeout = vm.envOr("MATCH_TIMEOUT_SECONDS", DEFAULT_MATCH_TIMEOUT);

        console2.log("=== PropRush :: WagerPool deploy ===");
        console2.log("chainid :", block.chainid);
        console2.log("deployer:", deployer);

        vm.startBroadcast(pk);

        if (usdc == address(0)) {
            MockUSDC mock = new MockUSDC();
            usdc = address(mock);
            console2.log("");
            console2.log("MockUSDC (TEST MONEY):", usdc);
            console2.log("  -> do NOT use this on mainnet");
        } else {
            console2.log("");
            console2.log("Using existing USDC :", usdc);
        }

        WagerPoolFactory factory =
            new WagerPoolFactory(usdc, keeper, treasury, resolver, disputeWindow, lobbyTimeout, matchTimeout);

        vm.stopBroadcast();

        console2.log("");
        console2.log("WagerPoolFactory    :", address(factory));
        console2.log("");
        console2.log("--- roles ---");
        console2.log("keeper   (game server) :", keeper);
        console2.log("treasury (5% fees)     :", treasury);
        console2.log("resolver (disputes)    :", resolver);
        console2.log("");
        console2.log("--- timeouts (seconds) ---");
        console2.log("disputeWindow:", disputeWindow);
        console2.log("lobbyTimeout :", lobbyTimeout);
        console2.log("matchTimeout :", matchTimeout);
        console2.log("");
        console2.log("Next step: hand the factory address + ABI to the frontend.");
        console2.log("Create a pool with: createPool(buyIn, maxPlayers, feeBps)");
        console2.log("  e.g. createPool(10000000, 4, 500)  // $10 buy-in, 4 players, 5% fee");
    }
}
