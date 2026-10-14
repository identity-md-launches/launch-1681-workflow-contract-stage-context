// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @notice Stateless properties of the token: round trips, idempotence, additivity, conservation across
/// failing calls, the absence of hidden entry points, and the event claims the ABI documentation makes.
contract LaunchTokenPropertiesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    bytes32 private constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant APPROVAL_SIG = keccak256("Approval(address,address,uint256)");

    LaunchToken private token;
    address private alice;
    address private bob;
    address private carol;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        token = new LaunchToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Round trips and algebra
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TransferRoundTripRestoresBothBalances(uint256 funding, uint256 amount) public {
        funding = bound(funding, 0, SUPPLY);
        amount = bound(amount, 0, funding);
        token.transfer(alice, funding);

        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(alice, amount);

        assertEq(token.balanceOf(alice), funding);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - funding);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SplitTransferEqualsSingleTransfer(uint256 x, uint256 y) public {
        x = bound(x, 0, SUPPLY);
        y = bound(y, 0, SUPPLY - x);
        LaunchToken other = new LaunchToken();

        token.transfer(alice, x);
        token.transfer(alice, y);
        other.transfer(alice, x + y);

        assertEq(token.balanceOf(alice), other.balanceOf(alice));
        assertEq(token.balanceOf(address(this)), other.balanceOf(address(this)));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ApproveIsIdempotentAndLastWriteWins(uint256 first, uint256 second) public {
        token.approve(alice, first);
        token.approve(alice, first);
        assertEq(token.allowance(address(this), alice), first);
        token.approve(alice, second);
        assertEq(token.allowance(address(this), alice), second);
        // An approval never moves tokens, whatever the amount.
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_AllowanceIsPerPairAndDoesNotLeak(address spenderA, address spenderB, uint256 amount) public {
        vm.assume(spenderA != address(0) && spenderB != address(0) && spenderA != spenderB);
        token.approve(spenderA, amount);
        assertEq(token.allowance(address(this), spenderA), amount);
        assertEq(token.allowance(address(this), spenderB), 0);
        assertEq(token.allowance(spenderA, address(this)), 0);
        assertEq(token.allowance(spenderA, spenderB), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_MaxAllowanceSurvivesAnySequenceOfSpends(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        c = bound(c, 0, SUPPLY - a - b);
        token.approve(alice, type(uint256).max);
        vm.startPrank(alice);
        token.transferFrom(address(this), bob, a);
        token.transferFrom(address(this), carol, b);
        token.transferFrom(address(this), alice, c);
        vm.stopPrank();
        assertEq(token.allowance(address(this), alice), type(uint256).max);
        assertEq(token.balanceOf(bob) + token.balanceOf(carol) + token.balanceOf(alice), a + b + c);
        assertEq(token.balanceOf(address(this)), SUPPLY - a - b - c);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FiniteAllowanceJustBelowMaxIsStillDecremented(uint256 spend) public {
        spend = bound(spend, 1, SUPPLY);
        uint256 nearMax = type(uint256).max - 1;
        token.approve(alice, nearMax);
        vm.prank(alice);
        token.transferFrom(address(this), bob, spend);
        assertEq(token.allowance(address(this), alice), nearMax - spend);
    }

    // ---------------------------------------------------------------------------------------------
    // Conservation across failing calls
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_AnyTransferAttemptConservesSupplyAndPairSum(uint256 funding, uint256 amount, address to) public {
        funding = bound(funding, 0, SUPPLY);
        token.transfer(alice, funding);
        uint256 toBefore = token.balanceOf(to);
        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));

        if (to == address(0)) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        } else if (amount > funding) {
            assertFalse(ok);
            assertEq(
                ret, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funding, amount)
            );
        } else {
            assertTrue(ok);
            assertEq(abi.decode(ret, (bool)), true);
        }

        if (!ok) {
            assertEq(token.balanceOf(alice), aliceBefore);
            assertEq(token.balanceOf(to), toBefore);
        } else if (to != alice) {
            assertEq(token.balanceOf(alice), aliceBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        } else {
            assertEq(token.balanceOf(alice), aliceBefore);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_AnyTransferFromAttemptIsAllOrNothing(uint256 funding, uint256 allowed, uint256 amount) public {
        funding = bound(funding, 0, SUPPLY);
        token.transfer(alice, funding);
        vm.prank(alice);
        token.approve(bob, allowed);

        vm.prank(bob);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transferFrom, (alice, carol, amount)));

        bool infinite = allowed == type(uint256).max;
        if (!infinite && amount > allowed) {
            assertFalse(ok);
            assertEq(
                ret, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowed, amount)
            );
        } else if (amount > funding) {
            assertFalse(ok);
            assertEq(
                ret, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funding, amount)
            );
        } else {
            assertTrue(ok);
        }

        if (ok) {
            assertEq(token.balanceOf(alice), funding - amount);
            assertEq(token.balanceOf(carol), amount);
            assertEq(token.allowance(alice, bob), infinite ? allowed : allowed - amount);
        } else {
            // A failed transferFrom must not have spent any allowance or moved anything.
            assertEq(token.balanceOf(alice), funding);
            assertEq(token.balanceOf(carol), 0);
            assertEq(token.allowance(alice, bob), allowed);
        }
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_EmptyAccountCannotSendAnythingPositive(address sender, address to, uint256 amount) public {
        assumeNotForgeAddress(sender);
        assumeNotPrecompile(sender);
        vm.assume(sender != address(this) && to != address(0));
        amount = bound(amount, 1, type(uint256).max);
        if (sender == address(0)) {
            // The zero address is refused as a sender before its (zero) balance is even consulted.
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        } else {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, sender, 0, amount));
        }
        vm.prank(sender);
        token.transfer(to, amount);
        assertEq(token.balanceOf(sender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_HolderNeedsAllowanceToTransferFromThemself(uint256 amount) public {
        // The ABI docs say transferFrom requires an allowance even when the caller is the holder.
        amount = bound(amount, 1, SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, amount)
        );
        token.transferFrom(address(this), alice, amount);
        assertEq(token.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Edge pins
    // ---------------------------------------------------------------------------------------------

    function test_OneWeiTransferAndBack() public {
        token.transfer(alice, 1);
        assertEq(token.balanceOf(alice), 1);
        vm.prank(alice);
        token.transfer(address(this), 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_FullSupplyCanMoveInOneTransfer() public {
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.transfer(alice, 1);
    }

    function test_FullSupplyPlusOneRevertsEvenWhenSplitAcrossAccounts() public {
        // No way to produce SUPPLY + 1 tokens anywhere, however the supply is arranged.
        token.transfer(alice, SUPPLY / 2);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, SUPPLY / 2, SUPPLY / 2 + 1)
        );
        token.transfer(bob, SUPPLY / 2 + 1);
        assertEq(token.balanceOf(alice) + token.balanceOf(address(this)), SUPPLY);
    }

    function test_ApproveSelfAndSpendOwnAllowance() public {
        token.approve(address(this), 5);
        token.transferFrom(address(this), alice, 5);
        assertEq(token.allowance(address(this), address(this)), 0);
        assertEq(token.balanceOf(alice), 5);
    }

    function test_SpendingAllowanceDoesNotEmitApproval() public {
        // The ABI README states transferFrom does not emit Approval; the vendored 5.0.2 code agrees.
        token.approve(alice, 100);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(address(this), bob, 40);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], TRANSFER_SIG);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(this)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(abi.decode(logs[0].data, (uint256)), 40);
        assertEq(token.allowance(address(this), alice), 60);
    }

    function test_ConstructorEmitsExactlyOneLog() public {
        vm.recordLogs();
        LaunchToken fresh = new LaunchToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], TRANSFER_SIG);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_ApproveEmitsExactlyOneApprovalLog() public {
        vm.recordLogs();
        token.approve(alice, 7);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], APPROVAL_SIG);
        assertEq(abi.decode(logs[0].data, (uint256)), 7);
    }

    function test_ViewFunctionsAreSideEffectFree() public {
        vm.recordLogs();
        token.name();
        token.symbol();
        token.decimals();
        token.totalSupply();
        token.balanceOf(alice);
        token.allowance(alice, bob);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Hidden entry points
    // ---------------------------------------------------------------------------------------------

    function _isDocumentedSelector(bytes4 sel) private pure returns (bool) {
        return sel == IERC20.name.selector || sel == IERC20.symbol.selector || sel == IERC20.decimals.selector
            || sel == IERC20.totalSupply.selector || sel == IERC20.balanceOf.selector
            || sel == IERC20.allowance.selector || sel == IERC20.transfer.selector || sel == IERC20.approve.selector
            || sel == IERC20.transferFrom.selector;
    }

    /// @dev Random selectors reject with empty return data: there is no fallback, no receive and no function
    /// outside the nine the ABI documents. Does not reach a function by chance, so combined with the
    /// curated admin-selector list in LaunchToken.t.sol.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_UndocumentedSelectorsAlwaysRevertWithoutData(bytes4 sel, bytes memory args, address caller)
        public
    {
        assumeNotForgeAddress(caller);
        assumeNotPrecompile(caller);
        if (_isDocumentedSelector(sel)) sel = bytes4(uint32(sel) ^ 0x80000000);
        assertFalse(_isDocumentedSelector(sel));
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(abi.encodePacked(sel, args));
        assertFalse(ok, "undocumented selector succeeded");
        assertEq(ret.length, 0, "undocumented selector returned data");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_EtherIsNeverAccepted(uint96 value, bytes memory data) public {
        uint256 v = bound(uint256(value), 1, 1000 ether);
        vm.deal(address(this), v);
        (bool ok,) = address(token).call{value: v}(data);
        assertFalse(ok);
        assertEq(address(token).balance, 0);
        assertEq(address(this).balance, v);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_DocumentedViewSelectorsNeverRevertForAnyArguments(address a, address b) public view {
        // Reads must be safe for any caller and any arguments; a frontend relies on this.
        (bool ok1, bytes memory r1) = address(token).staticcall(abi.encodeCall(IERC20.balanceOf, (a)));
        (bool ok2, bytes memory r2) = address(token).staticcall(abi.encodeCall(IERC20.allowance, (a, b)));
        assertTrue(ok1 && ok2);
        assertEq(abi.decode(r1, (uint256)), a == address(this) ? SUPPLY : 0);
        assertEq(abi.decode(r2, (uint256)), 0);
    }

    function test_ShortCalldataForDocumentedFunctionsReverts() public {
        // ABI decoding of malformed calldata must fail rather than default arguments to zero.
        (bool ok1,) = address(token).call(abi.encodePacked(IERC20.transfer.selector, alice));
        assertFalse(ok1);
        (bool ok2,) = address(token).call(abi.encodePacked(IERC20.approve.selector));
        assertFalse(ok2);
        (bool ok3,) = address(token).call(abi.encodePacked(IERC20.transferFrom.selector, uint256(1)));
        assertFalse(ok3);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_ConformsToForgeStdErc20Interface() public {
        // The token is reachable through a third-party ERC-20 interface, as pool, distributor and frontend
        // will reach it.
        IERC20 erc20 = IERC20(address(token));
        assertEq(erc20.name(), "Daemon");
        assertEq(erc20.symbol(), "DAEMON");
        assertEq(erc20.decimals(), 18);
        assertEq(erc20.totalSupply(), SUPPLY);
        assertTrue(erc20.approve(alice, 3));
        assertEq(erc20.allowance(address(this), alice), 3);
        assertTrue(erc20.transfer(alice, 2));
        vm.prank(alice);
        assertTrue(erc20.transferFrom(address(this), bob, 3));
        assertEq(erc20.balanceOf(alice), 2);
        assertEq(erc20.balanceOf(bob), 3);
    }
}
