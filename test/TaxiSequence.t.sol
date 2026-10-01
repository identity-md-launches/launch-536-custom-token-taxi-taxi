// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Taxi} from "../src/Taxi.sol";
import {TestBase} from "./helpers/TestBase.sol";
import {LaunchFactoryMock} from "./helpers/LaunchFactoryMock.sol";

contract TaxiSequenceTest is TestBase {
    Taxi internal token;
    LaunchFactoryMock internal factory;
    uint256 internal constant SUPPLY = 100_000_000 ether;

    function setUp() public {
        factory = new LaunchFactoryMock();
        token = factory.deploy(address(0x1001), 42);
        factory.setDistributor(42, address(0x1002));
    }

    function testFuzz_transferSequencesPreserveModelAndSupply(bytes32 seed) public {
        // The first three endpoints are exempt. Index 5 is the treasury.
        address[7] memory actors = [
            address(factory),
            address(0x1001),
            address(0x1002),
            address(0xA11CE),
            address(0xB0B),
            token.TREASURY(),
            address(0x5EED)
        ];
        uint256[7] memory expected;
        expected[0] = 40_000_000 ether;
        for (uint256 i = 1; i < actors.length; ++i) {
            vm.prank(address(factory));
            assertTrue(token.transfer(actors[i], 10_000_000 ether));
            expected[i] = 10_000_000 ether;
        }
        for (uint256 i; i < 40; ++i) {
            _step(actors, expected, uint256(keccak256(abi.encode(seed, i))));
            uint256 sum;
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.balanceOf(actors[j]), expected[j]);
                sum += token.balanceOf(actors[j]);
            }
            assertEq(sum, SUPPLY);
            assertEq(token.totalSupply(), SUPPLY);
        }
    }

    function _step(address[7] memory actors, uint256[7] memory expected, uint256 entropy) private {
        uint256 fromIndex = entropy % 7;
        uint256 toIndex = (entropy >> 8) % 7;
        uint256 amount = (entropy >> 16) % (expected[fromIndex] + 1);
        uint256 fee = (fromIndex < 3 || toIndex < 3) ? 0 : amount / 100;
        address from = actors[fromIndex];
        address to = actors[toIndex];

        if (entropy & 1 == 0) {
            vm.prank(from);
            assertTrue(token.transfer(to, amount));
        } else {
            address spender = actors[(entropy >> 224) % 7];
            vm.prank(from);
            assertTrue(token.approve(spender, amount));
            vm.prank(spender);
            assertTrue(token.transferFrom(from, to, amount));
            assertEq(token.allowance(from, spender), 0);
        }

        expected[fromIndex] -= amount;
        expected[toIndex] += amount - fee;
        expected[5] += fee;
    }
}
