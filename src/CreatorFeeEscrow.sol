// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {ICreatorFeeRights} from "./ICreatorFeeRights.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title CreatorFeeEscrow
/// @notice Reference implementation of the Creator Fee Rights draft: an escrow that one launchpad pays creator fees
///         into. The launchpad registers each token when it launches it and pays in every fee it charges on the token,
///         in the transaction that charges it. The escrow fixes each token's creator share at registration, credits
///         that share of each fee to the token's stream and sends the rest to the launchpad's protocol recipient at
///         once. The administrator sets the terms of future launches and the protocol recipient; nothing it can call
///         reaches a registered token's recipient or creator share, and the contract cannot be upgraded.
/// @dev Not audited. A reference for the interface.
contract CreatorFeeEscrow is ICreatorFeeRights, IERC165 {
    uint16 public constant BPS = 10_000;

    struct Stream {
        address recipient; // zero until the token is registered
        uint16 creatorShareBps; // fixed at registration
    }

    address private immutable _launchpad;

    address public admin;
    address public protocolRecipient;
    uint16 public defaultCreatorShareBps; // the share a token registered from now on gets

    mapping(address token => Stream) private _streams;
    mapping(address token => mapping(address asset => uint256)) private _accrued;
    mapping(address token => mapping(address asset => uint256)) private _claimed;
    bool private _locked;

    event AdminChanged(address indexed from, address indexed to);
    event ProtocolRecipientSet(address indexed recipient);
    event DefaultCreatorShareSet(uint16 bps);

    error NotLaunchpad();
    error NotAdmin();
    error NotRecipient();
    error ZeroAddress();
    error AlreadyRegistered();
    error NotRegistered();
    error BadShare();
    error Reentrant();
    error TransferFailed();

    modifier lock() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address launchpad_, address admin_, address protocolRecipient_, uint16 defaultCreatorShareBps_) {
        if (launchpad_ == address(0) || protocolRecipient_ == address(0)) revert ZeroAddress();
        if (defaultCreatorShareBps_ == 0 || defaultCreatorShareBps_ > BPS) revert BadShare();
        _launchpad = launchpad_;
        admin = admin_;
        protocolRecipient = protocolRecipient_;
        defaultCreatorShareBps = defaultCreatorShareBps_;
        emit AdminChanged(address(0), admin_);
        emit ProtocolRecipientSet(protocolRecipient_);
        emit DefaultCreatorShareSet(defaultCreatorShareBps_);
    }

    // ---------------------------------------------------------------- views

    /// @notice The only account that registers tokens and pays fees in. Never changes.
    function launchpad() external view returns (address) {
        return _launchpad;
    }

    /// @notice The share of each fee on `token` credited to its stream, in basis points: zero for a token never
    ///         registered. Never changes once the token is registered.
    function creatorShareBps(address token) external view returns (uint16) {
        return _streams[token].creatorShareBps;
    }

    function feeRecipient(address token) external view returns (address) {
        return _streams[token].recipient;
    }

    function accruedTotal(address token, address asset) external view returns (uint256) {
        return _accrued[token][asset];
    }

    function claimable(address token, address asset) public view returns (uint256) {
        return _accrued[token][asset] - _claimed[token][asset];
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICreatorFeeRights).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ---------------------------------------------------------------- the launchpad

    /// @notice Registers `token`, which the launchpad launches in this transaction, with `recipient` as the first
    ///         recipient of its creator fees and the current default as its creator share.
    function register(address token, address recipient) external {
        if (msg.sender != _launchpad) revert NotLaunchpad();
        if (token == address(0) || recipient == address(0)) revert ZeroAddress();
        if (_streams[token].recipient != address(0)) revert AlreadyRegistered();
        _streams[token] = Stream({recipient: recipient, creatorShareBps: defaultCreatorShareBps});
        emit FeeRecipientChanged(token, address(0), recipient);
    }

    /// @notice Called by the launchpad with each fee it charges on `token`, in the transaction that charges it. Takes
    ///         `fee` of `asset` from the launchpad, credits the token's creator share of what arrived to its stream and
    ///         sends the rest to the protocol recipient. Returns the amount credited.
    function accrue(address token, address asset, uint256 fee) external lock returns (uint256 credited) {
        if (msg.sender != _launchpad) revert NotLaunchpad();
        Stream memory s = _streams[token];
        if (s.recipient == address(0)) revert NotRegistered();

        // Credit what arrived, not what was announced, so a token with a transfer fee cannot overstate the stream.
        uint256 before = IERC20Minimal(asset).balanceOf(address(this));
        _call(asset, abi.encodeCall(IERC20Minimal.transferFrom, (msg.sender, address(this), fee)));
        uint256 received = IERC20Minimal(asset).balanceOf(address(this)) - before;

        credited = received * s.creatorShareBps / BPS;
        if (credited != 0) {
            _accrued[token][asset] += credited;
            emit CreatorFeesAccrued(token, asset, credited);
        }
        uint256 toProtocol = received - credited;
        if (toProtocol != 0) _call(asset, abi.encodeCall(IERC20Minimal.transfer, (protocolRecipient, toProtocol)));
    }

    /// @notice Called by a launchpad that can change the fee rate of `token`: at launch with the rate the token
    ///         launches with, and with each new rate in the transaction that sets it. `rate` is in millionths of the
    ///         amount traded. The escrow does not set or check the rate, and it leaves the creator share as it is.
    function reportFeeRate(address token, uint256 rate) external {
        if (msg.sender != _launchpad) revert NotLaunchpad();
        if (_streams[token].recipient == address(0)) revert NotRegistered();
        emit FeeRateChanged(token, rate);
    }

    // ---------------------------------------------------------------- the stream

    /// @dev Books and reports the amount sent. An asset that charges on transfer delivers less to the recipient.
    function claim(address token, address asset) external lock returns (uint256 amount) {
        amount = claimable(token, asset);
        if (amount == 0) return 0;
        address to = _streams[token].recipient;
        _claimed[token][asset] += amount;
        _call(asset, abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        emit CreatorFeesClaimed(token, to, asset, amount);
    }

    function setFeeRecipient(address token, address newRecipient) external {
        address current = _streams[token].recipient;
        if (current == address(0) || msg.sender != current) revert NotRecipient();
        if (newRecipient == address(0)) revert ZeroAddress();
        _streams[token].recipient = newRecipient;
        emit FeeRecipientChanged(token, current, newRecipient);
    }

    // ---------------------------------------------------------------- the administrator: future launches only

    function setDefaultCreatorShareBps(uint16 bps) external onlyAdmin {
        if (bps == 0 || bps > BPS) revert BadShare();
        defaultCreatorShareBps = bps;
        emit DefaultCreatorShareSet(bps);
    }

    function setProtocolRecipient(address recipient) external onlyAdmin {
        if (recipient == address(0)) revert ZeroAddress();
        protocolRecipient = recipient;
        emit ProtocolRecipientSet(recipient);
    }

    /// @notice Hands the administrator role on; the zero address renounces it.
    function setAdmin(address newAdmin) external onlyAdmin {
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    /// @dev A transfer or transferFrom that reverts, returns false, or reaches an address with no code fails. Tokens
    ///      that return nothing on success are accepted.
    function _call(address asset, bytes memory data) private {
        (bool ok, bytes memory ret) = asset.call(data);
        if (!ok) revert TransferFailed();
        if (ret.length == 0) {
            if (asset.code.length == 0) revert TransferFailed();
        } else if (!abi.decode(ret, (bool))) {
            revert TransferFailed();
        }
    }
}
