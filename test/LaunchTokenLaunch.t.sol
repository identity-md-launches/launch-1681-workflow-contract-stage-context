// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @dev Minimal view of the token, declared locally the way the protocol's floor declares it, so these
/// tests reach the deployed bytecode through an interface the project did not supply.
interface IFloorToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Local stand-in for the one transaction in which ProjectFactory.launch deploys the token and then
/// splits its supply. It is not the protocol factory; it reproduces only the checks the launch depends on:
/// the token mints the whole policy supply to its immediate deployer, and nothing else holds any of it.
contract LaunchRehearsalFactory {
    error SupplyMismatch(uint256 expected, uint256 actual);

    uint256 public constant POLICY_SUPPLY = 1_000_000_000 ether;

    address public token;
    address public pool;
    address public distributor;
    address public payer;

    constructor(address pool_, address distributor_, address payer_) {
        pool = pool_;
        distributor = distributor_;
        payer = payer_;
    }

    /// @notice Deploys the token from raw creation code and splits the supply in the same call.
    /// @param creationCode The token's init code, as the attested artifact is handed over.
    /// @param salt CREATE2 salt, as the factory uses.
    /// @param poolShare Minor units seeded into the pool; the rest of the requester's 90% goes to the payer.
    function launch(bytes memory creationCode, bytes32 salt, uint256 poolShare) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        require(deployed != address(0), "token constructor failed");
        IFloorToken t = IFloorToken(deployed);
        uint256 supply = t.totalSupply();
        if (supply != POLICY_SUPPLY) revert SupplyMismatch(POLICY_SUPPLY, supply);
        uint256 held = t.balanceOf(address(this));
        if (held != POLICY_SUPPLY) revert SupplyMismatch(POLICY_SUPPLY, held);
        token = deployed;

        uint256 swarm = POLICY_SUPPLY / 10; // 10%: 2% accepted work + 8% paired seats, via MerkleDistributor
        require(poolShare <= POLICY_SUPPLY - swarm, "pool share exceeds requester share");
        uint256 remainder = POLICY_SUPPLY - swarm - poolShare;
        require(t.transfer(distributor, swarm), "swarm transfer failed");
        require(t.transfer(pool, poolShare), "pool transfer failed");
        if (remainder > 0) require(t.transfer(payer, remainder), "payer transfer failed");
    }

    /// @notice Deploys with a nonzero endowment, which a nonpayable constructor must refuse.
    function tryDeployWithValue(bytes memory creationCode) external payable returns (address deployed) {
        uint256 v = msg.value;
        assembly ("memory-safe") {
            deployed := create(v, add(creationCode, 0x20), mload(creationCode))
        }
    }
}

