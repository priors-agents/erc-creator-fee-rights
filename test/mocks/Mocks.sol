// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {ICreatorFeeRights} from "../../src/ICreatorFeeRights.sol";
import {CreatorFeeEscrow} from "../../src/CreatorFeeEscrow.sol";

/// @notice A plain ERC-20 with a public mint. It stands for the launched tokens and for the asset fees are paid in.
contract MockToken {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice An ERC-20 that burns 1% of every transfer.
contract FeeOnTransferToken is MockToken {
    function _move(address from, address to, uint256 amount) internal override {
        uint256 burnt = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - burnt;
        emit Transfer(from, to, amount - burnt);
        emit Transfer(from, address(0), burnt);
    }
}

/// @notice A launchpad reduced to what the tests need. It registers each token with the escrow in the call that
///         launches it, and charges a fee on each trade that it pays into the escrow in the same call.
contract MockLaunchpad {
    event Launched(address indexed token, address indexed creator);
    event Traded(address indexed token, address indexed trader, address indexed asset, uint256 fee);

    CreatorFeeEscrow public escrow;

    /// @dev The escrow is deployed with this launchpad's address, so it is wired in once, afterwards.
    function setEscrow(CreatorFeeEscrow escrow_) external {
        require(address(escrow) == address(0), "set");
        escrow = escrow_;
    }

    function launch(address creator) external returns (address token) {
        token = address(new MockToken());
        escrow.register(token, creator);
        emit Launched(token, creator);
    }

    /// @notice A trade of `token` that costs the trader `fee` of `asset`, all of it paid into the escrow at once.
    function trade(address token, address asset, uint256 fee) external {
        require(MockToken(asset).transferFrom(msg.sender, address(this), fee), "pay");
        require(MockToken(asset).approve(address(escrow), fee), "approve");
        escrow.accrue(token, asset, fee);
        emit Traded(token, msg.sender, asset, fee);
    }
}

/// @notice A repay-first payee reduced to what the tests need. A creator points its fee recipient here; the payee
///         pays its one lender before the creator, and names a new fee recipient only at the creator's request and
///         only once the lender has no claim.
contract MockRepayFirstPayee {
    address public immutable creator;
    address public immutable lender;
    uint256 public owed; // what the creator owes the lender, in the asset swept

    constructor(address creator_, address lender_, uint256 owed_) {
        creator = creator_;
        lender = lender_;
        owed = owed_;
    }

    /// @notice Anyone may sweep: the lender is paid first, the creator gets the rest.
    function sweep(address asset) external returns (uint256 toLender, uint256 forwarded) {
        uint256 balance = MockToken(asset).balanceOf(address(this));
        toLender = balance < owed ? balance : owed;
        owed -= toLender;
        forwarded = balance - toLender;
        if (toLender != 0) require(MockToken(asset).transfer(lender, toLender), "lender");
        if (forwarded != 0) require(MockToken(asset).transfer(creator, forwarded), "creator");
    }

    /// @notice Hands the fee stream of `token` to `to`, for the creator, once nothing is owed.
    function handBack(ICreatorFeeRights rights, address token, address to) external {
        require(msg.sender == creator, "not creator");
        require(owed == 0, "lender has a claim");
        rights.setFeeRecipient(token, to);
    }
}
