// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Taxi} from "../src/Taxi.sol";
import {TestBase} from "./helpers/TestBase.sol";

/// @dev Answers the lookup with the gas it was given, so the budget can be observed from outside.
contract GasReportingRegistry {
    fallback() external {
        assembly {
            mstore(0, gas())
            return(0, 32)
        }
    }
}

/// @dev Answers only when given at least `need` gas; otherwise reverts like an expensive registry.
contract DemandingRegistry {
    uint256 private immutable need;

    constructor(uint256 need_) {
        need = need_;
    }

    fallback() external {
        uint256 required = need;
        assembly {
            if lt(gas(), required) { revert(0, 0) }
            mstore(0, 0x1002)
            return(0, 32)
        }
    }
}

/// @dev Payload shapes a strict decoder must reject, plus the widest address it must accept.
contract PayloadRegistry {
    uint256 public mode;

    function setMode(uint256 mode_) external {
        mode = mode_;
    }

    fallback() external {
        uint256 currentMode = mode;
        assembly {
            switch currentMode
            case 0 {
                // A revert whose data happens to be a well-formed address.
                mstore(0, 0x1002)
                revert(0, 32)
            }
            case 1 {
                // Two words: an address followed by a flag.
                mstore(0, 0x1002)
                mstore(32, 1)
                return(0, 64)
            }
            case 2 {
                // One bit above the address width.
                mstore(0, shl(160, 1))
                return(0, 32)
            }
            case 3 {
                // The widest canonical address.
                mstore(0, sub(shl(160, 1), 1))
                return(0, 32)
            }
            case 4 {
                mstore(0, 0)
                return(0, 32)
            }
            case 5 {
                // One trailing byte beyond a word.
                mstore(0, 0x1002)
                mstore(32, 0)
                return(0, 33)
            }
            default {
                mstore(0, 0x1002)
                return(0, 32)
            }
        }
    }
}

