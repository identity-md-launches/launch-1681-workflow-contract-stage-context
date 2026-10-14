// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @dev Local deployment probe only; this is not the protocol's ProjectFactory.
contract TokenDeploymentProbe {
    function deploy(bytes32 salt) external returns (LaunchToken) {
        return new LaunchToken{salt: salt}();
    }
}

/// @dev A transfer must succeed without calling even a reverting recipient.
contract RejectingRecipient {
    fallback() external {
        revert("recipient must not be called");
    }
}

contract LaunchTokenTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    LaunchToken private token;
    address private alice;
    address private bob;
    address private spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new LaunchToken();
    }

    function test_MetadataAndEntireSupplyBelongToDeployer() public view {
        assertEq(token.name(), "Daemon");
        assertEq(token.symbol(), "DAEMON");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_ConstructorEmitsMintEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), SUPPLY);
        new LaunchToken();
    }

    function test_Create2MintsToFactoryWithoutExternalConfiguration() public {
        TokenDeploymentProbe factory = new TokenDeploymentProbe();
        vm.prank(alice);
        LaunchToken deployed = factory.deploy(keccak256("local deployment probe"));
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(alice), 0);
        assertEq(deployed.balanceOf(address(this)), 0);
        assertEq(deployed.balanceOf(tx.origin), 0);
    }

    function test_FactoryCanTransferExactLaunchAllocations() public {
        // These are local recipients, not production deployment parameters.
        address pool = makeAddr("pool");
        address distributor = makeAddr("distributor");
        address creator = makeAddr("creator");
        assertTrue(token.transfer(pool, 880_000_000 ether));
        assertTrue(token.transfer(distributor, 100_000_000 ether));
        assertTrue(token.transfer(creator, 20_000_000 ether));
        assertEq(token.balanceOf(pool), 880_000_000 ether);
        assertEq(token.balanceOf(distributor), 100_000_000 ether);
        assertEq(token.balanceOf(creator), 20_000_000 ether);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferEmitsEventAndChargesNoFee() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 10 ether);
        assertTrue(token.transfer(alice, 10 ether));
        assertEq(token.balanceOf(address(this)), SUPPLY - 10 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferToContractDoesNotInvokeRecipient() public {
        RejectingRecipient recipient = new RejectingRecipient();
        assertTrue(token.transfer(address(recipient), 1 ether));
        assertEq(token.balanceOf(address(recipient)), 1 ether);
    }

    function test_TransferToZeroRevertsWithoutBurning() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroTransferToZeroAlsoReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_TransferMoreThanBalanceRevertsAtomically() public {
        token.transfer(alice, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 100, 101));
        vm.prank(alice);
        token.transfer(bob, 101);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ApproveEmitsEventWithoutMovingTokens() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 123);
        assertTrue(token.approve(spender, 123));
        assertEq(token.allowance(address(this), spender), 123);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_ApproveReplacesAndRevokesAllowance() public {
        token.approve(spender, 100);
        token.approve(spender, 30);
        assertEq(token.allowance(address(this), spender), 30);
        token.approve(spender, 0);
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
    }

    function test_ApproveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_ApprovalIsSpecificToOwnerAndSpender() public {
        token.transfer(alice, 100);
        token.approve(spender, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), spender), 100);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferFromSpendsAllowanceAndEmitsTransfer() public {
        token.approve(spender, 100);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 70);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 70));
        assertEq(token.allowance(address(this), spender), 30);
        assertEq(token.balanceOf(alice), 70);
        assertEq(token.balanceOf(address(this)), SUPPLY - 70);
    }

    function test_TransferFromCannotOverspendOrReuseExhaustedAllowance() public {
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 10, 11));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 11);
        assertEq(token.allowance(address(this), spender), 10);
        assertEq(token.balanceOf(alice), 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 10));
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(alice), 10);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10);
    }

    function test_TransferFromInsufficientBalanceRestoresAllowance() public {
        token.transfer(alice, 5);
        vm.prank(alice);
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5, 6));
        vm.prank(spender);
        token.transferFrom(alice, bob, 6);
        assertEq(token.allowance(alice, spender), 10);
        assertEq(token.balanceOf(alice), 5);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferFromToZeroRestoresAllowance() public {
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 10);
        assertEq(token.allowance(address(this), spender), 10);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferFromZeroSenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
    }

    function test_ZeroTransferFromRequiresNoAllowance() public {
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_InfiniteAllowanceIsNotDecremented() public {
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, 100));
        assertTrue(token.transferFrom(address(this), bob, 200));
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 200);
        assertEq(token.balanceOf(address(this)), SUPPLY - 300);
    }

    function test_TransferFromToSelfSpendsAllowanceWithoutChangingBalance() public {
        token.approve(spender, 10);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), 10));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_RejectsEtherAndUnknownCalls() public {
        vm.deal(address(this), 1 ether);
        (bool accepted,) = address(token).call{value: 1 wei}("");
        assertFalse(accepted);
        assertEq(address(token).balance, 0);
        (bool callable,) = address(token).call(hex"12345678");
        assertFalse(callable);
    }

    function test_NoMintBurnAdminOrUpgradeSelectorsForDeployerOrHolder() public {
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", alice, 1);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1);
        calls[2] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[3] = abi.encodeWithSignature("burnFrom(address,uint256)", address(this), 1);
        calls[4] = abi.encodeWithSignature("owner()");
        calls[5] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[6] = abi.encodeWithSignature("pause()");
        calls[7] = abi.encodeWithSignature("unpause()");
        calls[8] = abi.encodeWithSignature("upgradeTo(address)", alice);
        calls[9] = abi.encodeWithSignature("initialize(address)", alice);
        calls[10] = abi.encodeWithSignature("setMinter(address)", alice);
        calls[11] = abi.encodeWithSignature("setFee(uint256)", 1);
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSuccess,) = address(token).call(calls[i]);
            assertFalse(deployerSuccess);
            vm.prank(alice);
            (bool holderSuccess,) = address(token).call(calls[i]);
            assertFalse(holderSuccess);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_RuntimeWithinLimitAndWithoutEscapeOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
        }
    }

    function testFuzz_TransferConservesSupply(uint256 amount, address recipient) public {
        vm.assume(recipient != address(0) && recipient != address(this));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_SelfTransferPreservesBalance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransferFromAccounting(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY);
        amount = bound(amount, 0, approved);
        token.approve(spender, approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.allowance(address(this), spender), approved - amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_CannotTransferAboveBalance(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        token.transfer(alice, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_CannotTransferAboveAllowance(uint256 approved, uint256 excess) public {
        approved = bound(approved, 0, SUPPLY - 1);
        uint256 attempted = approved + bound(excess, 1, SUPPLY - approved);
        token.approve(spender, approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, attempted)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, attempted);
        assertEq(token.allowance(address(this), spender), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}
