// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @dev A holder that is a contract and refuses every call: tokens sent to it must still arrive and leave.
contract ContractHolder {
    fallback() external {
        revert("holder refuses calls");
    }

    function send(LaunchToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice Drives the token with valid and deliberately invalid calls in random order.
/// @dev Every invalid call is caught here and checked for the exact revert, so the invariant run (which
/// fails on any uncaught revert) also asserts that failures roll back completely. Ghost variables record
/// what the token should hold. Actors: five EOAs, a contract holder, and the token itself as a would-be
/// recipient. The supply starts with actor 0, standing in for the factory before it splits.
contract AdversarialTokenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant ACTORS = 6;

    LaunchToken public immutable token;
    ContractHolder public immutable contractHolder;

    address[ACTORS] public actors;
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostReceived;
    mapping(address => uint256) public ghostSent;

    uint256 public ghostSuccessfulTransfers;
    uint256 public ghostRejectedCalls;
    uint256 public ghostRecordedTransferCalls;
    uint256 public ghostTransferEventsSeen;
    uint256 public ghostMaxSingleBalance;

    constructor(LaunchToken token_, ContractHolder holder_) {
        token = token_;
        contractHolder = holder_;
        actors[0] = makeAddr("factory stand-in");
        actors[1] = makeAddr("pool stand-in");
        actors[2] = makeAddr("distributor stand-in");
        actors[3] = makeAddr("payer stand-in");
        actors[4] = makeAddr("trader");
        actors[5] = address(holder_);
        ghostBalance[actors[0]] = SUPPLY;
        ghostReceived[actors[0]] = SUPPLY;
        ghostMaxSingleBalance = SUPPLY;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % ACTORS];
    }

    function _bump(address a) private {
        if (ghostBalance[a] > ghostMaxSingleBalance) ghostMaxSingleBalance = ghostBalance[a];
    }

    function _sendAs(address from, address to, uint256 amount) private returns (bool ok) {
        if (from == address(contractHolder)) {
            ok = contractHolder.send(token, to, amount);
        } else {
            vm.prank(from);
            ok = token.transfer(to, amount);
        }
    }

    // ---------------------------------------------------------------------------------------- valid

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, ghostBalance[from]);

        vm.recordLogs();
        assertTrue(_sendAs(from, to, amount));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Exactly one Transfer log from the token, carrying exactly the requested amount: no fee leg.
        assertEq(logs.length, 1, "transfer emitted a different number of logs");
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(abi.decode(logs[0].data, (uint256)), amount);
        ghostTransferEventsSeen += logs.length;
        ghostRecordedTransferCalls++;

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        ghostSuccessfulTransfers++;
        _bump(to);
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = ghostBalance[from];
        assertTrue(_sendAs(from, to, amount));
        ghostBalance[from] = 0;
        ghostBalance[to] += amount;
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        ghostSuccessfulTransfers++;
        _bump(to);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool unlimited) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (owner == address(contractHolder)) owner = actors[4];
        uint256 amount = unlimited ? type(uint256).max : bound(amountSeed, 0, 2 * SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        if (spender == address(contractHolder)) spender = actors[4];
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 cap = allowed < ghostBalance[owner] ? allowed : ghostBalance[owner];
        uint256 amount = bound(amountSeed, 0, cap);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));

        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        ghostSent[owner] += amount;
        ghostReceived[to] += amount;
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        ghostSuccessfulTransfers++;
        _bump(to);
    }

    // -------------------------------------------------------------------------------------- invalid

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excessSeed) external {
        address from = _actor(fromSeed);
        if (from == address(contractHolder)) from = actors[4];
        address to = _actor(toSeed);
        uint256 have = ghostBalance[from];
        uint256 amount = have + bound(excessSeed, 1, type(uint256).max - have);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, have, amount));
        token.transfer(to, amount);
        ghostRejectedCalls++;
    }

    function transferToZero(uint256 fromSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        if (from == address(contractHolder)) from = actors[4];
        uint256 amount = bound(amountSeed, 0, ghostBalance[from]);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        ghostRejectedCalls++;
    }

    function transferFromOverAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excessSeed)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (spender == address(contractHolder)) spender = actors[4];
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed == type(uint256).max) {
            // Unlimited allowance cannot be exceeded; fall back to the balance limit instead.
            uint256 have = ghostBalance[owner];
            uint256 amount = have + bound(excessSeed, 1, type(uint256).max - have);
            vm.prank(spender);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, have, amount));
            token.transferFrom(owner, to, amount);
        } else {
            uint256 amount = allowed + bound(excessSeed, 1, type(uint256).max - allowed);
            vm.prank(spender);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
            token.transferFrom(owner, to, amount);
        }
        ghostRejectedCalls++;
    }

    function transferFromOverBalanceWithinAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (spender == address(contractHolder)) spender = actors[4];
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 have = ghostBalance[owner];
        if (allowed <= have) return; // nothing to exceed within the allowance
        uint256 amount = have + 1;
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, have, amount));
        token.transferFrom(owner, to, amount);
        // The allowance is untouched by the failed spend.
        assertEq(token.allowance(owner, spender), allowed);
        ghostRejectedCalls++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        if (owner == address(contractHolder)) owner = actors[4];
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        ghostRejectedCalls++;
    }

    function sendEther(uint256 fromSeed, uint256 valueSeed) external {
        address from = _actor(fromSeed);
        if (from == address(contractHolder)) from = actors[4];
        uint256 value = bound(valueSeed, 1, 100 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
        ghostRejectedCalls++;
    }

    function attemptPrivilegedCall(uint256 fromSeed, uint256 which, uint256 amount) external {
        address from = _actor(fromSeed);
        if (from == address(contractHolder)) from = actors[4];
        bytes memory data;
        which %= 8;
        if (which == 0) data = abi.encodeWithSignature("mint(address,uint256)", from, amount);
        else if (which == 1) data = abi.encodeWithSignature("burn(uint256)", amount);
        else if (which == 2) data = abi.encodeWithSignature("burnFrom(address,uint256)", actors[0], amount);
        else if (which == 3) data = abi.encodeWithSignature("pause()");
        else if (which == 4) data = abi.encodeWithSignature("transferOwnership(address)", from);
        else if (which == 5) data = abi.encodeWithSignature("setFee(uint256)", amount);
        else if (which == 6) data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", from, "");
        else data = abi.encodeWithSignature("rescue(address,uint256)", from, amount);
        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(data);
        assertFalse(ok);
        assertEq(ret.length, 0);
        ghostRejectedCalls++;
    }

    function sendToTokenItself(uint256 fromSeed, uint256 amountSeed) external {
        // Tokens sent to the token contract are lost (documented), but the ledger still balances.
        address from = _actor(fromSeed);
        if (from == address(contractHolder)) from = actors[4];
        uint256 amount = bound(amountSeed, 0, ghostBalance[from] / 1000);
        vm.prank(from);
        assertTrue(token.transfer(address(token), amount));
        ghostBalance[from] -= amount;
        ghostBalance[address(token)] += amount;
        ghostSent[from] += amount;
        ghostReceived[address(token)] += amount;
        ghostSuccessfulTransfers++;
    }
}

