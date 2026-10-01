// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Taxi} from "../src/Taxi.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TestBase} from "./helpers/TestBase.sol";
import {LaunchFactoryMock} from "./helpers/LaunchFactoryMock.sol";

/// @dev Models only the ERC-20 movements and claim ownership relevant to the exemption.
/// This is not Uniswap v4: it omits unlock accounting, pools, swaps and ERC-6909 approvals.
contract PoolManagerTokenFlowModel {
    mapping(address token => mapping(address holder => uint256 amount)) public claims;

    // Token calls corresponding to a funded sync/settle/take relay.
    function relay(Taxi token, address to, uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount));
        require(token.transfer(to, amount));
    }

    // Token deposit and separate ledger corresponding to settle/mint.
    function depositClaim(Taxi token, uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount));
        claims[address(token)][msg.sender] += amount;
    }

    function transferClaim(Taxi token, address to, uint256 amount) external {
        claims[address(token)][msg.sender] -= amount;
        claims[address(token)][to] += amount;
    }

    // Claim cancellation and token movement corresponding to burn/take.
    function redeemClaim(Taxi token, uint256 amount) external {
        claims[address(token)][msg.sender] -= amount;
        require(token.transfer(msg.sender, amount));
    }
}

/// @dev Reproduction of finding 968446c3. These tests document the required exemption's
/// economic limitation; passing them does not mean the relay has been prevented.
contract TaxiPoolManagerRelayTest is TestBase {
    uint256 internal constant AMOUNT = 1_000_000 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    LaunchFactoryMock internal factory;
    PoolManagerTokenFlowModel internal manager;
    Taxi internal token;

    function setUp() public {
        factory = new LaunchFactoryMock();
        manager = new PoolManagerTokenFlowModel();
        token = factory.deploy(address(manager), 42);
        vm.prank(address(factory));
        assertTrue(token.transfer(ALICE, 2 * AMOUNT));
    }

    function test_directTransferPaysFeeButPoolManagerRelayDoesNot() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, AMOUNT));
        assertEq(token.balanceOf(BOB), 990_000 ether);
        assertEq(token.balanceOf(token.TREASURY()), 10_000 ether);

        vm.prank(ALICE);
        assertTrue(token.approve(address(manager), AMOUNT));
        vm.prank(ALICE);
        manager.relay(token, BOB, AMOUNT);

        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 1_990_000 ether);
        assertEq(token.balanceOf(token.TREASURY()), 10_000 ether);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.allowance(ALICE, address(manager)), 0);
        _assertConservation();
    }

    function test_claimOwnershipChangesAndRedemptionPayNoTaxiFee() public {
        vm.prank(ALICE);
        assertTrue(token.approve(address(manager), AMOUNT));
        vm.prank(ALICE);
        manager.depositClaim(token, AMOUNT);
        assertEq(manager.claims(address(token), ALICE), AMOUNT);
        assertEq(token.balanceOf(address(manager)), AMOUNT);

        vm.prank(ALICE);
        manager.transferClaim(token, BOB, AMOUNT);
        vm.prank(BOB);
        manager.transferClaim(token, CAROL, AMOUNT);
        assertEq(manager.claims(address(token), ALICE), 0);
        assertEq(manager.claims(address(token), BOB), 0);
        assertEq(manager.claims(address(token), CAROL), AMOUNT);
        assertEq(token.balanceOf(address(manager)), AMOUNT);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(CAROL), 0);
        assertEq(token.balanceOf(token.TREASURY()), 0);

        vm.prank(CAROL);
        manager.redeemClaim(token, AMOUNT);
        assertEq(manager.claims(address(token), CAROL), 0);
        assertEq(token.balanceOf(ALICE), AMOUNT);
        assertEq(token.balanceOf(CAROL), AMOUNT);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(token.TREASURY()), 0);
        _assertConservation();
    }

    function test_relayStillRequiresHolderAllowance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(manager), 0, AMOUNT)
        );
        vm.prank(ALICE);
        manager.relay(token, BOB, AMOUNT);
        assertEq(token.balanceOf(ALICE), 2 * AMOUNT);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(token.TREASURY()), 0);
        _assertConservation();
    }

    function _assertConservation() private view {
        assertEq(token.totalSupply(), 100_000_000 ether);
        assertEq(
            token.balanceOf(address(factory)) + token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(CAROL)
                + token.balanceOf(address(manager)) + token.balanceOf(token.TREASURY()),
            token.totalSupply()
        );
    }
}
