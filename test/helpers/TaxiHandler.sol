// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Taxi} from "../../src/Taxi.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TestBase} from "./TestBase.sol";
import {LaunchFactoryMock} from "./LaunchFactoryMock.sol";

/// @dev Closed actor set: every possible recipient (including the treasury) is tracked.
/// Ghost balances start from the specified mint, never from observed token balances.
contract TaxiHandler is TestBase {
    uint256 internal constant SUPPLY = 100_000_000 ether;
    uint64 internal constant LAUNCH = 42;
    address internal constant TREASURY = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    address internal constant MANAGER = address(0x1001);

    Taxi public immutable token;
    LaunchFactoryMock public immutable factory;
    address[8] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    address public expectedDistributor;
    uint256 public successfulTransfers;
    uint256 public rejectedCalls;

    constructor(Taxi token_, LaunchFactoryMock factory_) {
        token = token_;
        factory = factory_;
        actors = [
            address(factory_),
            MANAGER,
            address(0x1002),
            address(0x1003),
            address(0xA11CE),
            address(0xB0B),
            address(0xCA401),
            TREASURY
        ];
        expectedBalance[address(factory_)] = SUPPLY;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) public {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), _bound(rawAmount, 0, expectedBalance[from]));
    }

    function transferBoundary(uint256 fromSeed, uint256 toSeed, uint8 choice) external {
        address from = _actor(fromSeed);
        uint256[8] memory edges = [uint256(0), 1, 99, 100, 101, 199, 200, expectedBalance[from]];
        uint256 amount = edges[choice % edges.length];
        if (amount > expectedBalance[from]) amount = expectedBalance[from];
        _transfer(from, _actor(toSeed), amount);
    }

    /// @dev Replacements and revocations persist until a later, independently chosen spend.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount, uint8 mode) public {
        uint256 amount = mode % 3 == 0 ? 0 : mode % 3 == 1 ? type(uint256).max : _bound(rawAmount, 0, SUPPLY);
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 toSeed, uint256 spenderSeed, uint256 rawAmount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 available = expectedBalance[owner];
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 limit = available < allowed ? available : allowed;
        _spend(owner, _actor(toSeed), spender, _bound(rawAmount, 0, limit));
    }

    /// @dev Guarantees meaningful delegated transfers even early in a sequence, before approvals accumulate.
    function approveAndTransferFrom(
        uint256 ownerSeed,
        uint256 toSeed,
        uint256 spenderSeed,
        uint256 rawAmount,
        bool infinite
    ) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _bound(rawAmount, 0, expectedBalance[owner]);
        _approve(owner, spender, infinite ? type(uint256).max : amount);
        _spend(owner, _actor(toSeed), spender, amount);
    }

    /// @dev Exercise registration, removal, replacement, address aliases, and unrelated launch keys.
    function changeDistributor(uint256 seed, bool otherLaunch) public {
        uint256 index = seed % (actors.length + 1);
        address next = index == actors.length ? address(0) : actors[index];
        factory.setDistributor(otherLaunch ? LAUNCH + 1 : LAUNCH, next);
        if (!otherLaunch) expectedDistributor = next;
    }

    /// @dev Catch only the expected failure; invariant checks then verify atomic rollback of ALL state.
    function rejectInvalidCall(uint256 ownerSeed, uint256 toSeed, uint256 spenderSeed, uint256 rawAmount, uint8 kind)
        external
    {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        address spender = _actor(spenderSeed);
        uint256 held = expectedBalance[owner];
        uint256 mode = kind % 6;
        uint256 amount;
        bytes memory data;
        bytes memory reason;
        address caller = owner;

        if (mode == 0 || mode == 2) {
            // Include max uint without overflowing the generator, and require the gross balance
            // even when owner == recipient or owner == treasury.
            amount = rawAmount % 2 == 0 ? type(uint256).max : held + _bound(rawAmount, 1, SUPPLY);
            reason = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount);
            if (mode == 0) {
                data = abi.encodeWithSelector(token.transfer.selector, to, amount);
            } else {
                _approve(owner, spender, amount);
                caller = spender;
                data = abi.encodeWithSelector(token.transferFrom.selector, owner, to, amount);
            }
        } else if (mode == 1) {
            // One unit short, including an empty/revoked allowance when amount == 1.
            amount = _bound(rawAmount, 1, held == 0 ? 1 : held);
            _approve(owner, spender, amount - 1);
            caller = spender;
            data = abi.encodeWithSelector(token.transferFrom.selector, owner, to, amount);
            reason =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, amount - 1, amount);
        } else if (mode == 3 || mode == 4) {
            amount = _bound(rawAmount, 0, held);
            reason = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
            if (mode == 3) {
                data = abi.encodeWithSelector(token.transfer.selector, address(0), amount);
            } else {
                _approve(owner, spender, amount + 1);
                caller = spender;
                data = abi.encodeWithSelector(token.transferFrom.selector, owner, address(0), amount);
            }
        } else {
            data = abi.encodeWithSelector(token.approve.selector, address(0), rawAmount);
            reason = abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0));
        }

        vm.prank(caller);
        (bool ok, bytes memory result) = address(token).call(data);
        require(!ok, "invalid token operation succeeded");
        require(keccak256(result) == keccak256(reason), "unexpected rejection reason");
        ++rejectedCalls;
    }

    function _transfer(address from, address to, uint256 amount) private {
        vm.prank(from);
        require(token.transfer(to, amount), "valid transfer returned false");
        _accountTransfer(from, to, amount);
    }

    function _spend(address owner, address to, address spender, uint256 amount) private {
        vm.prank(spender);
        require(token.transferFrom(owner, to, amount), "valid transferFrom returned false");
        if (expectedAllowance[owner][spender] != type(uint256).max) {
            expectedAllowance[owner][spender] -= amount;
        }
        _accountTransfer(owner, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        require(token.approve(spender, amount), "valid approval returned false");
        expectedAllowance[owner][spender] = amount;
    }

    function _accountTransfer(address from, address to, uint256 amount) private {
        // Specification oracle: fixed 1% of gross, floor-rounded, with endpoint exemptions.
        // Do not read fee constants, registry answers, or resulting balances from the token.
        bool exempt = from == actors[0] || to == actors[0] || from == MANAGER || to == MANAGER
            || (expectedDistributor != address(0) && (from == expectedDistributor || to == expectedDistributor));
        uint256 fee = exempt ? 0 : amount * 100 / 10_000;
        // Sequential ledger entries intentionally account for from/to/treasury aliases.
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount - fee;
        expectedBalance[TREASURY] += fee;
        ++successfulTransfers;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _bound(uint256 value, uint256 min, uint256 max) private pure returns (uint256) {
        if (value >= min && value <= max) return value;
        return min + value % (max - min + 1);
    }
}
