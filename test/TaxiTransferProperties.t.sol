// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Taxi} from "../src/Taxi.sol";
import {TestBase, Vm} from "./helpers/TestBase.sol";
import {LaunchFactoryMock} from "./helpers/LaunchFactoryMock.sol";

/// @dev Properties of a single transfer between any pair of endpoints, with the Transfer events
/// as the oracle for balances and the specification's floor-rounding inequality as the oracle
/// for the fee. Nothing here reads the fee constant or the registry back from the token.
/// forge-config: default.fuzz.runs = 1000
contract TaxiTransferPropertiesTest is TestBase {
    uint256 internal constant SUPPLY = 100_000_000 ether;
    uint64 internal constant LAUNCH = 42;
    address internal constant MANAGER = address(0x1001);
    address internal constant DISTRIBUTOR = address(0x1002);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant SPENDER = address(0x5EED);
    address internal constant TREASURY = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    LaunchFactoryMock internal factory;
    Taxi internal token;
    address[7] internal actors;

    function setUp() public {
        factory = new LaunchFactoryMock();
        token = factory.deploy(MANAGER, LAUNCH);
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        actors = [address(factory), MANAGER, DISTRIBUTOR, ALICE, BOB, TREASURY, CAROL];
    }

    /// @dev Every unit that leaves the sender is accounted for by exactly the events emitted,
    /// the fee event comes first and only when a fee is due, and no third balance moves.
    function testFuzz_transferEventsAccountForEveryUnitMoved(uint256 raw, uint8 fromSeed, uint8 toSeed, bool delegated)
        public
    {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = _bound(raw, 0, SUPPLY);
        if (from != address(factory)) _fund(from, amount);
        if (delegated) _approve(from, SPENDER, amount);
        uint256[7] memory before = _snapshot();

        vm.recordLogs();
        if (delegated) {
            vm.prank(SPENDER);
            assertTrue(token.transferFrom(from, to, amount));
        } else {
            vm.prank(from);
            assertTrue(token.transfer(to, amount));
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool exempt = _isExempt(from) || _isExempt(to);
        uint256 fee;
        if (logs.length == 2) {
            assertTrue(!exempt);
            fee = _decode(logs[0], from, TREASURY);
            assertTrue(fee > 0);
            assertTrue(fee * 100 <= amount && amount < (fee + 1) * 100);
            assertEq(_decode(logs[1], from, to), amount - fee);
        } else {
            assertEq(logs.length, 1);
            assertTrue(exempt || amount < 100);
            assertEq(_decode(logs[0], from, to), amount);
        }

        // Replay the events on the snapshot; the token's balances must agree with that ledger.
        for (uint256 i; i < actors.length; ++i) {
            uint256 expected = before[i];
            if (actors[i] == from) expected -= amount;
            if (actors[i] == to) expected += amount - fee;
            if (actors[i] == TREASURY) expected += fee;
            assertEq(token.balanceOf(actors[i]), expected);
        }
        assertEq(token.allowance(from, SPENDER), 0);
        assertEq(token.balanceOf(SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A transfer between two parties never touches a bystander's balance or allowances,
    /// and never touches allowances that were not spent.
    function testFuzz_bystanderStateIsUntouched(uint256 raw, uint8 fromSeed, uint8 toSeed, uint256 rawAllowance)
        public
    {
        address from = actors[fromSeed % 6];
        address to = actors[toSeed % 6];
        uint256 amount = _bound(raw, 0, SUPPLY / 2);
        uint256 granted = rawAllowance;
        _fund(CAROL, SUPPLY / 2);
        _approve(CAROL, from, granted);
        _approve(CAROL, to, granted);
        _approve(from, CAROL, granted);
        _approve(from, SPENDER, granted);
        if (from != address(factory)) _fund(from, amount);

        vm.prank(from);
        assertTrue(token.transfer(to, amount));

        assertEq(token.balanceOf(CAROL), SUPPLY / 2);
        assertEq(token.balanceOf(SPENDER), 0);
        assertEq(token.allowance(CAROL, from), granted);
        assertEq(token.allowance(CAROL, to), granted);
        assertEq(token.allowance(from, CAROL), granted);
        assertEq(token.allowance(from, SPENDER), granted);
        // Nothing was ever approved between the two endpoints; a plain transfer must not invent it.
        assertEq(token.allowance(from, to), 0);
        assertEq(token.allowance(to, from), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Under gas starvation a transfer either reverts whole or applies its rule whole; the
    /// bounded registry lookup never degrades an exempt claim into a taxed one when the registry
    /// itself is cheap.
    function testFuzz_gasStarvedTransferIsAllOrNothing(uint256 rawGas, bool fromDistributor) public {
        uint256 gas = _bound(rawGas, 0, 120_000);
        address from = fromDistributor ? DISTRIBUTOR : ALICE;
        _fund(from, 100 ether);

        vm.prank(from);
        (bool ok,) = address(token).call{gas: gas}(abi.encodeWithSelector(token.transfer.selector, BOB, 100 ether));

        if (ok) {
            assertEq(token.balanceOf(BOB), fromDistributor ? 100 ether : 99 ether);
            assertEq(token.balanceOf(TREASURY), fromDistributor ? 0 : 1 ether);
            assertEq(token.balanceOf(from), 0);
        } else {
            assertEq(token.balanceOf(BOB), 0);
            assertEq(token.balanceOf(TREASURY), 0);
            assertEq(token.balanceOf(from), 100 ether);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_gasStarvedTransferPinnedAtTooLittleAndEnough() public {
        _fund(DISTRIBUTOR, 100 ether);
        vm.prank(DISTRIBUTOR);
        (bool ok,) = address(token).call{gas: 25_000}(abi.encodeWithSelector(token.transfer.selector, BOB, 100 ether));
        assertTrue(!ok);
        assertEq(token.balanceOf(DISTRIBUTOR), 100 ether);
        assertEq(token.balanceOf(BOB), 0);
        vm.prank(DISTRIBUTOR);
        (ok,) = address(token).call{gas: 120_000}(abi.encodeWithSelector(token.transfer.selector, BOB, 100 ether));
        assertTrue(ok);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.balanceOf(BOB), 100 ether);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function _isExempt(address account) private view returns (bool) {
        return account == address(factory) || account == MANAGER || account == DISTRIBUTOR;
    }

    function _snapshot() private view returns (uint256[7] memory held) {
        for (uint256 i; i < actors.length; ++i) {
            held[i] = token.balanceOf(actors[i]);
        }
    }

    function _decode(Vm.Log memory entry, address from, address to) private view returns (uint256) {
        assertEq(entry.emitter, address(token));
        assertEq(entry.topics.length, 3);
        assertEq(entry.topics[0], TRANSFER);
        assertEq(entry.topics[1], bytes32(uint256(uint160(from))));
        assertEq(entry.topics[2], bytes32(uint256(uint160(to))));
        return abi.decode(entry.data, (uint256));
    }

    function _fund(address to, uint256 amount) private {
        vm.prank(address(factory));
        assertTrue(token.transfer(to, amount));
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
    }

    function _bound(uint256 value, uint256 min, uint256 max) private pure returns (uint256) {
        if (value >= min && value <= max) return value;
        return min + value % (max - min + 1);
    }
}
