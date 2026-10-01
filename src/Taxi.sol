// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";

/// @notice Fixed-supply TAXI with a permanent 1% transfer fee and launch-flow exemptions.
contract Taxi is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 10 ** 18;
    uint256 public constant FEE_BPS = 100;
    address public constant TREASURY = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;

    address public immutable factory;
    address public immutable poolManager;
    uint64 public immutable launchNumber;

    error InvalidFactory();
    error InvalidPoolManager();

    /// @param factory_ Factory providing distributorOf(uint64), normally also the deployer.
    /// @param poolManager_ Pool manager whose inbound and outbound transfers must arrive whole.
    /// @param launchNumber_ Launch registry key; the distributor is registered after deployment.
    constructor(address factory_, address poolManager_, uint64 launchNumber_) ERC20("Taxi", "TAXI") {
        if (factory_ == address(0)) revert InvalidFactory();
        if (poolManager_ == address(0)) revert InvalidPoolManager();
        factory = factory_;
        poolManager = poolManager_;
        launchNumber = launchNumber_;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice Current rewards distributor, or zero if unavailable or not yet registered.
    /// @dev Bound both gas and copied return data so a failed registry cannot freeze transfers.
    /// The registry must return one ABI-encoded address within 30,000 gas.
    function rewardsDistributor() public view returns (address) {
        bytes memory input = abi.encodeCall(ILaunchFactory.distributorOf, (launchNumber));
        address registry = factory;
        uint256 word = 0;
        assembly ("memory-safe") {
            let output := mload(0x40)
            let ok := staticcall(30000, registry, add(input, 0x20), mload(input), output, 0x20)
            if and(ok, eq(returndatasize(), 0x20)) { word := mload(output) }
        }
        // Reject noncanonical address encodings rather than silently truncating them.
        if (word > type(uint160).max) return address(0);
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word));
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0)) {
            // The sole mint is in the constructor; there is no external mint or burn entrypoint.
            super._update(from, to, amount);
            return;
        }

        // Require the gross amount even when from == to or from == TREASURY.
        uint256 available = balanceOf(from);
        if (available < amount) revert ERC20InsufficientBalance(from, available, amount);

        if (amount < 100 || _exempt(from, to)) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = amount / 100; // Exactly 1%, rounded down in the smallest token unit.
        super._update(from, TREASURY, fee);
        super._update(from, to, amount - fee);
    }

    function _exempt(address from, address to) private view returns (bool) {
        if (from == factory || to == factory || from == poolManager || to == poolManager) return true;
        address distributor = rewardsDistributor();
        return distributor != address(0) && (from == distributor || to == distributor);
    }
}