/// @notice Invariants of a fixed-supply ledger under random valid and invalid call sequences.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenAdversarialInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    LaunchToken private token;
    ContractHolder private holder;
    AdversarialTokenHandler private handler;

    function setUp() public {
        token = new LaunchToken();
        holder = new ContractHolder();
        handler = new AdversarialTokenHandler(token, holder);
        token.transfer(handler.actors(0), SUPPLY);

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = AdversarialTokenHandler.transfer.selector;
        selectors[1] = AdversarialTokenHandler.transferAll.selector;
        selectors[2] = AdversarialTokenHandler.approve.selector;
        selectors[3] = AdversarialTokenHandler.transferFrom.selector;
        selectors[4] = AdversarialTokenHandler.transferOverBalance.selector;
        selectors[5] = AdversarialTokenHandler.transferToZero.selector;
        selectors[6] = AdversarialTokenHandler.transferFromOverAllowance.selector;
        selectors[7] = AdversarialTokenHandler.transferFromOverBalanceWithinAllowance.selector;
        selectors[8] = AdversarialTokenHandler.approveZeroSpender.selector;
        selectors[9] = AdversarialTokenHandler.sendEther.selector;
        selectors[10] = AdversarialTokenHandler.attemptPrivilegedCall.selector;
        selectors[11] = AdversarialTokenHandler.sendToTokenItself.selector;
        selectors[12] = AdversarialTokenHandler.transfer.selector; // weight valid transfers higher
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Conservation: the token holds exactly what its holders are owed, no more, no less.
    function invariant_SupplyIsFixedAndFullyAccountedFor() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        uint256 sum;
        for (uint256 i; i < handler.ACTORS(); ++i) {
            address a = handler.actors(i);
            uint256 bal = token.balanceOf(a);
            assertEq(bal, handler.ghostBalance(a), "balance drifted from ledger");
            sum += bal;
        }
        uint256 locked = token.balanceOf(address(token));
        assertEq(locked, handler.ghostBalance(address(token)), "token self-balance drifted");
        assertEq(sum + locked, SUPPLY, "sum of balances is not the supply");
        assertEq(token.balanceOf(address(0)), 0, "zero address holds tokens");
        assertEq(token.balanceOf(address(this)), 0, "test contract holds tokens");
        assertEq(token.balanceOf(address(handler)), 0, "handler holds tokens");
    }

    /// @dev Nobody ever sends more than they received: outflow <= inflow for every account.
    function invariant_NoAccountSendsMoreThanItReceived() public view {
        for (uint256 i; i < handler.ACTORS(); ++i) {
            address a = handler.actors(i);
            assertLe(handler.ghostSent(a), handler.ghostReceived(a), "account overdrew");
            assertEq(handler.ghostReceived(a) - handler.ghostSent(a), token.balanceOf(a), "flow mismatch");
        }
    }

    /// @dev No single balance exceeds the supply, ever; the maximum observed is the supply itself.
    function invariant_NoBalanceEverExceedsSupply() public view {
        assertEq(handler.ghostMaxSingleBalance(), SUPPLY);
        for (uint256 i; i < handler.ACTORS(); ++i) {
            assertLe(token.balanceOf(handler.actors(i)), SUPPLY);
        }
    }

    /// @dev Allowances equal exactly what was approved minus what was spent through them; finite allowances
    /// only decrease by spending, unlimited ones never move, and failed spends leave them untouched.
    function invariant_AllowancesMatchLedger() public view {
        for (uint256 o; o < handler.ACTORS(); ++o) {
            for (uint256 s; s < handler.ACTORS(); ++s) {
                address owner = handler.actors(o);
                address spender = handler.actors(s);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drift");
            }
        }
    }

    /// @dev The token never custodies ether and its metadata is immutable.
    function invariant_NoEtherAndImmutableMetadata() public view {
        assertEq(address(token).balance, 0);
        assertEq(token.name(), "Daemon");
        assertEq(token.symbol(), "DAEMON");
        assertEq(token.decimals(), 18);
    }

    /// @dev Every recorded transfer emitted exactly one Transfer log: there is no hidden fee leg.
    function invariant_OneTransferLogPerRecordedTransfer() public view {
        assertEq(handler.ghostTransferEventsSeen(), handler.ghostRecordedTransferCalls());
        assertLe(handler.ghostRecordedTransferCalls(), handler.ghostSuccessfulTransfers());
    }

    /// @dev Reports how much of the run exercised failure paths. Not an assertion on the token; an
    /// assertion on the harness so an all-happy run cannot pass silently.
    function afterInvariant() public view {
        assertGt(handler.ghostRejectedCalls(), 0, "no failure path exercised");
        assertGt(handler.ghostSuccessfulTransfers(), 0, "no successful transfer exercised");
    }
}
