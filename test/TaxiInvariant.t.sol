// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Taxi} from "../src/Taxi.sol";
import {TestBase} from "./helpers/TestBase.sol";
import {LaunchFactoryMock} from "./helpers/LaunchFactoryMock.sol";
import {TaxiHandler} from "./helpers/TaxiHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TaxiInvariantTest is TestBase {
    uint256 internal constant SUPPLY = 100_000_000 ether;
    Taxi internal token;
    LaunchFactoryMock internal factory;
    TaxiHandler internal handler;

    // Foundry's invariant targeting ABI, kept local to avoid adding dependencies or remappings.
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    function setUp() public {
        factory = new LaunchFactoryMock();
        token = factory.deploy(address(0x1001), 42);
        handler = new TaxiHandler(token, factory);
        for (uint256 i = 1; i < 8; ++i) {
            handler.transfer(0, i, 10_000_000 ether);
        }
        for (uint256 i; i < 8; ++i) {
            handler.approve(i, 6, 1_000_000 ether, 2);
        }
        handler.changeDistributor(2, false);
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function targetSelectors() public view returns (FuzzSelector[] memory targets) {
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = TaxiHandler.transfer.selector;
        selectors[1] = TaxiHandler.transferBoundary.selector;
        selectors[2] = TaxiHandler.approve.selector;
        selectors[3] = TaxiHandler.transferFrom.selector;
        selectors[4] = TaxiHandler.approveAndTransferFrom.selector;
        selectors[5] = TaxiHandler.changeDistributor.selector;
        selectors[6] = TaxiHandler.rejectInvalidCall.selector;
        targets = new FuzzSelector[](1);
        targets[0] = FuzzSelector(address(handler), selectors);
    }

    function invariant_fixedSupplyAndExactBalances() public view {
        uint256 sum;
        for (uint256 i; i < 8; ++i) {
            address actor = handler.actors(i);
            uint256 held = token.balanceOf(actor);
            require(held == handler.expectedBalance(actor), "balance differs from independent ledger");
            sum += held;
        }
        require(token.totalSupply() == SUPPLY, "supply changed");
        require(sum == SUPPLY, "tokens lost, minted, or sent outside actor set");
        require(token.balanceOf(address(0)) == 0, "zero address received tokens");
    }

    function invariant_allowancesMatchAuthorizations() public view {
        for (uint256 i; i < 8; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < 8; ++j) {
                address spender = handler.actors(j);
                require(
                    token.allowance(owner, spender) == handler.expectedAllowance(owner, spender),
                    "allowance changed without authorization or failed to roll back"
                );
            }
            require(token.allowance(owner, address(0)) == 0, "zero spender authorized");
        }
    }

    function invariant_configurationAndRegistryStayConsistent() public view {
        assertEq(token.name(), "Taxi");
        assertEq(token.symbol(), "TAXI");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.FEE_BPS(), 100);
        assertEq(token.TREASURY(), 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7);
        assertEq(token.factory(), address(factory));
        assertEq(token.poolManager(), address(0x1001));
        assertEq(token.launchNumber(), 42);
        assertEq(token.rewardsDistributor(), handler.expectedDistributor());
    }

    /// @dev Deterministic replay covers each handler and failure branch even before random exploration.
    function test_handlerExercisesPersistentStateAndEveryRejection() public {
        handler.transfer(4, 5, 100 ether);
        handler.transferBoundary(7, 7, 7);
        handler.approve(4, 5, 300 ether, 2);
        handler.transferFrom(4, 4, 5, 100 ether);
        handler.transferFrom(4, 7, 5, 100 ether);
        handler.approveAndTransferFrom(7, 5, 6, 100 ether, true);
        handler.approveAndTransferFrom(5, 4, 6, 100 ether, false);
        handler.changeDistributor(3, false);
        handler.changeDistributor(4, true);
        handler.transfer(2, 4, 100 ether);
        handler.transfer(3, 4, 100 ether);
        handler.changeDistributor(8, false);
        for (uint8 mode; mode < 6; ++mode) {
            handler.rejectInvalidCall(4, 5, 6, 100 ether, mode);
            invariant_fixedSupplyAndExactBalances();
            invariant_allowancesMatchAuthorizations();
        }
        assertEq(handler.rejectedCalls(), 6);
        assertTrue(handler.successfulTransfers() > 7);
        invariant_configurationAndRegistryStayConsistent();
    }
}
