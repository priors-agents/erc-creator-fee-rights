// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Creator Fee Rights (draft ERC)
/// @notice The creator fee stream of each token a launchpad launched: who receives it, what it has earned since launch,
///         what can be claimed now, and a recipient that only the current recipient can change, so that the stream can
///         be pledged to a lender.
/// @dev The ERC-165 identifier is `type(ICreatorFeeRights).interfaceId`. A token is registered when its first
///      `FeeRecipientChanged` is emitted, with `from` set to the zero address. `FeeRateChanged` is emitted only for a
///      launchpad that can change a launched token's fee rate, at registration and at each change, with the rate in
///      millionths of the amount traded.
interface ICreatorFeeRights {
    event CreatorFeesAccrued(address indexed token, address indexed asset, uint256 amount);
    event CreatorFeesClaimed(address indexed token, address indexed recipient, address indexed asset, uint256 amount);
    event FeeRecipientChanged(address indexed token, address indexed from, address indexed to);
    event FeeRateChanged(address indexed token, uint256 rate);

    /// @notice Who receives the creator fees of `token`: the zero address for a token never registered.
    function feeRecipient(address token) external view returns (address);

    /// @notice Every amount of `asset` credited to the stream of `token` since it was registered: the sum of its
    ///         `CreatorFeesAccrued` events. Never decreases.
    function accruedTotal(address token, address asset) external view returns (uint256);

    /// @notice What `claim(token, asset)` would send now: `accruedTotal` less what was claimed.
    function claimable(address token, address asset) external view returns (uint256);

    /// @notice Sends `claimable(token, asset)` to `feeRecipient(token)` and returns the amount sent. Anyone may call it;
    ///         the caller never chooses where the fees go. An asset that charges on transfer delivers less than it.
    function claim(address token, address asset) external returns (uint256);

    /// @notice Names a new recipient of the creator fees of `token`. The current recipient only.
    function setFeeRecipient(address token, address newRecipient) external;
}
