// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/EventRegistry.sol";

/**
 * @title EventRegistryTest
 * @notice Tests for EventRegistry contract
 */
contract EventRegistryTest is Test {
    EventRegistry public registry;

    address public oracle1 = address(0x1);
    address public oracle2 = address(0x2);
    address public oracle3 = address(0x3);

    bytes32 public eventId = keccak256("ETH > 5000");

    function setUp() public {
        registry = new EventRegistry();
    }

    // ============ Event Creation Tests ============

    function testCreateEvent() public {
        address[] memory signers = new address[](3);
        signers[0] = oracle1;
        signers[1] = oracle2;
        signers[2] = oracle3;

        registry.createEvent(eventId, signers, 2);

        EventRegistry.Event memory eventData = registry.getEvent(eventId);
        assertEq(eventData.id, eventId);
        assertEq(eventData.signers.length, 3);
        assertEq(eventData.threshold, 2);
        assertFalse(eventData.resolved);
    }

    function testCreateEventRevertsOnDuplicate() public {
        address[] memory signers = new address[](2);
        signers[0] = oracle1;
        signers[1] = oracle2;

        registry.createEvent(eventId, signers, 2);

        vm.expectRevert(EventRegistry.EventAlreadyExists.selector);
        registry.createEvent(eventId, signers, 2);
    }

    function testCreateEventRevertsOnInvalidThreshold() public {
        address[] memory signers = new address[](3);
        signers[0] = oracle1;
        signers[1] = oracle2;
        signers[2] = oracle3;

        vm.expectRevert(EventRegistry.InvalidThreshold.selector);
        registry.createEvent(eventId, signers, 0);

        vm.expectRevert(EventRegistry.InvalidThreshold.selector);
        registry.createEvent(eventId, signers, 4);
    }

    function testCreateEventRevertsOnEmptySigners() public {
        address[] memory signers = new address[](0);

        vm.expectRevert(EventRegistry.InvalidSigners.selector);
        registry.createEvent(eventId, signers, 1);
    }

    function testCreateEventRevertsOnDuplicateSigners() public {
        address[] memory signers = new address[](3);
        signers[0] = oracle1;
        signers[1] = oracle2;
        signers[2] = oracle1; // Duplicate!

        vm.expectRevert(EventRegistry.DuplicateSigner.selector);
        registry.createEvent(eventId, signers, 2);
    }

    // ============ Event Resolution Tests ============

    function testResolveEvent() public {
        // Create event
        address[] memory signers = new address[](3);
        signers[0] = oracle1;
        signers[1] = oracle2;
        signers[2] = oracle3;
        registry.createEvent(eventId, signers, 2);

        // Prepare resolution
        bytes memory resolutionBytes = abi.encode(true);
        bytes32 messageHash = keccak256(abi.encodePacked(address(registry), eventId, resolutionBytes));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        // Sign with oracle1 and oracle2
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(1, ethSignedMessageHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(2, ethSignedMessageHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        // Resolve
        registry.resolveEvent(eventId, signatures, resolutionBytes);

        // Verify
        assertTrue(registry.isResolved(eventId));
        assertEq(registry.getResolution(eventId), resolutionBytes);
    }

    function testResolveEventRevertsOnNonExistent() public {
        bytes memory resolutionBytes = abi.encode(true);
        bytes[] memory signatures = new bytes[](2);

        vm.expectRevert(EventRegistry.EventDoesNotExist.selector);
        registry.resolveEvent(eventId, signatures, resolutionBytes);
    }

    function testResolveEventRevertsOnDoubleResolution() public {
        // Create and resolve event
        address[] memory signers = new address[](2);
        signers[0] = oracle1;
        signers[1] = oracle2;
        registry.createEvent(eventId, signers, 2);

        bytes memory resolutionBytes = abi.encode(true);
        bytes32 messageHash = keccak256(abi.encodePacked(address(registry), eventId, resolutionBytes));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(1, ethSignedMessageHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(2, ethSignedMessageHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        registry.resolveEvent(eventId, signatures, resolutionBytes);

        // Try to resolve again
        vm.expectRevert(EventRegistry.EventAlreadyResolved.selector);
        registry.resolveEvent(eventId, signatures, resolutionBytes);
    }

    function testResolveEventRevertsOnInsufficientSignatures() public {
        address[] memory signers = new address[](3);
        signers[0] = oracle1;
        signers[1] = oracle2;
        signers[2] = oracle3;
        registry.createEvent(eventId, signers, 3); // Need 3 signatures

        bytes memory resolutionBytes = abi.encode(true);
        bytes32 messageHash = keccak256(abi.encodePacked(address(registry), eventId, resolutionBytes));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(1, ethSignedMessageHash);

        bytes[] memory signatures = new bytes[](1); // Only 1 signature!
        signatures[0] = abi.encodePacked(r1, s1, v1);

        vm.expectRevert(EventRegistry.InsufficientSignatures.selector);
        registry.resolveEvent(eventId, signatures, resolutionBytes);
    }

    function testResolveEventRevertsOnInvalidSigner() public {
        address[] memory signers = new address[](2);
        signers[0] = oracle1;
        signers[1] = oracle2;
        registry.createEvent(eventId, signers, 2);

        bytes memory resolutionBytes = abi.encode(true);
        bytes32 messageHash = keccak256(abi.encodePacked(address(registry), eventId, resolutionBytes));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        // Sign with unauthorized oracle (private key 99)
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(99, ethSignedMessageHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(98, ethSignedMessageHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        vm.expectRevert(EventRegistry.InsufficientSignatures.selector);
        registry.resolveEvent(eventId, signatures, resolutionBytes);
    }

    function testResolveEventIgnoresDuplicateSignatures() public {
        address[] memory signers = new address[](2);
        signers[0] = oracle1;
        signers[1] = oracle2;
        registry.createEvent(eventId, signers, 2);

        bytes memory resolutionBytes = abi.encode(true);
        bytes32 messageHash = keccak256(abi.encodePacked(address(registry), eventId, resolutionBytes));
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(1, ethSignedMessageHash);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r1, s1, v1); // Same signature!

        // Should fail because duplicate is ignored
        vm.expectRevert(EventRegistry.InsufficientSignatures.selector);
        registry.resolveEvent(eventId, signatures, resolutionBytes);
    }
}
