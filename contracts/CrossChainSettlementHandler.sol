// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IUSDC.sol";

/**
 * @title CrossChainSettlementHandler
 * @notice Receives CCTP messages and distributes USDC to users on destination chain
 * @dev Deployed on each destination chain (Ethereum, Optimism, Base, etc.)
 */
contract CrossChainSettlementHandler {

    // ============ State Variables ============

    /// @notice USDC token on this chain
    IUSDC public immutable usdc;

    /// @notice Circle's MessageTransmitter on this chain
    address public immutable messageTransmitter;

    /// @notice Trusted sender (ConditionalVault) on source chain (as bytes32)
    bytes32 public immutable trustedSender;

    /// @notice Source chain domain (Arc's CCTP domain ID)
    uint32 public immutable sourceDomain;

    /// @notice Contract owner
    address public owner;

    // ============ Events ============

    event SettlementReceived(
        address indexed recipient,
        uint256 amount,
        uint32 indexed sourceDomain,
        bytes32 indexed sender
    );

    event FundsRecovered(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    // ============ Errors ============

    error Unauthorized();
    error InvalidSender();
    error InvalidSourceDomain();
    error TransferFailed();

    // ============ Modifiers ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyMessageTransmitter() {
        if (msg.sender != messageTransmitter) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initializes the settlement handler
     * @param _usdc USDC token address on this chain
     * @param _messageTransmitter Circle's MessageTransmitter address
     * @param _trustedSender ConditionalVault address on source chain (as bytes32)
     * @param _sourceDomain CCTP domain ID for source chain (Arc)
     */
    constructor(
        address _usdc,
        address _messageTransmitter,
        bytes32 _trustedSender,
        uint32 _sourceDomain
    ) {
        usdc = IUSDC(_usdc);
        messageTransmitter = _messageTransmitter;
        trustedSender = _trustedSender;
        sourceDomain = _sourceDomain;
        owner = msg.sender;
    }

    // ============ External Functions ============

    /**
     * @notice Handles incoming CCTP message
     * @dev Called by Circle's MessageTransmitter after message attestation
     * @param sourceDomain_ The domain of the source chain
     * @param sender_ The sender on the source chain (should be ConditionalVault)
     * @param messageBody The message payload
     */
    function handleReceiveMessage(
        uint32 sourceDomain_,
        bytes32 sender_,
        bytes calldata messageBody
    ) external onlyMessageTransmitter returns (bool) {
        // Validate source domain
        if (sourceDomain_ != sourceDomain) revert InvalidSourceDomain();

        // Validate sender is trusted ConditionalVault
        if (sender_ != trustedSender) revert InvalidSender();

        // Decode message (recipient address, amount)
        (address recipient, uint256 amount) = abi.decode(messageBody, (address, uint256));

        // Transfer USDC to recipient
        // Note: USDC was already minted to this contract by CCTP
        bool success = usdc.transfer(recipient, amount);
        if (!success) revert TransferFailed();

        emit SettlementReceived(recipient, amount, sourceDomain_, sender_);

        return true;
    }

    /**
     * @notice Allows owner to recover stuck funds
     * @param token Token address to recover
     * @param to Recipient address
     * @param amount Amount to recover
     */
    function recoverFunds(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(usdc)) {
            usdc.transfer(to, amount);
        } else {
            // For other ERC20 tokens
            IUSDC(token).transfer(to, amount);
        }

        emit FundsRecovered(token, to, amount);
    }

    /**
     * @notice Updates the owner address
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }

    // ============ View Functions ============

    /**
     * @notice Gets the current USDC balance of this contract
     * @return USDC balance
     */
    function getBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
