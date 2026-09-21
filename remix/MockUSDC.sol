// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.7.0/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice FAKE USDC for testing on local/testnet ONLY.
 *         Real USDC (6 decimals) is used on Base mainnet when we launch.
 *         Anyone can mint here — that's intentional, it's test money.
 */
contract MockUSDC is ERC20 {
    // USDC has 6 decimals in real life. Matching it keeps amounts realistic.
    uint8 private constant _DECIMALS = 6;

    constructor() ERC20("Mock USDC", "mUSDC") {
        // Give the deployer a starting bag of test money.
        _mint(msg.sender, 1_000_000 * 10 ** _DECIMALS); // 1,000,000 mUSDC
    }

    /// @dev Free test tokens for anyone who asks. Testnet only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }
}
