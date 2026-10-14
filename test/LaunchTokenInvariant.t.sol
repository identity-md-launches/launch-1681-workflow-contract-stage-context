// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @dev Test-only ledger model. Only these four actors receive tokens.
contract TokenHandler is Test {
    LaunchToken private immutable token;
    address[4] public actors;
    uint256[4] public expectedBalances;
    uint256[4][4] public expectedAllowances;

    constructor(LaunchToken token_) {
        token = token_;
        actors[0] = makeAddr("holder one");
        actors[1] = makeAddr("holder two");
        actors[2] = makeAddr("holder three");
        actors[3] = makeAddr("holder four");
        expectedBalances[0] = 1_000_000_000 ether;
    }

    function transfer(uint256 senderSeed, uint256 recipientSeed, uint256 amountSeed) external {
        uint256 sender = senderSeed % 4;
        uint256 recipient = recipientSeed % 4;
        uint256 amount = bound(amountSeed, 0, expectedBalances[sender]);
        vm.prank(actors[sender]);
        assertTrue(token.transfer(actors[recipient], amount));
        expectedBalances[sender] -= amount;
        expectedBalances[recipient] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        expectedAllowances[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 recipientSeed, uint256 amountSeed) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 recipient = recipientSeed % 4;
        uint256 allowed = expectedAllowances[owner][spender];
        uint256 available = expectedBalances[owner];
        uint256 amount = bound(amountSeed, 0, allowed < available ? allowed : available);
        vm.prank(actors[spender]);
        assertTrue(token.transferFrom(actors[owner], actors[recipient], amount));
        expectedBalances[owner] -= amount;
        expectedBalances[recipient] += amount;
        if (allowed != type(uint256).max) {
            expectedAllowances[owner][spender] -= amount;
        }
    }
}

contract LaunchTokenInvariantTest is Test {
    LaunchToken private token;
    TokenHandler private handler;

    function setUp() public {
        token = new LaunchToken();
        handler = new TokenHandler(token);
        token.transfer(handler.actors(0), 1_000_000_000 ether);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = TokenHandler.transfer.selector;
        selectors[1] = TokenHandler.approve.selector;
        selectors[2] = TokenHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_FixedSupplyAndBalancesMatchLedger() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            uint256 balance = token.balanceOf(handler.actors(i));
            assertEq(balance, handler.expectedBalances(i));
            sum += balance;
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), sum);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function invariant_OnlyApprovedAmountsAreSpendable() public view {
        for (uint256 owner; owner < 4; ++owner) {
            for (uint256 spender; spender < 4; ++spender) {
                assertEq(
                    token.allowance(handler.actors(owner), handler.actors(spender)),
                    handler.expectedAllowances(owner, spender)
                );
            }
        }
    }
}
