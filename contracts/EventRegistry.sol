// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EventRegistry
 * @notice Manages event definitions and oracle-based resolution with M-of-N multisig
 * @dev Events are resolved by collecting threshold signatures from authorized oracles
 */
contract EventRegistry {

    // ============ Structs ============

    struct Event {
        bytes32 id;                 // Event identifier
        address[] signers;          // Authorized oracle addresses
        uint8 threshold;            // Required number of signatures (M in M-of-N)
        bool resolved;              // Whether event has been resolved
        bytes resolutionBytes;      // Encoded resolution data
    }

    // ============ State Variables ============

    /// @notice Mapping from event ID to event data
    mapping(bytes32 => Event) public events;

    // ============ Events ============

    event EventCreated(
        bytes32 indexed eventId,
        address[] signers,
        uint8 threshold
    );

    event EventResolved(
        bytes32 indexed eventId,
        bytes resolutionBytes,
        uint256 timestamp
    );

    // ============ Errors ============

    error EventAlreadyExists();
    error EventDoesNotExist();
    error EventAlreadyResolved();
    error InvalidThreshold();
    error InvalidSigners();
    error InsufficientSignatures();
    error InvalidSignature();
    error DuplicateSigner();

    // ============ External Functions ============

    /**
     * @notice Creates a new event with oracle configuration
     * @param eventId Unique identifier for the event
     * @param signers Array of authorized oracle addresses
     * @param threshold Number of signatures required (M in M-of-N)
     */
    function createEvent(
        bytes32 eventId,
        address[] calldata signers,
        uint8 threshold
    ) external {
        // Validation
        if (events[eventId].id != bytes32(0)) revert EventAlreadyExists();
        if (signers.length == 0) revert InvalidSigners();
        if (threshold == 0 || threshold > signers.length) revert InvalidThreshold();

        // Check for duplicate signers
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == address(0)) revert InvalidSigners();
            for (uint256 j = i + 1; j < signers.length; j++) {
                if (signers[i] == signers[j]) revert DuplicateSigner();
            }
        }

        // Store event
        events[eventId] = Event({
            id: eventId,
            signers: signers,
            threshold: threshold,
            resolved: false,
            resolutionBytes: ""
        });

        emit EventCreated(eventId, signers, threshold);
    }

    /**
     * @notice Resolves an event with M-of-N multisig signatures
     * @param eventId The event to resolve
     * @param signatures Array of signatures from oracles
     * @param resolutionBytes Encoded resolution data
     */
    function resolveEvent(
        bytes32 eventId,
        bytes[] calldata signatures,
        bytes calldata resolutionBytes
    ) external {
        Event storage eventData = events[eventId];

        // Validation
        if (eventData.id == bytes32(0)) revert EventDoesNotExist();
        if (eventData.resolved) revert EventAlreadyResolved();
        if (signatures.length < eventData.threshold) revert InsufficientSignatures();

        // Construct message hash for signature verification
        bytes32 messageHash = keccak256(
            abi.encodePacked(address(this), eventId, resolutionBytes)
        );
        bytes32 ethSignedMessageHash = getEthSignedMessageHash(messageHash);

        // Track unique signers
        address[] memory uniqueSigners = new address[](signatures.length);
        uint256 validSignatureCount = 0;

        // Verify signatures
        for (uint256 i = 0; i < signatures.length; i++) {
            address recoveredSigner = recoverSigner(ethSignedMessageHash, signatures[i]);

            // Check if signer is authorized
            if (!isAuthorizedSigner(eventData.signers, recoveredSigner)) {
                continue; // Skip invalid signers
            }

            // Check for duplicate signer
            bool isDuplicate = false;
            for (uint256 j = 0; j < validSignatureCount; j++) {
                if (uniqueSigners[j] == recoveredSigner) {
                    isDuplicate = true;
                    break;
                }
            }

            if (!isDuplicate) {
                uniqueSigners[validSignatureCount] = recoveredSigner;
                validSignatureCount++;
            }

            // Early exit if we have enough valid signatures
            if (validSignatureCount >= eventData.threshold) {
                break;
            }
        }

        // Ensure we have enough valid signatures
        if (validSignatureCount < eventData.threshold) {
            revert InsufficientSignatures();
        }

        // Mark event as resolved
        eventData.resolved = true;
        eventData.resolutionBytes = resolutionBytes;

        emit EventResolved(eventId, resolutionBytes, block.timestamp);
    }

    // ============ View Functions ============

    /**
     * @notice Gets event data
     * @param eventId The event identifier
     * @return Event struct
     */
    function getEvent(bytes32 eventId) external view returns (Event memory) {
        return events[eventId];
    }

    /**
     * @notice Checks if an event is resolved
     * @param eventId The event identifier
     * @return True if event is resolved
     */
    function isResolved(bytes32 eventId) external view returns (bool) {
        return events[eventId].resolved;
    }

    /**
     * @notice Gets resolution data for an event
     * @param eventId The event identifier
     * @return Resolution bytes
     */
    function getResolution(bytes32 eventId) external view returns (bytes memory) {
        if (!events[eventId].resolved) revert EventDoesNotExist();
        return events[eventId].resolutionBytes;
    }

    // ============ Internal Functions ============

    /**
     * @notice Checks if an address is an authorized signer for the event
     * @param signers Array of authorized signers
     * @param signer Address to check
     * @return True if signer is authorized
     */
    function isAuthorizedSigner(address[] memory signers, address signer)
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == signer) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Recovers signer address from signature
     * @param ethSignedMessageHash The hash that was signed
     * @param signature The signature bytes
     * @return Recovered signer address
     */
    function recoverSigner(bytes32 ethSignedMessageHash, bytes memory signature)
        internal
        pure
        returns (address)
    {
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(signature);
        return ecrecover(ethSignedMessageHash, v, r, s);
    }

    /**
     * @notice Splits signature into r, s, v components
     * @param sig The signature bytes
     * @return r, s, v components
     */
    function splitSignature(bytes memory sig)
        internal
        pure
        returns (bytes32 r, bytes32 s, uint8 v)
    {
        require(sig.length == 65, "Invalid signature length");

        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }

        // Adjust v if needed (some wallets use 0/1 instead of 27/28)
        if (v < 27) {
            v += 27;
        }

        require(v == 27 || v == 28, "Invalid signature v value");
    }

    /**
     * @notice Constructs EIP-191 compliant message hash
     * @param messageHash The original message hash
     * @return EIP-191 prefixed hash
     */
    function getEthSignedMessageHash(bytes32 messageHash)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
    }
}
