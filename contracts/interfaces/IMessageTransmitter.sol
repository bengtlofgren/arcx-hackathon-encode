// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMessageTransmitter
 * @notice Interface for Circle's CCTP MessageTransmitter contract
 * @dev Used to receive cross-chain messages on destination domain
 */
interface IMessageTransmitter {
    /**
     * @notice Receives an incoming message, validating the header and passing
     * the body to the specified recipient handler
     * @param message Message bytes
     * @param attestation Attestation bytes
     * @return success Whether the message was successfully received
     */
    function receiveMessage(bytes calldata message, bytes calldata attestation)
        external
        returns (bool success);

    /**
     * @notice Replaces a message with a new message
     * @param originalMessage Original message bytes
     * @param originalAttestation Original attestation bytes
     * @param newMessageBody New message body
     * @param newDestinationCaller New destination caller
     */
    function replaceMessage(
        bytes calldata originalMessage,
        bytes calldata originalAttestation,
        bytes calldata newMessageBody,
        bytes32 newDestinationCaller
    ) external;

    /**
     * @notice Returns the local domain
     * @return The local domain identifier
     */
    function localDomain() external view returns (uint32);
}
