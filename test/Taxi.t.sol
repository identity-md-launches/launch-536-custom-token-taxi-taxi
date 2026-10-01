// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Taxi} from "../src/Taxi.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TestBase, Vm} from "./helpers/TestBase.sol";
import {LaunchFactoryMock} from "./helpers/LaunchFactoryMock.sol";

contract TaxiTest is TestBase {
    uint256 internal constant SUPPLY = 100_000_000 ether;
    uint64 internal constant LAUNCH = 42;
    address internal constant MANAGER = address(0x1001);
    address internal constant DISTRIBUTOR = address(0x1002);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5EED);
    address internal constant TREASURY = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    LaunchFactoryMock internal factory;
    Taxi internal token;

    function setUp() public {
        factory = new LaunchFactoryMock();
        token = factory.deploy(MANAGER, LAUNCH);
    }

    function test_metadataAndConstructorMint() public view {
        assertEq(token.name(), "Taxi");
        assertEq(token.symbol(), "TAXI");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.factory(), address(factory));
        assertEq(token.poolManager(), MANAGER);
        assertEq(token.launchNumber(), LAUNCH);
        assertEq(token.TREASURY(), TREASURY);
        assertEq(token.FEE_BPS(), 100);
        assertEq(token.rewardsDistributor(), address(0));
    }

    function test_directDeploymentMintsToActualDeployer() public {
        vm.recordLogs();
        Taxi direct = new Taxi(address(factory), MANAGER, LAUNCH);
        assertEq(direct.balanceOf(address(this)), SUPPLY);
        assertEq(direct.balanceOf(address(factory)), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        _assertTransfer(logs[0], address(direct), address(0), address(this), SUPPLY);
    }

    function test_rejectsZeroFactory() public {
        vm.expectRevert(Taxi.InvalidFactory.selector);
        new Taxi(address(0), MANAGER, LAUNCH);
    }

    function test_rejectsZeroManager() public {
        vm.expectRevert(Taxi.InvalidPoolManager.selector);
        new Taxi(address(factory), address(0), LAUNCH);
    }

    function test_taxedTransferAndEvents() public {
        _fund(ALICE, 1000 ether);
        vm.recordLogs();
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100 ether));
        assertEq(token.balanceOf(ALICE), 900 ether);
        assertEq(token.balanceOf(BOB), 99 ether);
        assertEq(token.balanceOf(TREASURY), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        _assertTransfer(logs[0], address(token), ALICE, TREASURY, 1 ether);
        _assertTransfer(logs[1], address(token), ALICE, BOB, 99 ether);
    }

    function test_roundingBoundariesAndZeroTransfer() public {
        _fund(ALICE, 1000);
        _move(ALICE, BOB, 0);
        _move(ALICE, BOB, 1);
        _move(ALICE, BOB, 99);
        assertEq(token.balanceOf(TREASURY), 0);
        _move(ALICE, BOB, 100);
        assertEq(token.balanceOf(TREASURY), 1);
        _move(ALICE, BOB, 199);
        assertEq(token.balanceOf(TREASURY), 2);
        _move(ALICE, BOB, 200);
        assertEq(token.balanceOf(TREASURY), 4);
        assertEq(token.balanceOf(ALICE), 401);
        assertEq(token.balanceOf(BOB), 595);
    }

    function test_zeroTransferFromEmptyAccountEmitsEvent() public {
        vm.recordLogs();
        _move(ALICE, BOB, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        _assertTransfer(logs[0], address(token), ALICE, BOB, 0);
    }

    function test_entireBalanceCanBeTransferred() public {
        _fund(ALICE, SUPPLY);
        _move(ALICE, BOB, SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 99_000_000 ether);
        assertEq(token.balanceOf(TREASURY), 1_000_000 ether);
    }

    function test_selfTransferPaysOnlyFee() public {
        _fund(ALICE, 100 ether);
        _move(ALICE, ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 99 ether);
        assertEq(token.balanceOf(TREASURY), 1 ether);
    }

    function test_treasuryIncomingOutgoingAndSelfTransfers() public {
        _fund(ALICE, 100 ether);
        _move(ALICE, TREASURY, 100 ether);
        assertEq(token.balanceOf(TREASURY), 100 ether);
        _move(TREASURY, BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 99 ether);
        assertEq(token.balanceOf(TREASURY), 1 ether);
        _move(TREASURY, TREASURY, 1 ether);
        assertEq(token.balanceOf(TREASURY), 1 ether);
    }

    function test_allExemptEndpointsInBothDirections() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        address[3] memory exempt = [address(factory), MANAGER, DISTRIBUTOR];
        for (uint256 i; i < exempt.length; ++i) {
            address account = exempt[i];
            _fund(ALICE, 200 ether);
            uint256 before = token.balanceOf(account);
            _move(ALICE, account, 100 ether);
            assertEq(token.balanceOf(account), before + 100 ether);
            uint256 recipientBefore = token.balanceOf(BOB);
            _move(account, BOB, 100 ether);
            assertEq(token.balanceOf(BOB), recipientBefore + 100 ether);
        }
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function test_transferFromAllExemptEndpointsInBothDirections() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        address[3] memory exempt = [address(factory), MANAGER, DISTRIBUTOR];
        for (uint256 i; i < exempt.length; ++i) {
            address account = exempt[i];
            _fund(ALICE, 100 ether);
            uint256 before = token.balanceOf(account);
            _approveAndMove(ALICE, account, SPENDER, 100 ether);
            assertEq(token.balanceOf(account), before + 100 ether);
            uint256 recipientBefore = token.balanceOf(BOB);
            _approveAndMove(account, BOB, SPENDER, 100 ether);
            assertEq(token.balanceOf(BOB), recipientBefore + 100 ether);
        }
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function test_launchAllocationClaimsAndPoolRoundTripAreExact() public {
        // Register after constructor, as the real launch factory does.
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        _fund(DISTRIBUTOR, 10_000_000 ether);
        _fund(MANAGER, 60_000_000 ether);
        _fund(ALICE, 30_000_000 ether);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(DISTRIBUTOR), 10_000_000 ether);
        assertEq(token.balanceOf(MANAGER), 60_000_000 ether);
        assertEq(token.balanceOf(ALICE), 30_000_000 ether);
        _move(DISTRIBUTOR, BOB, 10_000_000 ether);
        _move(MANAGER, ALICE, 250 ether);
        _move(ALICE, MANAGER, 250 ether);
        assertEq(token.balanceOf(BOB), 10_000_000 ether);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.balanceOf(MANAGER), 60_000_000 ether);
        assertEq(token.balanceOf(ALICE), 30_000_000 ether);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_distributorResolvedDynamicallyAndOnlyForThisLaunch() public {
        _fund(DISTRIBUTOR, 300 ether);
        factory.setDistributor(LAUNCH + 1, DISTRIBUTOR);
        _move(DISTRIBUTOR, ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 99 ether);
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        assertEq(token.rewardsDistributor(), DISTRIBUTOR);
        _move(DISTRIBUTOR, ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 199 ether);
        factory.setDistributor(LAUNCH, BOB);
        assertEq(token.rewardsDistributor(), BOB);
        _move(DISTRIBUTOR, ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 298 ether);
        assertEq(token.balanceOf(TREASURY), 2 ether);
        _move(ALICE, BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 100 ether);
    }

    function test_exemptSpenderDoesNotExemptOrdinaryEndpoints() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        address[3] memory spenders = [address(factory), MANAGER, DISTRIBUTOR];
        _fund(ALICE, 300 ether);
        for (uint256 i; i < spenders.length; ++i) {
            _approveAndMove(ALICE, BOB, spenders[i], 100 ether);
        }
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 297 ether);
        assertEq(token.balanceOf(TREASURY), 3 ether);
    }

    function test_transferFromConsumesGrossAllowance() public {
        _fund(ALICE, 100 ether);
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 110 ether));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 100 ether));
        assertEq(token.allowance(ALICE, SPENDER), 10 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 99 ether);
        assertEq(token.balanceOf(TREASURY), 1 ether);
    }

    function test_infiniteAllowanceIsPreserved() public {
        _fund(ALICE, 100 ether);
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, type(uint256).max));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 100 ether));
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
    }

    function test_approvalEventReplacementAndRevocation() public {
        vm.recordLogs();
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 123));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], keccak256("Approval(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(ALICE))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(SPENDER))));
        assertEq(abi.decode(logs[0].data, (uint256)), 123);
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 456));
        assertEq(token.allowance(ALICE, SPENDER), 456);
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 0));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_insufficientBalanceRevertsBeforeFee() public {
        _fund(ALICE, 100 ether);
        _expectBalanceFailure(ALICE, BOB, 100 ether, 101 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function test_selfAndTreasuryTransfersRequireGrossBalance() public {
        _fund(ALICE, 100 ether);
        _fund(TREASURY, 99 ether);
        _expectBalanceFailure(ALICE, ALICE, 100 ether, 101 ether);
        _expectBalanceFailure(TREASURY, BOB, 99 ether, 100 ether);
        _expectBalanceFailure(TREASURY, TREASURY, 99 ether, 100 ether);
    }

    function test_maxUintTransferRevertsWithoutOverflow() public {
        _fund(ALICE, 100 ether);
        _expectBalanceFailure(ALICE, BOB, 100 ether, type(uint256).max);
    }

    function test_insufficientAllowanceCannotPayOnlyNetAmount() public {
        _fund(ALICE, 100 ether);
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 99 ether));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 99 ether, 100 ether)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.allowance(ALICE, SPENDER), 99 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function test_failedTransferFromRollsBackAllowance() public {
        _fund(ALICE, 50 ether);
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 100 ether));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 50 ether, 100 ether)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.allowance(ALICE, SPENDER), 100 ether);
        assertEq(token.balanceOf(ALICE), 50 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function test_zeroAddressTransfersAndApprovalsRevert() public {
        _fund(ALICE, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), BOB, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(ALICE);
        token.approve(address(0), 1);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function test_zeroRecipientTransferFromRollsBackAllowance() public {
        _fund(ALICE, 100 ether);
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 100 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 100 ether);
        assertEq(token.allowance(ALICE, SPENDER), 100 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function test_factoryCannotSpendHolderWithoutApproval() public {
        _fund(ALICE, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        vm.prank(address(factory));
        token.transferFrom(ALICE, address(factory), 1);
        assertEq(token.balanceOf(ALICE), 100 ether);
        _move(ALICE, BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 99 ether);
    }

    function test_noAdminMintBurnOrConfigurationEntrypoints() public {
        _fund(ALICE, 100 ether);
        bytes[] memory calls = new bytes[](18);
        calls[0] = abi.encodeWithSignature("owner()");
        calls[1] = abi.encodeWithSignature("mint(address,uint256)", BOB, SUPPLY);
        calls[2] = abi.encodeWithSignature("mint(uint256)", SUPPLY);
        calls[3] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[4] = abi.encodeWithSignature("burnFrom(address,uint256)", ALICE, 1);
        calls[5] = abi.encodeWithSignature("pause()");
        calls[6] = abi.encodeWithSignature("blacklist(address)", ALICE);
        calls[7] = abi.encodeWithSignature("freeze(address)", ALICE);
        calls[8] = abi.encodeWithSignature("seize(address)", ALICE);
        calls[9] = abi.encodeWithSignature("setFee(uint256)", 200);
        calls[10] = abi.encodeWithSignature("setFeeBps(uint256)", 200);
        calls[11] = abi.encodeWithSignature("setTreasury(address)", BOB);
        calls[12] = abi.encodeWithSignature("setExempt(address,bool)", ALICE, true);
        calls[13] = abi.encodeWithSignature("setFactory(address)", BOB);
        calls[14] = abi.encodeWithSignature("setPoolManager(address)", BOB);
        calls[15] = abi.encodeWithSignature("transferOwnership(address)", BOB);
        calls[16] = abi.encodeWithSignature("upgradeTo(address)", BOB);
        calls[17] = abi.encodeWithSignature("initialize(address)", BOB);
        address[2] memory callers = [address(factory), BOB];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < calls.length; ++i) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(calls[i]);
                assertTrue(!ok);
                assertEq(token.totalSupply(), SUPPLY);
                assertEq(token.balanceOf(ALICE), 100 ether);
            }
        }
        _move(ALICE, BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 99 ether);
        assertEq(token.balanceOf(TREASURY), 1 ether);
    }

    function test_runtimeHasNoDangerousOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertTrue(runtime.length > 0 && runtime.length <= 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
            }
        }
    }

    function testFuzz_taxAndAllowanceConserveSupply(uint256 rawAmount, uint256 rawExtra) public {
        uint256 amount = rawAmount % (SUPPLY + 1);
        uint256 extra = rawExtra % (SUPPLY + 1);
        _fund(ALICE, amount);
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, amount + extra));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, amount));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), amount - amount / 100);
        assertEq(token.balanceOf(TREASURY), amount / 100);
        assertEq(token.allowance(ALICE, SPENDER), extra);
        assertEq(token.balanceOf(address(factory)) + token.balanceOf(BOB) + token.balanceOf(TREASURY), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_exemptAmountsArriveWhole(uint256 rawAmount, uint8 which, bool inbound) public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        address[3] memory exempt = [address(factory), MANAGER, DISTRIBUTOR];
        address endpoint = exempt[which % 3];
        uint256 amount = rawAmount % (SUPPLY + 1);
        if (inbound) {
            _fund(ALICE, amount);
            uint256 before = token.balanceOf(endpoint);
            _approveAndMove(ALICE, endpoint, SPENDER, amount);
            assertEq(token.balanceOf(endpoint), before + amount);
            assertEq(token.balanceOf(ALICE), 0);
        } else {
            _fund(endpoint, amount);
            uint256 before = token.balanceOf(endpoint);
            _approveAndMove(endpoint, ALICE, SPENDER, amount);
            assertEq(token.balanceOf(endpoint), before - amount);
            assertEq(token.balanceOf(ALICE), amount);
        }
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _fund(address to, uint256 amount) internal {
        _move(address(factory), to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
    }

    function _approveAndMove(address from, address to, address spender, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.approve(spender, amount));
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        assertEq(token.allowance(from, spender), 0);
    }

    function _expectBalanceFailure(address from, address to, uint256 balance, uint256 amount) internal {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function _assertTransfer(Vm.Log memory entry, address emitter, address from, address to, uint256 amount)
        internal
        pure
    {
        assertEq(entry.emitter, emitter);
        assertEq(entry.topics.length, 3);
        assertEq(entry.topics[0], TRANSFER);
        assertEq(entry.topics[1], bytes32(uint256(uint160(from))));
        assertEq(entry.topics[2], bytes32(uint256(uint160(to))));
        assertEq(abi.decode(entry.data, (uint256)), amount);
    }
}
