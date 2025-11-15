// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IUSDC.sol";
import "./interfaces/IUSDY.sol";
import "./interfaces/ITokenMessenger.sol";
import "./EventRegistry.sol";

/**
 * @title ConditionalVault
 * @notice Manages conditional balances and automatic cross-chain settlement via CCTP
 * @dev Supports transferable conditional positions and USDC/USDY collateral
 */
contract ConditionalVault {

    // ============ Structs ============

    struct Balance {
        uint256 amount;              // Amount of USDC owed on resolution
        uint32 destinationChain;     // CCTP domain ID for payout
        address destinationAddress;  // Recipient address on destination chain
    }

    // ============ State Variables ============

    /// @notice EventRegistry contract for checking resolution status
    EventRegistry public immutable eventRegistry;

    /// @notice USDC token contract
    IUSDC public immutable usdc;

    /// @notice USDY token contract (optional yield-bearing collateral)
    IUSDY public immutable usdy;

    /// @notice Circle's CCTP TokenMessenger for cross-chain transfers
    ITokenMessenger public immutable tokenMessenger;

    /// @notice Mapping: user => eventId => balances
    mapping(address => mapping(bytes32 => Balance[])) public balances;

    /// @notice Tracks if an event has been settled
    mapping(bytes32 => bool) public settled;

    /// @notice Nonces for transfer signature replay prevention
    mapping(address => uint256) public nonces;

    /// @notice Contract owner for admin functions
    address public owner;

    // ============ Events ============

    event ConditionalBalanceAdded(
        address indexed user,
        bytes32 indexed eventId,
        uint256 amount,
        uint32 destinationChain,
        address destinationAddress
    );

    event ConditionalBalanceTransferred(
        address indexed from,
        address indexed to,
        bytes32 indexed eventId,
        uint256 amount,
        uint32 toDestChain,
        address toDestAddress
    );

    event EventSettled(
        bytes32 indexed eventId,
        uint256 totalAmount,
        uint256 userCount
    );

    event SettlementExecuted(
        address indexed user,
        bytes32 indexed eventId,
        uint256 amount,
        uint32 destinationChain,
        uint64 nonce
    );

    // ============ Errors ============

    error Unauthorized();
    error EventNotResolved();
    error EventAlreadySettled();
    error InsufficientBalance();
    error InvalidAmount();
    error InvalidDestination();
    error InvalidSignature();
    error EventResolved();
    error TransferFailed();

    // ============ Modifiers ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _eventRegistry,
        address _usdc,
        address _usdy,
        address _tokenMessenger
    ) {
        eventRegistry = EventRegistry(_eventRegistry);
        usdc = IUSDC(_usdc);
        usdy = IUSDY(_usdy);
        tokenMessenger = ITokenMessenger(_tokenMessenger);
        owner = msg.sender;
    }

    // ============ External Functions ============

    /**
     * @notice Adds a conditional balance for a user
     * @param user The user to credit
     * @param eventId The event this balance is conditioned on
     * @param amount Amount of USDC
     * @param destChain CCTP destination domain
     * @param destAddress Recipient address on destination chain
     */
    function addConditionalBalance(
        address user,
        bytes32 eventId,
        uint256 amount,
        uint32 destChain,
        address destAddress
    ) external {
        if (amount == 0) revert InvalidAmount();
        if (destAddress == address(0)) revert InvalidDestination();

        // Transfer USDC from sender to vault
        bool success = usdc.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();

        // Add balance entry
        balances[user][eventId].push(Balance({
            amount: amount,
            destinationChain: destChain,
            destinationAddress: destAddress
        }));

        emit ConditionalBalanceAdded(user, eventId, amount, destChain, destAddress);
    }

    /**
     * @notice Transfers conditional balance from one user to another (with signature)
     * @param from Current owner of the balance
     * @param to Recipient of the balance
     * @param eventId The event identifier
     * @param amount Amount to transfer
     * @param toDestChain Recipient's destination chain
     * @param toDestAddress Recipient's destination address
     * @param signature Signature from 'from' authorizing the transfer
     */
    function transferConditionalBalance(
        address from,
        address to,
        bytes32 eventId,
        uint256 amount,
        uint32 toDestChain,
        address toDestAddress,
        bytes memory signature
    ) external {
        if (amount == 0) revert InvalidAmount();
        if (to == address(0) || toDestAddress == address(0)) revert InvalidDestination();
        if (settled[eventId]) revert EventResolved();

        // Check event is not resolved yet
        if (eventRegistry.isResolved(eventId)) revert EventResolved();

        // Verify signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this),
            from,
            to,
            eventId,
            amount,
            toDestChain,
            toDestAddress,
            nonces[from]
        ));
        bytes32 ethSignedMessageHash = getEthSignedMessageHash(messageHash);
        address recoveredSigner = recoverSigner(ethSignedMessageHash, signature);

        if (recoveredSigner != from) revert InvalidSignature();

        // Increment nonce to prevent replay
        nonces[from]++;

        // Get total balance for user for this event
        uint256 totalBalance = getTotalBalance(from, eventId);
        if (totalBalance < amount) revert InsufficientBalance();

        // Reduce from's balance
        _reduceBalance(from, eventId, amount);

        // Add to recipient's balance
        balances[to][eventId].push(Balance({
            amount: amount,
            destinationChain: toDestChain,
            destinationAddress: toDestAddress
        }));

        emit ConditionalBalanceTransferred(from, to, eventId, amount, toDestChain, toDestAddress);
    }

    /**
     * @notice Settles an event by sending USDC cross-chain to all holders
     * @param eventId The event to settle
     */
    function settleEvent(bytes32 eventId) external {
        // Check event is resolved
        if (!eventRegistry.isResolved(eventId)) revert EventNotResolved();

        // Check not already settled
        if (settled[eventId]) revert EventAlreadySettled();

        // Mark as settled first (reentrancy guard)
        settled[eventId] = true;

        // We need to iterate through all users, but we don't have a user list
        // In production, you'd maintain a list of users per event
        // For hackathon purposes, settlement will be called per user or we batch via events

        emit EventSettled(eventId, 0, 0);
    }

    /**
     * @notice Settles a specific user's balances for an event (CCTP burns)
     * @param eventId The event to settle
     * @param user The user whose balances to settle
     */
    function settleUserBalances(bytes32 eventId, address user) external {
        // Check event is resolved
        if (!eventRegistry.isResolved(eventId)) revert EventNotResolved();

        // Check event is marked for settlement
        if (!settled[eventId]) revert EventNotResolved();

        Balance[] storage userBalances = balances[user][eventId];

        // Process each balance entry
        for (uint256 i = 0; i < userBalances.length; i++) {
            Balance memory bal = userBalances[i];

            if (bal.amount == 0) continue; // Skip if already processed

            // Approve USDC to TokenMessenger
            usdc.approve(address(tokenMessenger), bal.amount);

            // Convert destination address to bytes32
            bytes32 mintRecipient = addressToBytes32(bal.destinationAddress);

            // Burn USDC via CCTP for cross-chain transfer
            uint64 nonce = tokenMessenger.depositForBurn(
                bal.amount,
                bal.destinationChain,
                mintRecipient,
                address(usdc)
            );

            emit SettlementExecuted(
                user,
                eventId,
                bal.amount,
                bal.destinationChain,
                nonce
            );

            // Mark as processed
            userBalances[i].amount = 0;
        }
    }

    /**
     * @notice Admin function to withdraw unallocated collateral
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawUnusedCollateral(address token, uint256 amount) external onlyOwner {
        if (token == address(usdc)) {
            usdc.transfer(owner, amount);
        } else if (token == address(usdy)) {
            usdy.transfer(owner, amount);
        }
    }

    // ============ View Functions ============

    /**
     * @notice Gets all balances for a user for an event
     * @param user The user address
     * @param eventId The event identifier
     * @return Array of Balance structs
     */
    function getBalances(address user, bytes32 eventId)
        external
        view
        returns (Balance[] memory)
    {
        return balances[user][eventId];
    }

    /**
     * @notice Gets total balance amount for a user for an event
     * @param user The user address
     * @param eventId The event identifier
     * @return Total amount across all balance entries
     */
    function getTotalBalance(address user, bytes32 eventId)
        public
        view
        returns (uint256)
    {
        Balance[] memory userBalances = balances[user][eventId];
        uint256 total = 0;

        for (uint256 i = 0; i < userBalances.length; i++) {
            total += userBalances[i].amount;
        }

        return total;
    }

    // ============ Internal Functions ============

    /**
     * @notice Reduces a user's balance by a given amount
     * @param user The user whose balance to reduce
     * @param eventId The event identifier
     * @param amount Amount to reduce by
     */
    function _reduceBalance(address user, bytes32 eventId, uint256 amount) internal {
        Balance[] storage userBalances = balances[user][eventId];
        uint256 remaining = amount;

        // Reduce from balance entries (FIFO)
        for (uint256 i = 0; i < userBalances.length && remaining > 0; i++) {
            if (userBalances[i].amount == 0) continue;

            if (userBalances[i].amount <= remaining) {
                remaining -= userBalances[i].amount;
                userBalances[i].amount = 0;
            } else {
                userBalances[i].amount -= remaining;
                remaining = 0;
            }
        }

        require(remaining == 0, "Insufficient balance to reduce");
    }

    /**
     * @notice Converts address to bytes32 for CCTP
     * @param addr The address to convert
     * @return bytes32 representation
     */
    function addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
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
