// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITokenMessenger
 * @notice Interface for Circle's CCTP TokenMessenger contract
 * @dev Used to burn tokens on source chain for cross-chain transfer
 */
interface ITokenMessenger {
    /**
     * @notice Deposits and burns tokens from sender to be minted on destination domain
     * @param amount Amount of tokens to burn
     * @param destinationDomain Destination domain identifier
     * @param mintRecipient Address of mint recipient on destination domain
     * @param burnToken Address of contract to burn deposited tokens, on local domain
     * @return nonce Unique nonce reserved by message
     */
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce);

    /**
     * @notice Deposits and burns tokens with caller specified
     * @param amount Amount of tokens to burn
     * @param destinationDomain Destination domain identifier
     * @param mintRecipient Address of mint recipient on destination domain
     * @param burnToken Address of contract to burn deposited tokens
     * @param destinationCaller Authorized caller on destination domain
     * @return nonce Unique nonce reserved by message
     */
    function depositForBurnWithCaller(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller
    ) external returns (uint64 nonce);
}
