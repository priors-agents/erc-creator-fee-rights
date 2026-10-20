// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {ICreatorFeeRights} from "../src/ICreatorFeeRights.sol";
import {CreatorFeeEscrow} from "../src/CreatorFeeEscrow.sol";
import {MockToken, FeeOnTransferToken, MockLaunchpad, MockRepayFirstPayee} from "./mocks/Mocks.sol";

/// @notice A contract that runs other code in its own context, the way an upgradeable proxy does. It shows that the
///         opcode check in `test_code_cannotBeUpgraded` finds such code when it is there.
contract Delegator {
    function run(address target, bytes calldata data) external returns (bool ok) {
        (ok,) = target.delegatecall(data);
    }
}

contract CreatorFeeEscrowTest is Test {
    event CreatorFeesAccrued(address indexed token, address indexed asset, uint256 amount);
    event CreatorFeesClaimed(address indexed token, address indexed recipient, address indexed asset, uint256 amount);
    event FeeRecipientChanged(address indexed token, address indexed from, address indexed to);
    event Traded(address indexed token, address indexed trader, address indexed asset, uint256 fee);

    uint16 constant SHARE = 5_000; // the creator's half of each fee

    MockLaunchpad launchpad;
    CreatorFeeEscrow escrow;
    MockToken usd;
    MockToken weth;
    address admin = makeAddr("admin");
    address protocol = makeAddr("protocol");
    address creator = makeAddr("creator");
    address trader = makeAddr("trader");
    address stranger = makeAddr("stranger");
    address token; // launched by `creator` in setUp

    function setUp() public {
        launchpad = new MockLaunchpad();
        escrow = new CreatorFeeEscrow(address(launchpad), admin, protocol, SHARE);
        launchpad.setEscrow(escrow);
        usd = new MockToken();
        weth = new MockToken();
        token = launchpad.launch(creator);
    }

    function _fund(MockToken asset, uint256 fee) internal {
        asset.mint(trader, fee);
        vm.prank(trader);
        asset.approve(address(launchpad), fee);
    }

    function _trade(address t, MockToken asset, uint256 fee) internal {
        _fund(asset, fee);
        vm.prank(trader);
        launchpad.trade(t, address(asset), fee);
    }

    /// @dev The launchpad pays `fee` of `asset` it already holds into the escrow for `t`.
    function _payIn(MockToken asset, address t, uint256 fee) internal returns (uint256 credited) {
        asset.mint(address(launchpad), fee);
        vm.startPrank(address(launchpad));
        asset.approve(address(escrow), fee);
        credited = escrow.accrue(t, address(asset), fee);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- registration

    function test_launch_registersTheCreatorAsFirstRecipient() public {
        address next = vm.computeCreateAddress(address(launchpad), vm.getNonce(address(launchpad)));
        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeRecipientChanged(next, address(0), creator);
        address t = launchpad.launch(creator);

        assertEq(t, next);
        assertEq(escrow.feeRecipient(t), creator);
        assertEq(escrow.creatorShareBps(t), SHARE);
        assertEq(escrow.accruedTotal(t, address(usd)), 0);
        assertEq(escrow.launchpad(), address(launchpad));
    }

    function test_register_rejectsZeroAddresses() public {
        vm.startPrank(address(launchpad));
        vm.expectRevert(CreatorFeeEscrow.ZeroAddress.selector);
        escrow.register(address(0), creator);
        vm.expectRevert(CreatorFeeEscrow.ZeroAddress.selector);
        escrow.register(address(0xbeef), address(0));
        vm.stopPrank();
        assertEq(escrow.feeRecipient(address(0xbeef)), address(0));
    }

    function test_register_aRegisteredTokenAgain_reverts() public {
        vm.prank(address(launchpad));
        vm.expectRevert(CreatorFeeEscrow.AlreadyRegistered.selector);
        escrow.register(token, address(launchpad));
        assertEq(escrow.feeRecipient(token), creator);
    }

    function test_register_onlyTheLaunchpad() public {
        vm.prank(stranger);
        vm.expectRevert(CreatorFeeEscrow.NotLaunchpad.selector);
        escrow.register(address(0xbeef), stranger);
    }

    function test_unregisteredToken_hasNoRecipientAndNothingToClaim() public {
        address other = address(new MockToken());
        usd.mint(address(escrow), 1e6);
        assertEq(escrow.feeRecipient(other), address(0));
        assertEq(escrow.creatorShareBps(other), 0);
        assertEq(escrow.accruedTotal(other, address(usd)), 0);
        assertEq(escrow.claimable(other, address(usd)), 0);
        assertEq(escrow.claim(other, address(usd)), 0);
        assertEq(usd.balanceOf(address(escrow)), 1e6);

        vm.prank(address(launchpad));
        vm.expectRevert(CreatorFeeEscrow.NotRegistered.selector);
        escrow.accrue(other, address(usd), 0);
        vm.prank(stranger);
        vm.expectRevert(CreatorFeeEscrow.NotRecipient.selector);
        escrow.setFeeRecipient(other, stranger);
    }

    // ------------------------------------------------------------- accrual

    function test_trade_creditsTheCreatorShareWhereTheFeeIsCharged() public {
        _fund(usd, 100e6);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit CreatorFeesAccrued(token, address(usd), 50e6);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit Traded(token, trader, address(usd), 100e6);
        vm.prank(trader);
        launchpad.trade(token, address(usd), 100e6);

        assertEq(escrow.accruedTotal(token, address(usd)), 50e6);
        assertEq(escrow.claimable(token, address(usd)), 50e6);
        assertEq(usd.balanceOf(protocol), 50e6); // the launchpad's half, sent on at once
        assertEq(usd.balanceOf(address(escrow)), 50e6);
        assertEq(usd.balanceOf(creator), 0); // credited, not paid, until someone claims
    }

    function test_trade_aFeeTooSmallToCredit_creditsNothingAndEmitsNoAccrual() public {
        _fund(usd, 1);
        vm.recordLogs();
        vm.prank(trader);
        launchpad.trade(token, address(usd), 1); // half of one base unit rounds down to zero
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 fromEscrow;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(escrow)) ++fromEscrow;
        }
        assertEq(fromEscrow, 0);
        assertEq(escrow.accruedTotal(token, address(usd)), 0);
        assertEq(escrow.claimable(token, address(usd)), 0);
        assertEq(usd.balanceOf(protocol), 1); // the unit goes to the launchpad's side
        assertEq(usd.balanceOf(address(escrow)), 0);
    }

    function test_accrue_onlyTheLaunchpad() public {
        // A creator paying its own money into its stream would inflate the history a lender sizes on.
        usd.mint(creator, 100e6);
        vm.startPrank(creator);
        usd.approve(address(escrow), 100e6);
        vm.expectRevert(CreatorFeeEscrow.NotLaunchpad.selector);
        escrow.accrue(token, address(usd), 100e6);
        vm.stopPrank();
        vm.prank(admin);
        vm.expectRevert(CreatorFeeEscrow.NotLaunchpad.selector);
        escrow.accrue(token, address(usd), 0);
        assertEq(escrow.accruedTotal(token, address(usd)), 0);
    }

    function test_fundsSentDirectly_areNotCredited() public {
        _trade(token, usd, 100e6);
        usd.mint(creator, 70e6);
        vm.prank(creator);
        assertTrue(usd.transfer(address(escrow), 70e6));

        assertEq(escrow.accruedTotal(token, address(usd)), 50e6);
        assertEq(escrow.claimable(token, address(usd)), 50e6);
        assertEq(escrow.claim(token, address(usd)), 50e6);
        assertEq(escrow.claimable(token, address(usd)), 0);
    }

    function test_accrue_creditsWhatArrived() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        uint256 credited = _payIn(fot, token, 100e6);

        assertEq(credited, 49.5e6); // half of the 99e6 that arrived
        assertEq(escrow.accruedTotal(token, address(fot)), 49.5e6);
        assertEq(escrow.claim(token, address(fot)), 49.5e6); // and all of it can be paid
        assertEq(fot.balanceOf(address(escrow)), 0);
    }

    // ------------------------------------------------------------- the creator share

    function test_creatorShare_isFixedAtRegistration_whateverTheAdministratorSets() public {
        vm.prank(admin);
        escrow.setDefaultCreatorShareBps(1_000); // 10% for launches from now on
        address later = launchpad.launch(creator);

        _trade(token, usd, 100e6);
        _trade(later, usd, 100e6);
        assertEq(escrow.creatorShareBps(token), SHARE);
        assertEq(escrow.accruedTotal(token, address(usd)), 50e6);
        assertEq(escrow.creatorShareBps(later), 1_000);
        assertEq(escrow.accruedTotal(later, address(usd)), 10e6);
    }

    function test_adminSettings_onlyTheAdmin() public {
        vm.startPrank(stranger);
        vm.expectRevert(CreatorFeeEscrow.NotAdmin.selector);
        escrow.setDefaultCreatorShareBps(1);
        vm.expectRevert(CreatorFeeEscrow.NotAdmin.selector);
        escrow.setProtocolRecipient(stranger);
        vm.expectRevert(CreatorFeeEscrow.NotAdmin.selector);
        escrow.setAdmin(stranger);
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert(CreatorFeeEscrow.BadShare.selector);
        escrow.setDefaultCreatorShareBps(0);
        vm.expectRevert(CreatorFeeEscrow.BadShare.selector);
        escrow.setDefaultCreatorShareBps(10_001);
        vm.expectRevert(CreatorFeeEscrow.ZeroAddress.selector);
        escrow.setProtocolRecipient(address(0));
        escrow.setAdmin(address(0)); // renounced
        vm.expectRevert(CreatorFeeEscrow.NotAdmin.selector);
        escrow.setDefaultCreatorShareBps(1);
        vm.stopPrank();
    }

    function test_constructor_rejectsBadArguments() public {
        vm.expectRevert(CreatorFeeEscrow.ZeroAddress.selector);
        new CreatorFeeEscrow(address(0), admin, protocol, SHARE);
        vm.expectRevert(CreatorFeeEscrow.ZeroAddress.selector);
        new CreatorFeeEscrow(address(launchpad), admin, address(0), SHARE);
        vm.expectRevert(CreatorFeeEscrow.BadShare.selector);
        new CreatorFeeEscrow(address(launchpad), admin, protocol, 0);
        vm.expectRevert(CreatorFeeEscrow.BadShare.selector);
        new CreatorFeeEscrow(address(launchpad), admin, protocol, 10_001);
    }

    // ------------------------------------------------------------- the recipient

    function test_setFeeRecipient_byTheRecipient_changesItAndEmits() public {
        address next = makeAddr("next");
        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeRecipientChanged(token, creator, next);
        vm.prank(creator);
        escrow.setFeeRecipient(token, next);
        assertEq(escrow.feeRecipient(token), next);

        // From now on only `next` can name the recipient.
        vm.prank(creator);
        vm.expectRevert(CreatorFeeEscrow.NotRecipient.selector);
        escrow.setFeeRecipient(token, creator);
    }

    function test_setFeeRecipient_toTheZeroAddress_reverts() public {
        vm.prank(creator);
        vm.expectRevert(CreatorFeeEscrow.ZeroAddress.selector);
        escrow.setFeeRecipient(token, address(0));
        assertEq(escrow.feeRecipient(token), creator);
    }

    function testFuzz_setFeeRecipient_byAnyoneElse_reverts(address caller, address to) public {
        vm.assume(caller != creator);
        vm.prank(caller);
        vm.expectRevert(CreatorFeeEscrow.NotRecipient.selector);
        escrow.setFeeRecipient(token, to);
        assertEq(escrow.feeRecipient(token), creator);
    }

    function test_noAdministratorOrLaunchpadPath_changesTheRecipient() public {
        address newAdmin = makeAddr("newAdmin");
        vm.startPrank(admin);
        escrow.setDefaultCreatorShareBps(1);
        escrow.setProtocolRecipient(stranger);
        vm.expectRevert(CreatorFeeEscrow.NotRecipient.selector);
        escrow.setFeeRecipient(token, admin);
        escrow.setAdmin(newAdmin);
        vm.stopPrank();

        vm.startPrank(address(launchpad));
        vm.expectRevert(CreatorFeeEscrow.AlreadyRegistered.selector);
        escrow.register(token, address(launchpad));
        vm.expectRevert(CreatorFeeEscrow.NotRecipient.selector);
        escrow.setFeeRecipient(token, address(launchpad));
        vm.stopPrank();

        vm.prank(newAdmin);
        vm.expectRevert(CreatorFeeEscrow.NotRecipient.selector);
        escrow.setFeeRecipient(token, newAdmin);

        assertEq(escrow.feeRecipient(token), creator);
        assertEq(escrow.creatorShareBps(token), SHARE);
    }

    function test_code_cannotBeUpgraded() public {
        bytes memory code = address(escrow).code;
        assertFalse(_hasOpcode(code, 0xf4), "DELEGATECALL");
        assertFalse(_hasOpcode(code, 0xf2), "CALLCODE");
        assertFalse(_hasOpcode(code, 0xff), "SELFDESTRUCT");
        assertTrue(_hasOpcode(address(new Delegator()).code, 0xf4)); // the check finds such code when it is there
    }

    // ------------------------------------------------------------- claims

    function test_claim_byAnyone_paysTheRecipient() public {
        _trade(token, usd, 100e6);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit CreatorFeesClaimed(token, creator, address(usd), 50e6);
        vm.prank(stranger);
        uint256 paid = escrow.claim(token, address(usd));

        assertEq(paid, 50e6);
        assertEq(usd.balanceOf(creator), 50e6);
        assertEq(usd.balanceOf(stranger), 0);
        assertEq(escrow.claimable(token, address(usd)), 0);
        assertEq(escrow.accruedTotal(token, address(usd)), 50e6); // the history stays
    }

    function test_claim_inAnAssetThatChargesOnTransfer_sendsAndReportsTheAmountSent() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        address other = launchpad.launch(stranger);
        _payIn(fot, token, 100e6); // 99e6 arrive, 49.5e6 credited
        _payIn(fot, other, 100e6); // a second stream in the same asset
        uint256 before = fot.balanceOf(creator);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit CreatorFeesClaimed(token, creator, address(fot), 49.5e6);
        uint256 sent = escrow.claim(token, address(fot));

        assertEq(sent, 49.5e6);
        assertEq(fot.balanceOf(creator) - before, 49.005e6); // the asset keeps 1% of what was sent
        assertEq(escrow.claimable(token, address(fot)), 0);
        assertEq(escrow.accruedTotal(token, address(fot)), 49.5e6);
        assertEq(fot.balanceOf(address(escrow)), escrow.claimable(other, address(fot))); // only the other stream is left
        assertEq(escrow.claimable(other, address(fot)), 49.5e6);
    }

    function test_claim_withNothingClaimable_returnsZero_andDoesNothing() public {
        _trade(token, usd, 100e6);
        escrow.claim(token, address(usd));

        vm.recordLogs();
        assertEq(escrow.claim(token, address(usd)), 0);
        assertEq(escrow.claim(token, address(weth)), 0); // an asset never paid in
        assertEq(vm.getRecordedLogs().length, 0); // no transfer, no event
        assertEq(usd.balanceOf(creator), 50e6);
    }

    function test_unclaimedFees_arePaidToTheRecipientAtTheTimeOfTheClaim() public {
        address next = makeAddr("next");
        _trade(token, usd, 100e6);
        vm.prank(creator);
        escrow.setFeeRecipient(token, next);
        escrow.claim(token, address(usd));
        assertEq(usd.balanceOf(next), 50e6);
        assertEq(usd.balanceOf(creator), 0);
    }

    /// @dev A lender recounts `accruedTotal` and `claimable` from the escrow's logs alone, across two tokens, two
    ///      assets, trades, claims and changes of recipient, and finds the escrow holding exactly what is claimable.
    function testFuzz_figuresRecountFromLogs(uint256 seed) public {
        address[2] memory tokens = [token, launchpad.launch(stranger)];
        MockToken[2] memory assets = [usd, weth];

        vm.recordLogs();
        for (uint256 i; i < 24; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address t = tokens[r % 2];
            MockToken a = assets[(r >> 8) % 2];
            uint256 action = (r >> 16) % 4;
            if (action < 2) {
                _trade(t, a, (r >> 32) % 1e12);
            } else if (action == 2) {
                escrow.claim(t, address(a));
            } else {
                vm.prank(escrow.feeRecipient(t));
                escrow.setFeeRecipient(t, address(uint160(uint256(keccak256(abi.encode("recipient", r))))));
            }
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 j; j < 2; ++j) {
            uint256 held;
            for (uint256 k; k < 2; ++k) {
                (uint256 accrued, uint256 claimed) = _recount(logs, tokens[k], address(assets[j]));
                assertEq(escrow.accruedTotal(tokens[k], address(assets[j])), accrued);
                assertEq(escrow.claimable(tokens[k], address(assets[j])), accrued - claimed);
                held += accrued - claimed;
            }
            assertEq(assets[j].balanceOf(address(escrow)), held);
        }
    }

    // ------------------------------------------------------------- a pledged stream

    /// @dev The creator points its fee recipient at a repay-first payee. Only the payee can hand the stream back, and
    ///      it does so only once its lender is repaid.
    function test_repayFirstPayee_onlyThePayeeHandsTheStreamBack() public {
        address lender = makeAddr("lender");
        MockRepayFirstPayee payee = new MockRepayFirstPayee(creator, lender, 60e6);
        vm.prank(creator);
        escrow.setFeeRecipient(token, address(payee));

        // Neither the creator, the launchpad nor its administrator can take the stream back.
        address[3] memory others = [creator, address(launchpad), admin];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(CreatorFeeEscrow.NotRecipient.selector);
            escrow.setFeeRecipient(token, others[i]);
        }
        // The payee refuses while its lender is owed.
        vm.prank(creator);
        vm.expectRevert(bytes("lender has a claim"));
        payee.handBack(escrow, token, creator);

        // Fees repay the lender first: anyone claims them to the payee and sweeps it.
        _trade(token, usd, 200e6);
        vm.startPrank(stranger);
        escrow.claim(token, address(usd));
        payee.sweep(address(usd));
        vm.stopPrank();
        assertEq(usd.balanceOf(lender), 60e6);
        assertEq(usd.balanceOf(creator), 40e6);
        assertEq(payee.owed(), 0);

        // Repaid: the payee hands the stream back.
        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeRecipientChanged(token, address(payee), creator);
        vm.prank(creator);
        payee.handBack(escrow, token, creator);
        assertEq(escrow.feeRecipient(token), creator);
    }

    // ------------------------------------------------------------- interface

    function test_supportsInterface() public view {
        assertTrue(escrow.supportsInterface(type(ICreatorFeeRights).interfaceId));
        assertTrue(escrow.supportsInterface(0x01ffc9a7));
        assertFalse(escrow.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------- helpers

    /// @dev Sums the escrow's `CreatorFeesAccrued` and `CreatorFeesClaimed` logs for one token and asset.
    function _recount(Vm.Log[] memory logs, address t, address a)
        internal
        view
        returns (uint256 accrued, uint256 claimed)
    {
        bytes32 tt = bytes32(uint256(uint160(t)));
        bytes32 at = bytes32(uint256(uint160(a)));
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(escrow) || l.topics[1] != tt) continue;
            if (l.topics[0] == CreatorFeesAccrued.selector && l.topics[2] == at) {
                accrued += abi.decode(l.data, (uint256));
            } else if (l.topics[0] == CreatorFeesClaimed.selector && l.topics[3] == at) {
                claimed += abi.decode(l.data, (uint256));
            }
        }
    }

    /// @dev Whether `code` holds opcode `op`, skipping PUSH data and the compiler's metadata at the end.
    function _hasOpcode(bytes memory code, uint8 op) internal pure returns (bool) {
        uint256 n = code.length;
        uint256 meta = n >= 2 ? (uint256(uint8(code[n - 2])) << 8) | uint8(code[n - 1]) : 0;
        uint256 end = meta + 2 <= n ? n - meta - 2 : n;
        for (uint256 i; i < end; ++i) {
            uint8 b = uint8(code[i]);
            if (b == op) return true;
            if (b >= 0x60 && b <= 0x7f) i += b - 0x5f; // PUSH1..PUSH32 carry 1..32 bytes of data
        }
        return false;
    }
}