/// @notice Rehearses the launch and the protocol's floor against the real creation code, offline.
/// @dev The protocol floor (Token.protected.t.sol / Project.protected.t.sol) runs with the token's attested
/// creation code supplied by the verifier. It cannot run here, so these tests replay its assertions on the
/// compiled artifact and additionally drive the launch split the factory performs.
contract LaunchTokenLaunchTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    address private pool;
    address private distributor;
    address private payer;

    function setUp() public {
        pool = makeAddr("pool");
        distributor = makeAddr("merkle distributor");
        payer = makeAddr("launch payer");
    }

    // ---------------------------------------------------------------------------------------------
    // Launch in one transaction
    // ---------------------------------------------------------------------------------------------

    function test_OneCallLaunchSplitsSupplyExactlyAtStandardTerms() public {
        LaunchRehearsalFactory factory = new LaunchRehearsalFactory(pool, distributor, payer);
        // Standard terms for this launch: 88% pool, 10% swarm, 2% creator.
        address deployed = factory.launch(type(LaunchToken).creationCode, bytes32(uint256(1)), 880_000_000 ether);
        LaunchToken token = LaunchToken(deployed);

        assertEq(factory.token(), deployed);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(pool), 880_000_000 ether);
        assertEq(token.balanceOf(distributor), 100_000_000 ether);
        assertEq(token.balanceOf(payer), 20_000_000 ether);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(tx.origin), 0);
        assertEq(token.balanceOf(pool) + token.balanceOf(distributor) + token.balanceOf(payer), token.totalSupply());
    }

    function test_OneCallLaunchWithDefaultEightyPercentPool() public {
        LaunchRehearsalFactory factory = new LaunchRehearsalFactory(pool, distributor, payer);
        address deployed = factory.launch(type(LaunchToken).creationCode, bytes32(uint256(2)), 800_000_000 ether);
        LaunchToken token = LaunchToken(deployed);
        assertEq(token.balanceOf(pool), 800_000_000 ether);
        assertEq(token.balanceOf(distributor), 100_000_000 ether);
        assertEq(token.balanceOf(payer), 100_000_000 ether);
        assertEq(token.balanceOf(address(factory)), 0);
    }

    function test_OneCallLaunchWithWholeRequesterShareInPool() public {
        LaunchRehearsalFactory factory = new LaunchRehearsalFactory(pool, distributor, payer);
        address deployed = factory.launch(type(LaunchToken).creationCode, bytes32(uint256(3)), 900_000_000 ether);
        LaunchToken token = LaunchToken(deployed);
        assertEq(token.balanceOf(pool), 900_000_000 ether);
        assertEq(token.balanceOf(distributor), 100_000_000 ether);
        assertEq(token.balanceOf(payer), 0);
    }

    function testFuzz_OneCallLaunchConservesSupplyForAnyPoolShare(uint256 poolShare, bytes32 salt) public {
        poolShare = bound(poolShare, 0, 900_000_000 ether);
        LaunchRehearsalFactory factory = new LaunchRehearsalFactory(pool, distributor, payer);
        address deployed = factory.launch(type(LaunchToken).creationCode, salt, poolShare);
        LaunchToken token = LaunchToken(deployed);
        assertEq(token.balanceOf(pool), poolShare);
        assertEq(token.balanceOf(distributor), 100_000_000 ether);
        assertEq(token.balanceOf(payer), 900_000_000 ether - poolShare);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_LaunchOnMainnetChainIdInEmptyChain() public {
        // The launch checks run constructors on an empty chain with the launch's chain id.
        vm.chainId(1);
        LaunchRehearsalFactory factory = new LaunchRehearsalFactory(pool, distributor, payer);
        address deployed = factory.launch(type(LaunchToken).creationCode, bytes32(uint256(7)), 880_000_000 ether);
        assertEq(LaunchToken(deployed).totalSupply(), SUPPLY);
        assertEq(block.chainid, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Floor rehearsal: what Token.protected.t.sol asserts, on the compiled artifact
    // ---------------------------------------------------------------------------------------------

    function _deployRaw(bytes memory creationCode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
    }

    function test_Floor_RawCreateMintsWholeSupplyToDeployer() public {
        vm.chainId(1);
        address deployed = _deployRaw(type(LaunchToken).creationCode);
        assertTrue(deployed != address(0), "token deployment reverted");
        IFloorToken t = IFloorToken(deployed);
        assertGt(t.totalSupply(), 0);
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.balanceOf(address(this)), t.totalSupply());
        assertEq(uint256(t.decimals()), 18);
    }

    function test_Floor_NoCommonAdminCallIncreasesSupply() public {
        address deployed = _deployRaw(type(LaunchToken).creationCode);
        IFloorToken t = IFloorToken(deployed);
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = deployed.call(data);
            assertFalse(ok, signatures[i]);
            assertEq(t.totalSupply(), SUPPLY, signatures[i]);
            assertEq(t.balanceOf(attacker), 0, signatures[i]);
        }
        // Not even the deployer.
        (bool deployerOk,) = deployed.call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(deployerOk);
        assertEq(t.totalSupply(), SUPPLY);
    }

    function test_Floor_TransferMovesExactlyWhatItWasAsked() public {
        address deployed = _deployRaw(type(LaunchToken).creationCode);
        IFloorToken t = IFloorToken(deployed);
        address recipient = address(0xCAFE);
        uint256 amount = SUPPLY / 1_000;
        uint256 before = t.balanceOf(address(this));
        assertTrue(t.transfer(recipient, amount));
        assertEq(t.balanceOf(recipient), amount);
        assertEq(t.balanceOf(address(this)), before - amount);
        assertEq(t.totalSupply(), SUPPLY);
    }

    function test_Floor_RuntimeAndCreationCodeHaveNoEscapeOpcodes() public {
        address deployed = _deployRaw(type(LaunchToken).creationCode);
        _assertNoEscapeOpcodes(deployed.code);
        // The constructor is also scanned: a SELFDESTRUCT or DELEGATECALL during construction is as
        // disqualifying as one at runtime.
        _assertNoEscapeOpcodes(type(LaunchToken).creationCode);
        assertLe(deployed.code.length, 24_576);
    }

    function _assertNoEscapeOpcodes(bytes memory code) private pure {
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
            assertTrue(op != 0xF0 && op != 0xF5, "CREATE/CREATE2 in token");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment edge cases and failure paths
    // ---------------------------------------------------------------------------------------------

    function test_ConstructorRefusesEther() public {
        LaunchRehearsalFactory factory = new LaunchRehearsalFactory(pool, distributor, payer);
        vm.deal(address(this), 1 ether);
        address deployed = factory.tryDeployWithValue{value: 1 wei}(type(LaunchToken).creationCode);
        assertEq(deployed, address(0), "nonpayable constructor accepted ether");
        assertEq(address(factory).balance, 1 wei, "ether left the factory");
    }

    function test_CreationCodeHasNoConstructorArguments() public {
        // Trailing bytes would be read as constructor arguments by a token that takes any. One that takes
        // none ignores them, and the manifest's empty constructorArgs is therefore correct.
        bytes memory code = type(LaunchToken).creationCode;
        bytes memory withJunk = abi.encodePacked(code, uint256(123_456), address(0xDEAD));
        address deployed = _deployRaw(withJunk);
        assertTrue(deployed != address(0));
        assertEq(LaunchToken(deployed).totalSupply(), SUPPLY);
        assertEq(LaunchToken(deployed).balanceOf(address(this)), SUPPLY);
        assertEq(LaunchToken(deployed).balanceOf(address(0xDEAD)), 0);
    }

    function test_Create2AddressIsPredictableFromCreationCodeAlone() public {
        // The protocol predicts the token address before deployment (IMD_EXPECTED_TOKEN). That only works
        // when the init code hash depends on nothing but the artifact, which bytecode_hash = "none" and a
        // no-argument constructor guarantee.
        LaunchRehearsalFactory factory = new LaunchRehearsalFactory(pool, distributor, payer);
        bytes32 salt = keccak256("daemon");
        address predicted = vm.computeCreate2Address(salt, keccak256(type(LaunchToken).creationCode), address(factory));
        address deployed = factory.launch(type(LaunchToken).creationCode, salt, 880_000_000 ether);
        assertEq(deployed, predicted);
    }

    function test_SameSaltTwiceFromSameFactoryFails() public {
        LaunchRehearsalFactory factory = new LaunchRehearsalFactory(pool, distributor, payer);
        bytes32 salt = bytes32(uint256(42));
        factory.launch(type(LaunchToken).creationCode, salt, 880_000_000 ether);
        vm.expectRevert(bytes("token constructor failed"));
        factory.launch(type(LaunchToken).creationCode, salt, 880_000_000 ether);
    }

    function test_TwoDeploymentsAreIndependentLedgers() public {
        LaunchToken a = new LaunchToken();
        vm.prank(payer);
        LaunchToken b = new LaunchToken();

        assertTrue(address(a) != address(b));
        assertEq(a.balanceOf(address(this)), SUPPLY);
        assertEq(a.balanceOf(payer), 0);
        assertEq(b.balanceOf(payer), SUPPLY);
        assertEq(b.balanceOf(address(this)), 0);

        a.transfer(pool, 1 ether);
        assertEq(b.balanceOf(pool), 0);
        assertEq(b.totalSupply(), SUPPLY);
    }

    function testFuzz_MintsToWhoeverDeploysNotToOrigin(address deployer) public {
        assumeNotForgeAddress(deployer);
        assumeNotPrecompile(deployer);
        vm.assume(deployer.code.length == 0 && deployer != address(0));
        vm.assume(deployer != tx.origin && deployer != address(this));
        vm.prank(deployer);
        LaunchToken token = new LaunchToken();
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(tx.origin), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_FactoryStandInRefusesTokenWithWrongSupply() public {
        // Exercises the rehearsal factory's own failure path so a wrong token could not pass it silently.
        LaunchRehearsalFactory factory = new LaunchRehearsalFactory(pool, distributor, payer);
        vm.expectRevert(abi.encodeWithSelector(LaunchRehearsalFactory.SupplyMismatch.selector, SUPPLY, 1_000_000 ether));
        factory.launch(type(ShortSupplyToken).creationCode, bytes32(uint256(9)), 880_000_000 ether);
    }

    function test_FactoryStandInRefusesTokenThatMintsElsewhere() public {
        LaunchRehearsalFactory factory = new LaunchRehearsalFactory(pool, distributor, payer);
        vm.expectRevert(abi.encodeWithSelector(LaunchRehearsalFactory.SupplyMismatch.selector, SUPPLY, SUPPLY - 1));
        factory.launch(type(LeakingSupplyToken).creationCode, bytes32(uint256(10)), 880_000_000 ether);
    }

    function test_TransferToZeroFromFactoryIsRefused() public {
        LaunchToken token = new LaunchToken();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}

/// @dev Negative controls for the rehearsal factory. Not launch tokens; they exist so the factory stand-in is
/// shown to reject what the protocol's SupplyMismatch rejects.
contract ShortSupplyToken is LaunchToken {
    constructor() {
        // LaunchToken minted the policy supply to msg.sender; burn down to a million.
        _burn(msg.sender, 1_000_000_000 ether - 1_000_000 ether);
    }
}

contract LeakingSupplyToken is LaunchToken {
    constructor() {
        _transfer(msg.sender, address(0xdead), 1);
    }
}
