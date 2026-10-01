// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Taxi} from "../../src/Taxi.sol";

/// @dev Test fixture only. Production must use the chain's actual launch factory.
contract LaunchFactoryMock {
    mapping(uint64 => address) public distributorOf;

    function deploy(address manager, uint64 number) external returns (Taxi) {
        return new Taxi(address(this), manager, number);
    }

    function setDistributor(uint64 number, address distributor) external {
        distributorOf[number] = distributor;
    }
}
