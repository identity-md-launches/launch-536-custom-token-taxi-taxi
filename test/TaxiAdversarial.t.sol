// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Taxi} from "../src/Taxi.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TestBase, Vm} from "./helpers/TestBase.sol";
import {LaunchFactoryMock} from "./helpers/LaunchFactoryMock.sol";

/// forge-config: default.fuzz.runs = 1000
contract TaxiAdversarialTest is TestBase {
    uint256 internal constant SUPPLY = 100_000_000 ether;
    uint64 internal constant LAUNCH = 42;
    address internal constant MANAGER = address(0x1001);
    address internal constant DISTRIBUTOR = address(0x1002);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5EED);
    address internal constant TREASURY = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;

    LaunchFactoryMock internal factory;
    Taxi internal token;

    function setUp() public {
        factory = new LaunchFactoryMock();
        token = factory.deploy(MANAGER, LAUNCH);
    }

    function test_delegatedSelfTransferConsumesGrossAllowanceAndCannotBeReplayed() public {
        _fund(ALICE, 200 ether);
        _approve(ALICE, SPENDER, 100 ether);
        _spend(ALICE, ALICE, SPENDER, 100 ether);
        assertEq(token.balanceOf(ALICE), 199 ether);
        assertEq(token.balanceOf(TREASURY), 1 ether);
        assertEq(token.allowance(ALICE, SPENDER), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, ALICE, 1);
        assertEq(token.balanceOf(ALICE), 199 ether);
        assertEq(token.balanceOf(TREASURY), 1 ether);
    }

    function test_treasuryDelegationConsumesGrossAllowanceDespiteSmallerDebit() public {
        _fund(TREASURY, 100 ether);
        _approve(TREASURY, SPENDER, 100 ether);
        _spend(TREASURY, BOB, SPENDER, 100 ether);
        assertEq(token.balanceOf(TREASURY), 1 ether);
        assertEq(token.balanceOf(BOB), 99 ether);
        assertEq(token.allowance(TREASURY, SPENDER), 0);
    }

    function test_transferFromByHolderStillRequiresExplicitAllowance() public {
        _fund(ALICE, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 100 ether));
        vm.prank(ALICE);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
        _approve(ALICE, ALICE, 100 ether);
        _spend(ALICE, BOB, ALICE, 100 ether);
        assertEq(token.allowance(ALICE, ALICE), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 99 ether);
        assertEq(token.balanceOf(TREASURY), 1 ether);
    }

    function test_infiniteApprovalCanBeRevokedAndReplacedWithFiniteBudget() public {
        _fund(ALICE, 300 ether);
        _approve(ALICE, SPENDER, type(uint256).max);
        _spend(ALICE, BOB, SPENDER, 100 ether);
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
        _approve(ALICE, SPENDER, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);

        _approve(ALICE, SPENDER, 150 ether);
        _spend(ALICE, BOB, SPENDER, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 50 ether, 51 ether)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 51 ether);
        assertEq(token.allowance(ALICE, SPENDER), 50 ether);
        _spend(ALICE, BOB, SPENDER, 50 ether);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 50 ether);
        assertEq(token.balanceOf(BOB), 247.5 ether);
        assertEq(token.balanceOf(TREASURY), 2.5 ether);
    }

    function test_zeroTransferFromEmptyHolderNeedsNoApprovalAndEmitsTransfer() public {
        vm.recordLogs();
        _spend(ALICE, BOB, SPENDER, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(ALICE))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(BOB))));
        assertEq(abi.decode(logs[0].data, (uint256)), 0);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroSenderCannotReachConstructorMintPathEvenWithZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(BOB, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(BOB, 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testFuzz_failedDelegatedAliasPreservesBalanceAndAllowance(uint256 raw, uint8 aliasKind, bool infinite)
        public
    {
        uint256 held = _boundSupply(raw);
        address from = aliasKind % 3 == 0 ? ALICE : TREASURY;
        address to = aliasKind % 3 == 1 ? BOB : from;
        uint256 amount = held + 1;
        uint256 approved = infinite ? type(uint256).max : amount;
        _fund(from, held);
        _approve(from, SPENDER, approved);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        vm.prank(SPENDER);
        token.transferFrom(from, to, amount);
        assertEq(token.allowance(from, SPENDER), approved);
        assertEq(token.balanceOf(from), held);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(from == ALICE ? TREASURY : ALICE), 0);
        assertEq(token.balanceOf(address(factory)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_exemptionIsEvaluatedAtSpendTime(uint256 raw, bool registerAfterApproval) public {
        uint256 amount = _boundSupply(raw);
        _fund(DISTRIBUTOR, amount);
        if (!registerAfterApproval) factory.setDistributor(LAUNCH, DISTRIBUTOR);
        _approve(DISTRIBUTOR, SPENDER, amount);
        factory.setDistributor(LAUNCH, registerAfterApproval ? DISTRIBUTOR : address(0));
        _spend(DISTRIBUTOR, BOB, SPENDER, amount);

        uint256 fee = registerAfterApproval ? 0 : amount / 100;
        assertEq(token.balanceOf(BOB), amount - fee);
        assertEq(token.balanceOf(TREASURY), fee);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.allowance(DISTRIBUTOR, SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_taxedRoundTripCannotCreateValueAndRoundingStaysBelowOneUnit(uint256 raw) public {
        _roundTrip(_boundSupply(raw));
    }

    function test_roundTripAtZeroOneFeeBoundariesAndFullSupply() public {
        // Each new fixture has the whole supply; no state reset or storage cheatcodes are needed.
        uint256[7] memory amounts = [uint256(0), 1, 99, 100, 101, 200, SUPPLY];
        for (uint256 i; i < amounts.length; ++i) {
            token = factory.deploy(MANAGER, LAUNCH);
            _roundTrip(amounts[i]);
        }
    }

    function test_launchNumberZeroAndMaxUseTheirOwnRegistryKey() public {
        uint64[2] memory numbers = [uint64(0), type(uint64).max];
        for (uint256 i; i < numbers.length; ++i) {
            uint64 number = numbers[i];
            token = factory.deploy(MANAGER, number);
            factory.setDistributor(number, address(0));
            factory.setDistributor(numbers[1 - i], ALICE);
            assertEq(token.launchNumber(), number);
            assertEq(token.rewardsDistributor(), address(0));
            factory.setDistributor(number, DISTRIBUTOR);
            assertEq(token.rewardsDistributor(), DISTRIBUTOR);
            _fund(DISTRIBUTOR, 100 ether);
            vm.prank(DISTRIBUTOR);
            assertTrue(token.transfer(BOB, 100 ether));
            assertEq(token.balanceOf(BOB), 100 ether);
            assertEq(token.balanceOf(DISTRIBUTOR), 0);
            assertEq(token.balanceOf(TREASURY), 0);
        }
    }

    function _roundTrip(uint256 amount) private {
        _fund(ALICE, amount);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, amount));
        uint256 received = token.balanceOf(BOB);
        uint256 firstFee = token.balanceOf(TREASURY);
        // Characterize floor rounding by inequalities, independently of Taxi's division expression.
        assertTrue(firstFee * 100 <= amount && amount < (firstFee + 1) * 100);
        assertEq(received + firstFee, amount);
        assertEq(token.balanceOf(ALICE), 0);
        vm.prank(BOB);
        assertTrue(token.transfer(ALICE, received));
        uint256 totalFees = token.balanceOf(TREASURY);
        uint256 secondFee = totalFees - firstFee;
        assertTrue(secondFee * 100 <= received && received < (secondFee + 1) * 100);
        assertTrue(token.balanceOf(ALICE) <= amount);
        assertEq(token.balanceOf(ALICE) + totalFees, amount);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _fund(address to, uint256 amount) private {
        vm.prank(address(factory));
        assertTrue(token.transfer(to, amount));
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
    }

    function _spend(address owner, address to, address spender, uint256 amount) private {
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
    }

    function _boundSupply(uint256 value) private pure returns (uint256) {
        return value <= SUPPLY ? value : value % (SUPPLY + 1);
    }
}
