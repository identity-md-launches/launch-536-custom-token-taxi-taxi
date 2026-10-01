// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Taxi} from "../src/Taxi.sol";
import {TestBase} from "./helpers/TestBase.sol";

/// @dev Malformed, failing, gas-consuming, and state-changing registry responses.
contract FaultyRegistry {
    uint256 public mode;
    uint256 public writes;

    function setMode(uint256 mode_) external {
        mode = mode_;
    }

    fallback() external {
        uint256 currentMode = mode;
        assembly {
            switch currentMode
            case 0 { revert(0, 0) }
            case 1 { return(0, 0) }
            case 2 {
                mstore(0, 0x1002)
                return(0, 31)
            }
            case 3 {
                mstore(0, not(0))
                return(0, 32)
            }
            case 4 {
                mstore(0, 0x1002)
                return(0, 0x10000)
            }
            case 5 { for {} 1 {} {} }
            case 6 { sstore(1, 1) }
            default {
                mstore(0, 0x1002)
                return(0, 32)
            }
        }
    }
}

contract TaxiRegistryTest is TestBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant MANAGER = address(0x1001);
    address internal constant DISTRIBUTOR = address(0x1002);

    FaultyRegistry internal registry;
    Taxi internal token;

    function setUp() public {
        registry = new FaultyRegistry();
        token = new Taxi(address(registry), MANAGER, 42);
    }

    function testFuzz_registryFaultsDoNotFreezeOrdinaryTransfers(uint8 rawMode) public {
        registry.setMode(rawMode % 7);
        assertEq(token.rewardsDistributor(), address(0));
        assertTrue(token.transfer(DISTRIBUTOR, 100 ether));
        assertEq(token.balanceOf(DISTRIBUTOR), 99 ether);
        assertEq(token.balanceOf(token.TREASURY()), 1 ether);
        assertEq(registry.writes(), 0);
    }

    function test_failedRegistryDoesNotAffectFixedExemptions() public {
        // A registry that consumes all forwarded gas is skipped for fixed exemptions.
        registry.setMode(5);
        assertTrue(token.transfer(MANAGER, 100 ether));
        assertEq(token.balanceOf(MANAGER), 100 ether);
        vm.prank(MANAGER);
        assertTrue(token.transfer(ALICE, 100 ether));
        assertEq(token.balanceOf(ALICE), 100 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(address(registry), 100 ether));
        assertEq(token.balanceOf(address(registry)), 100 ether);
        vm.prank(address(registry));
        assertTrue(token.transfer(ALICE, 100 ether));
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(token.TREASURY()), 0);
    }

    function test_successfulRegistryReadMakesDistributorExempt() public {
        registry.setMode(7);
        assertEq(token.rewardsDistributor(), DISTRIBUTOR);
        assertTrue(token.transfer(DISTRIBUTOR, 100 ether));
        assertEq(token.balanceOf(DISTRIBUTOR), 100 ether);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(ALICE, 100 ether));
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(token.TREASURY()), 0);
    }

    function test_registryWithNoCodeDefaultsToTaxedTransfers() public {
        Taxi standalone = new Taxi(address(0x1234), MANAGER, 42);
        assertEq(standalone.rewardsDistributor(), address(0));
        assertTrue(standalone.transfer(ALICE, 100 ether));
        assertEq(standalone.balanceOf(ALICE), 99 ether);
        assertEq(standalone.balanceOf(standalone.TREASURY()), 1 ether);
    }

    function test_registryRecoveryIsRecognizedWithoutTokenConfiguration() public {
        assertTrue(token.transfer(DISTRIBUTOR, 100 ether));
        assertEq(token.balanceOf(DISTRIBUTOR), 99 ether);
        registry.setMode(7);
        assertTrue(token.transfer(DISTRIBUTOR, 100 ether));
        assertEq(token.balanceOf(DISTRIBUTOR), 199 ether);
        registry.setMode(0);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(ALICE, 100 ether));
        assertEq(token.balanceOf(ALICE), 99 ether);
        assertEq(token.balanceOf(token.TREASURY()), 2 ether);
    }
}