/// @dev Calls back into the token during the lookup: reads are allowed, writes must be absorbed.
contract ReenteringRegistry {
    Taxi public token;
    uint256 public mode;

    function configure(Taxi token_, uint256 mode_) external {
        token = token_;
        mode = mode_;
    }

    function distributorOf(uint64) external view returns (address) {
        if (mode == 0) {
            // A registry that consults the token while answering.
            token.balanceOf(address(this));
            token.totalSupply();
            return address(0x1002);
        }
        if (mode == 1) {
            // A registry that tries to move tokens while answering; the write must fail under
            // STATICCALL and the failure must surface as "no distributor", not as a stuck transfer.
            (bool ok,) = address(token).staticcall(abi.encodeWithSelector(token.transfer.selector, address(0xB0B), 1));
            require(ok, "write during lookup rejected");
            return address(0x1002);
        }
        // A registry that re-enters the lookup itself; the gas budget bounds the recursion.
        token.rewardsDistributor();
        return address(0x1002);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract TaxiRegistryBoundaryTest is TestBase {
    uint256 internal constant SUPPLY = 100_000_000 ether;
    uint256 internal constant LOOKUP_GAS = 30_000;
    address internal constant MANAGER = address(0x1001);
    address internal constant DISTRIBUTOR = address(0x1002);
    address internal constant BOB = address(0xB0B);
    address internal constant TREASURY = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;

    function test_lookupBudgetIsExactlyThirtyThousandGasAndNotRaisedByTheCaller() public {
        GasReportingRegistry registry = new GasReportingRegistry();
        Taxi token = new Taxi(address(registry), MANAGER, 42);
        uint256 observed = uint160(token.rewardsDistributor());
        // Dispatch into the fallback costs a few dozen gas; the stipend itself is the documented cap.
        assertTrue(observed <= LOOKUP_GAS);
        assertTrue(observed > LOOKUP_GAS - 200);
        uint256 observedAgain = uint160(token.rewardsDistributor{gas: 5_000_000}());
        assertTrue(observedAgain <= LOOKUP_GAS);
        assertEq(observedAgain, observed);
        // The gas-shaped answer is a nonzero address and is honored like any other registry answer.
        assertTrue(token.transfer(address(uint160(observed)), 100 ether));
        assertEq(token.balanceOf(address(uint160(observed))), 100 ether);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function testFuzz_registryWithinBudgetIsHonoredAndBeyondBudgetIsSilentlyAbsent(uint256 raw, bool beyond) public {
        uint256 need = beyond ? _bound(raw, LOOKUP_GAS + 1, 100_000_000) : _bound(raw, 0, LOOKUP_GAS - 1_000);
        DemandingRegistry registry = new DemandingRegistry(need);
        Taxi token = new Taxi(address(registry), MANAGER, 42);
        assertEq(token.rewardsDistributor(), beyond ? address(0) : DISTRIBUTOR);
        // A claim through an over-budget registry does not revert: it arrives taxed.
        assertTrue(token.transfer(DISTRIBUTOR, 100 ether));
        assertEq(token.balanceOf(DISTRIBUTOR), beyond ? 99 ether : 100 ether);
        assertEq(token.balanceOf(TREASURY), beyond ? 1 ether : 0);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(BOB, 50 ether));
        assertEq(token.balanceOf(BOB), beyond ? 49.5 ether : 50 ether);
        assertEq(token.balanceOf(TREASURY), beyond ? 1.5 ether : 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_budgetBoundaryPinnedJustBelowAndJustAboveTheCap() public {
        uint256[2] memory honored = [LOOKUP_GAS - 1_000, LOOKUP_GAS - 200];
        uint256[2] memory absent = [LOOKUP_GAS, LOOKUP_GAS + 1];
        for (uint256 i; i < 2; ++i) {
            Taxi token = new Taxi(address(new DemandingRegistry(honored[i])), MANAGER, 42);
            assertEq(token.rewardsDistributor(), DISTRIBUTOR);
            token = new Taxi(address(new DemandingRegistry(absent[i])), MANAGER, 42);
            assertEq(token.rewardsDistributor(), address(0));
        }
    }

    function test_malformedPayloadsAreAbsentAndWidestAddressIsAccepted() public {
        PayloadRegistry registry = new PayloadRegistry();
        Taxi token = new Taxi(address(registry), MANAGER, 42);
        uint256[5] memory rejected = [uint256(0), 1, 2, 4, 5];
        for (uint256 i; i < rejected.length; ++i) {
            registry.setMode(rejected[i]);
            assertEq(token.rewardsDistributor(), address(0));
            assertTrue(token.transfer(DISTRIBUTOR, 100));
        }
        // Every rejected shape produced a taxed transfer: five fees of one unit each.
        assertEq(token.balanceOf(DISTRIBUTOR), 495);
        assertEq(token.balanceOf(TREASURY), 5);

        registry.setMode(3);
        address widest = address(type(uint160).max);
        assertEq(token.rewardsDistributor(), widest);
        assertTrue(token.transfer(widest, 100 ether));
        assertEq(token.balanceOf(widest), 100 ether);
        vm.prank(widest);
        assertTrue(token.transfer(BOB, 100 ether));
        assertEq(token.balanceOf(BOB), 100 ether);
        assertEq(token.balanceOf(TREASURY), 5);

        registry.setMode(7);
        assertEq(token.rewardsDistributor(), DISTRIBUTOR);
        assertTrue(token.transfer(DISTRIBUTOR, 100));
        assertEq(token.balanceOf(DISTRIBUTOR), 595);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_registryReadingTheTokenDuringLookupIsHonored() public {
        ReenteringRegistry registry = new ReenteringRegistry();
        Taxi token = new Taxi(address(registry), MANAGER, 42);
        registry.configure(token, 0);
        assertEq(token.rewardsDistributor(), DISTRIBUTOR);
        assertTrue(token.transfer(DISTRIBUTOR, 100 ether));
        assertEq(token.balanceOf(DISTRIBUTOR), 100 ether);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function test_registryWritingTheTokenDuringLookupIsAbsentAndMovesNothing() public {
        ReenteringRegistry registry = new ReenteringRegistry();
        Taxi token = new Taxi(address(registry), MANAGER, 42);
        assertTrue(token.transfer(address(registry), 100 ether));
        registry.configure(token, 1);
        assertEq(token.rewardsDistributor(), address(0));
        assertTrue(token.transfer(DISTRIBUTOR, 100 ether));
        assertEq(token.balanceOf(DISTRIBUTOR), 99 ether);
        assertEq(token.balanceOf(TREASURY), 1 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(registry)), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_registryReenteringTheLookupNeverFreezesTransfers() public {
        ReenteringRegistry registry = new ReenteringRegistry();
        Taxi token = new Taxi(address(registry), MANAGER, 42);
        registry.configure(token, 2);
        // The nested lookups exhaust the 30,000-gas budget somewhere down the chain; whatever the
        // outermost registry answers, the lookup and the transfer must complete.
        address answered = token.rewardsDistributor();
        assertTrue(answered == address(0) || answered == DISTRIBUTOR);
        assertTrue(token.transfer(DISTRIBUTOR, 100 ether));
        uint256 fee = token.balanceOf(TREASURY);
        assertEq(fee, answered == DISTRIBUTOR ? 0 : 1 ether);
        assertEq(token.balanceOf(DISTRIBUTOR), 100 ether - fee);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _bound(uint256 value, uint256 min, uint256 max) private pure returns (uint256) {
        if (value >= min && value <= max) return value;
        return min + value % (max - min + 1);
    }
}
