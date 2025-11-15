// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/EventRegistry.sol";
import "../contracts/ConditionalVault.sol";
import "../contracts/CrossChainSettlementHandler.sol";

// Mock USDC for testing
contract MockUSDC {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balances[from] >= amount, "Insufficient balance");
        require(allowances[from][msg.sender] >= amount, "Insufficient allowance");
        balances[from] -= amount;
        balances[to] += amount;
        allowances[from][msg.sender] -= amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }
}

// Mock TokenMessenger for testing
contract MockTokenMessenger {
    uint64 public nonce = 0;

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64) {
        // Mock: Just increment nonce
        nonce++;
        return nonce;
    }

    function depositForBurnWithCaller(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller
    ) external returns (uint64) {
        nonce++;
        return nonce;
    }
}

/**
 * @title SettlementTest
 * @notice Tests for conditional balance management, transfers, and settlement
 */
contract SettlementTest is Test {
    EventRegistry public registry;
    ConditionalVault public vault;
    MockUSDC public usdc;
    MockTokenMessenger public tokenMessenger;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public oracle1 = address(0x1);
    address public oracle2 = address(0x2);

    bytes32 public eventId = keccak256("ETH > 5000");

    function setUp() public {
        // Deploy contracts
        usdc = new MockUSDC();
        tokenMessenger = new MockTokenMessenger();
        registry = new EventRegistry();
        vault = new ConditionalVault(
            address(registry),
            address(usdc),
            address(0), // No USDY for simplicity
            address(tokenMessenger)
        );

        // Mint USDC to users
        usdc.mint(alice, 10000e6);
        usdc.mint(bob, 10000e6);

        // Create event
        address[] memory signers = new address[](2);
        signers[0] = oracle1;
        signers[1] = oracle2;
        registry.createEvent(eventId, signers, 2);
    }

    // ============ Add Balance Tests ============

    function testAddConditionalBalance() public {
        uint256 amount = 1000e6;

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.addConditionalBalance(alice, eventId, amount, 0, alice);
        vm.stopPrank();

        ConditionalVault.Balance[] memory balances = vault.getBalances(alice, eventId);
        assertEq(balances.length, 1);
        assertEq(balances[0].amount, amount);
        assertEq(balances[0].destinationChain, 0);
        assertEq(balances[0].destinationAddress, alice);
    }

    function testAddMultipleBalances() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 2000e6);

        vault.addConditionalBalance(alice, eventId, 1000e6, 0, alice);
        vault.addConditionalBalance(alice, eventId, 500e6, 10, alice);

        vm.stopPrank();

        ConditionalVault.Balance[] memory balances = vault.getBalances(alice, eventId);
        assertEq(balances.length, 2);
        assertEq(balances[0].amount, 1000e6);
        assertEq(balances[1].amount, 500e6);
    }

    function testGetTotalBalance() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 2000e6);

        vault.addConditionalBalance(alice, eventId, 1000e6, 0, alice);
        vault.addConditionalBalance(alice, eventId, 500e6, 10, alice);

        vm.stopPrank();

        uint256 total = vault.getTotalBalance(alice, eventId);
        assertEq(total, 1500e6);
    }

    // ============ Transfer Balance Tests ============

    function testTransferConditionalBalance() public {
        // Alice adds balance
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.addConditionalBalance(alice, eventId, 1000e6, 0, alice);
        vm.stopPrank();

        // Alice transfers 400 to Bob
        uint256 transferAmount = 400e6;
        uint256 nonce = vault.nonces(alice);

        bytes32 messageHash = keccak256(abi.encodePacked(
            address(vault),
            alice,
            bob,
            eventId,
            transferAmount,
            uint32(10), // Bob's destination chain
            bob, // Bob's destination address
            nonce
        ));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        // Sign with Alice's key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(uint160(alice)), ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Execute transfer
        vault.transferConditionalBalance(alice, bob, eventId, transferAmount, 10, bob, signature);

        // Verify balances
        assertEq(vault.getTotalBalance(alice, eventId), 600e6);
        assertEq(vault.getTotalBalance(bob, eventId), 400e6);

        // Verify nonce incremented
        assertEq(vault.nonces(alice), nonce + 1);
    }

    function testTransferRevertsOnInvalidSignature() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.addConditionalBalance(alice, eventId, 1000e6, 0, alice);
        vm.stopPrank();

        // Bob tries to sign (not Alice!)
        uint256 nonce = vault.nonces(alice);
        bytes32 messageHash = keccak256(abi.encodePacked(
            address(vault),
            alice,
            bob,
            eventId,
            uint256(400e6),
            uint32(10),
            bob,
            nonce
        ));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(uint160(bob)), ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ConditionalVault.InvalidSignature.selector);
        vault.transferConditionalBalance(alice, bob, eventId, 400e6, 10, bob, signature);
    }

    function testTransferRevertsOnInsufficientBalance() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 500e6);
        vault.addConditionalBalance(alice, eventId, 500e6, 0, alice);
        vm.stopPrank();

        // Try to transfer more than balance
        uint256 nonce = vault.nonces(alice);
        bytes32 messageHash = keccak256(abi.encodePacked(
            address(vault),
            alice,
            bob,
            eventId,
            uint256(1000e6), // More than Alice has!
            uint32(10),
            bob,
            nonce
        ));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(uint160(alice)), ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ConditionalVault.InsufficientBalance.selector);
        vault.transferConditionalBalance(alice, bob, eventId, 1000e6, 10, bob, signature);
    }

    function testTransferRevertsAfterResolution() public {
        // Add balance
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.addConditionalBalance(alice, eventId, 1000e6, 0, alice);
        vm.stopPrank();

        // Resolve event
        bytes memory resolutionBytes = abi.encode(true);
        bytes32 msgHash = keccak256(abi.encodePacked(address(registry), eventId, resolutionBytes));
        bytes32 ethSignedMsgHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash)
        );

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(1, ethSignedMsgHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(2, ethSignedMsgHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        registry.resolveEvent(eventId, signatures, resolutionBytes);

        // Try to transfer after resolution
        uint256 nonce = vault.nonces(alice);
        bytes32 transferHash = keccak256(abi.encodePacked(
            address(vault),
            alice,
            bob,
            eventId,
            uint256(400e6),
            uint32(10),
            bob,
            nonce
        ));
        bytes32 ethSignedTransferHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", transferHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(uint160(alice)), ethSignedTransferHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ConditionalVault.EventResolved.selector);
        vault.transferConditionalBalance(alice, bob, eventId, 400e6, 10, bob, signature);
    }

    function testTransferPreventsReplay() public {
        // Add balance
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.addConditionalBalance(alice, eventId, 1000e6, 0, alice);
        vm.stopPrank();

        // First transfer
        uint256 nonce = vault.nonces(alice);
        bytes32 messageHash = keccak256(abi.encodePacked(
            address(vault),
            alice,
            bob,
            eventId,
            uint256(400e6),
            uint32(10),
            bob,
            nonce
        ));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(uint160(alice)), ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vault.transferConditionalBalance(alice, bob, eventId, 400e6, 10, bob, signature);

        // Try to replay same signature
        vm.expectRevert(ConditionalVault.InvalidSignature.selector);
        vault.transferConditionalBalance(alice, bob, eventId, 400e6, 10, bob, signature);
    }

    // ============ Settlement Tests ============

    function testSettleEvent() public {
        // Add balances
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.addConditionalBalance(alice, eventId, 1000e6, 0, alice);
        vm.stopPrank();

        // Resolve event
        bytes memory resolutionBytes = abi.encode(true);
        bytes32 msgHash = keccak256(abi.encodePacked(address(registry), eventId, resolutionBytes));
        bytes32 ethSignedMsgHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash)
        );

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(1, ethSignedMsgHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(2, ethSignedMsgHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        registry.resolveEvent(eventId, signatures, resolutionBytes);

        // Settle
        vault.settleEvent(eventId);
        assertTrue(vault.settled(eventId));
    }

    function testSettleUserBalances() public {
        // Add balance
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.addConditionalBalance(alice, eventId, 1000e6, 0, alice);
        vm.stopPrank();

        // Resolve and mark for settlement
        bytes memory resolutionBytes = abi.encode(true);
        bytes32 msgHash = keccak256(abi.encodePacked(address(registry), eventId, resolutionBytes));
        bytes32 ethSignedMsgHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash)
        );

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(1, ethSignedMsgHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(2, ethSignedMsgHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        registry.resolveEvent(eventId, signatures, resolutionBytes);
        vault.settleEvent(eventId);

        // Settle user balances
        vault.settleUserBalances(eventId, alice);

        // Balances should be zeroed out
        ConditionalVault.Balance[] memory balances = vault.getBalances(alice, eventId);
        assertEq(balances[0].amount, 0);
    }

    function testSettleRevertsBeforeResolution() public {
        vm.expectRevert(ConditionalVault.EventNotResolved.selector);
        vault.settleEvent(eventId);
    }

    function testSettleRevertsOnDouble() public {
        // Resolve event
        bytes memory resolutionBytes = abi.encode(true);
        bytes32 msgHash = keccak256(abi.encodePacked(address(registry), eventId, resolutionBytes));
        bytes32 ethSignedMsgHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash)
        );

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(1, ethSignedMsgHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(2, ethSignedMsgHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        registry.resolveEvent(eventId, signatures, resolutionBytes);

        vault.settleEvent(eventId);

        vm.expectRevert(ConditionalVault.EventAlreadySettled.selector);
        vault.settleEvent(eventId);
    }

    // ============ Integration Test ============

    function testFullFlowWithTransfer() public {
        // 1. Alice and Bob add balances
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.addConditionalBalance(alice, eventId, 1000e6, 0, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), 500e6);
        vault.addConditionalBalance(bob, eventId, 500e6, 10, bob);
        vm.stopPrank();

        // 2. Alice transfers 400 to Bob
        uint256 nonce = vault.nonces(alice);
        bytes32 transferHash = keccak256(abi.encodePacked(
            address(vault),
            alice,
            bob,
            eventId,
            uint256(400e6),
            uint32(10),
            bob,
            nonce
        ));
        bytes32 ethSignedTransferHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", transferHash)
        );
        (uint8 vt, bytes32 rt, bytes32 st) = vm.sign(uint256(uint160(alice)), ethSignedTransferHash);
        vault.transferConditionalBalance(alice, bob, eventId, 400e6, 10, bob, abi.encodePacked(rt, st, vt));

        // Verify intermediate state
        assertEq(vault.getTotalBalance(alice, eventId), 600e6);
        assertEq(vault.getTotalBalance(bob, eventId), 900e6);

        // 3. Resolve event
        bytes memory resolutionBytes = abi.encode(true);
        bytes32 msgHash = keccak256(abi.encodePacked(address(registry), eventId, resolutionBytes));
        bytes32 ethSignedMsgHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash)
        );
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(1, ethSignedMsgHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(2, ethSignedMsgHash);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        registry.resolveEvent(eventId, signatures, resolutionBytes);

        // 4. Settle
        vault.settleEvent(eventId);
        vault.settleUserBalances(eventId, alice);
        vault.settleUserBalances(eventId, bob);

        // Verify settlement
        assertTrue(vault.settled(eventId));
    }
}
