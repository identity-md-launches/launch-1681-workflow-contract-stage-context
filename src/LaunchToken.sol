// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Daemon
/// @notice Fixed-supply ERC-20 for the Daemon launch on Ethereum.
/// @dev The factory receives the entire supply and handles launch allocations.
/// There are no external mint, burn, administration, fee, or upgrade functions.
contract LaunchToken is ERC20 {
    uint256 private constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Mints one billion DAEMON, with 18 decimals, to the deploying factory.
    /// @dev Nonpayable, no arguments, and no external calls or initialization step.
    constructor() ERC20("Daemon", "DAEMON") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
