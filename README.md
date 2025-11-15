# Arc Conditional Settlement Protocol (ACSP)

**Programmable conditional payouts with automatic cross-chain settlement via CCTP**

Built for the Arc blockchain hackathon.

---

## Overview

The Arc Conditional Settlement Protocol (ACSP) is a smart contract system that enables:

1. **Conditional Balances**: Users deposit USDC that's only paid out if a specific event occurs
2. **Oracle Resolution**: Events are resolved by M-of-N multisig oracles
3. **Transferable Positions**: Users can trade their conditional balances before resolution
4. **Automatic Cross-Chain Settlement**: On resolution, USDC is automatically sent cross-chain via Circle's CCTP to each user's specified destination

**No manual claim step required** - settlement happens automatically!

---

## Use Cases

- **Prediction Markets**: Bet on future events with automatic payouts
- **Insurance**: Parametric insurance with oracle-triggered settlements
- **Escrow**: Conditional payments based on real-world events
- **DeFi Primitives**: Building blocks for more complex financial products

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Arc Blockchain                        │
│                                                              │
│  ┌──────────────────┐         ┌─────────────────────────┐  │
│  │  EventRegistry   │◄────────┤  Oracle Signers (M-of-N) │  │
│  └────────┬─────────┘         └─────────────────────────┘  │
│           │                                                  │
│           │ Triggers Settlement                              │
│           ▼                                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │         ConditionalVault                              │  │
│  │  - Holds USDC collateral                              │  │
│  │  - Manages conditional balances                       │  │
│  │  - Supports balance transfers                         │  │
│  │  - Triggers CCTP burns on settlement                  │  │
│  └────────┬───────────────────────────────────────────────┘  │
│           │ CCTP depositForBurn()                            │
│           ▼                                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │     Circle CCTP (TokenMessenger)                      │  │
│  └────────┬───────────────────────────────────────────────┘  │
└───────────┼──────────────────────────────────────────────────┘
            │ Attestation (via resolver bot)
            ▼
┌─────────────────────────────────────────────────────────────┐
│        Destination Chain (Ethereum/Optimism/Base/etc)        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │   CrossChainSettlementHandler                         │  │
│  │   - Receives CCTP message                             │  │
│  │   - Transfers USDC to user                            │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## Contracts

### 1. EventRegistry.sol

Manages event definitions and oracle-based resolution.

**Key Functions**:
- `createEvent(bytes32 eventId, address[] signers, uint8 threshold)` - Create new event
- `resolveEvent(bytes32 eventId, bytes[] signatures, bytes resolutionBytes)` - Resolve with M-of-N multisig
- `isResolved(bytes32 eventId)` - Check if event is resolved

### 2. ConditionalVault.sol

Manages conditional balances, transfers, and CCTP settlement.

**Key Functions**:
- `addConditionalBalance(address user, bytes32 eventId, uint256 amount, uint32 destChain, address destAddress)` - Deposit USDC
- `transferConditionalBalance(...)` - Transfer balance to another user (with signature)
- `settleEvent(bytes32 eventId)` - Mark event for settlement
- `settleUserBalances(bytes32 eventId, address user)` - Execute CCTP burns for user

### 3. CrossChainSettlementHandler.sol

Receives CCTP messages and distributes USDC on destination chains.

**Key Functions**:
- `handleReceiveMessage(uint32 sourceDomain, bytes32 sender, bytes messageBody)` - CCTP receiver
- `recoverFunds(address token, address to, uint256 amount)` - Admin recovery

---

## Features

### Transferable Conditional Balances

Users can transfer their conditional positions to others **before** the event resolves.

**Example**:
```solidity
// Alice has 1000 USDC conditional on "ETH > $5000"
// She wants to sell 400 USDC worth to Bob for immediate liquidity

// 1. Alice signs a transfer message
uint256 nonce = vault.nonces(alice);
bytes32 hash = keccak256(abi.encodePacked(
    address(vault),
    alice,        // from
    bob,          // to
    eventId,
    400e6,        // amount
    10,           // Bob's destination chain (Optimism)
    bob,          // Bob's destination address
    nonce
));
bytes memory signature = alice.sign(hash);

// 2. Anyone can submit the transfer
vault.transferConditionalBalance(alice, bob, eventId, 400e6, 10, bob, signature);

// Result:
// - Alice: 600 USDC conditional balance
// - Bob: 400 USDC conditional balance
// - On resolution, Alice gets 600 on Ethereum, Bob gets 400 on Optimism
```

**Security**:
- Signature-based authorization
- Nonce prevents replay attacks
- Transfers locked after event resolution

---

## Installation

### Prerequisites

- Node.js 18+
- Foundry (for tests)
- Hardhat (for deployment)

### Setup

```bash
# Install dependencies
npm install

# Compile contracts
npx hardhat compile

# Run Foundry tests
forge test

# Run with verbose output
forge test -vvv
```

---

## Deployment

### 1. Configure Networks

Edit `hardhat.config.ts`:

```typescript
networks: {
  arc: {
    url: "https://arc-testnet-rpc-url",
    accounts: [PRIVATE_KEY],
  },
  sepolia: {
    url: "https://eth-sepolia-rpc-url",
    accounts: [PRIVATE_KEY],
  },
}
```

### 2. Update Configuration

Edit `scripts/deploy.ts` with Arc testnet addresses:

```typescript
const ARC_CONFIG = {
  USDC_ADDRESS: "0x...",           // Arc testnet USDC
  USDY_ADDRESS: "0x...",           // Arc testnet USDY (optional)
  TOKEN_MESSENGER: "0x...",        // Arc CCTP TokenMessenger
  MESSAGE_TRANSMITTER: "0x...",    // Arc MessageTransmitter
  CCTP_DOMAIN: 0,                  // Arc's CCTP domain ID
};
```

### 3. Deploy to Arc

```bash
npx hardhat run scripts/deploy.ts --network arc
```

This deploys:
- EventRegistry
- ConditionalVault

**Save the deployed addresses!**

### 4. Deploy CrossChainSettlementHandler on Destination Chains

Edit the handler deployment function in `scripts/deploy.ts` with the ConditionalVault address from step 3.

```bash
# Deploy on Ethereum Sepolia
npx hardhat run scripts/deploy.ts --network sepolia

# Deploy on Optimism Sepolia
npx hardhat run scripts/deploy.ts --network optimism-sepolia
```

---

## Usage

### Example Flow

```typescript
// 1. Create event
const eventId = ethers.id("ETH > $5000 by Dec 31, 2025");
await eventRegistry.createEvent(
  eventId,
  [oracle1.address, oracle2.address, oracle3.address],
  2  // 2-of-3 multisig
);

// 2. Alice deposits 1000 USDC
await usdc.connect(alice).approve(vaultAddress, 1000e6);
await vault.addConditionalBalance(
  alice.address,
  eventId,
  1000e6,
  0,  // Ethereum mainnet
  alice.address
);

// 3. Alice transfers 400 USDC to Bob
const nonce = await vault.nonces(alice.address);
const hash = keccak256(abi.encodePacked(
  vaultAddress, alice.address, bob.address,
  eventId, 400e6, 10, bob.address, nonce
));
const signature = await alice.signMessage(arrayify(hash));

await vault.transferConditionalBalance(
  alice.address, bob.address, eventId,
  400e6, 10, bob.address, signature
);

// 4. Oracles resolve event
const resolutionBytes = abi.encode(["bool"], [true]);
const msgHash = keccak256(abi.encodePacked(registryAddress, eventId, resolutionBytes));
const sig1 = await oracle1.signMessage(arrayify(msgHash));
const sig2 = await oracle2.signMessage(arrayify(msgHash));

await eventRegistry.resolveEvent(eventId, [sig1, sig2], resolutionBytes);

// 5. Settle event
await vault.settleEvent(eventId);
await vault.settleUserBalances(eventId, alice.address);
await vault.settleUserBalances(eventId, bob.address);

// 6. Resolver bot submits CCTP attestations
// (Off-chain process - attestations fetched from Circle API)
```

### Demo Script

Run the full demo:

```bash
npx hardhat run scripts/resolve_and_trigger.ts --network arc
```

---

## Testing

### Run All Tests

```bash
forge test
```

### Run Specific Tests

```bash
# Event tests only
forge test --match-contract EventRegistryTest

# Settlement tests only
forge test --match-contract SettlementTest

# Specific test function
forge test --match-test testTransferConditionalBalance -vvv
```

### Test Coverage

```bash
forge coverage
```

Expected coverage: >90% for all contracts

---

## Security Considerations

### Implemented Protections

✅ **Reentrancy Guards**: Settlement functions protected
✅ **Signature Validation**: ECDSA with EIP-191 prefix
✅ **Replay Prevention**: Nonces for transfers, contract address in signatures
✅ **Double Resolution**: Events can only be resolved once
✅ **Double Settlement**: Events can only be settled once
✅ **Access Control**: Owner functions protected
✅ **Input Validation**: Zero addresses, amounts, thresholds checked

### Known Limitations (Hackathon Scope)

⚠️ **User Enumeration**: Settlement requires knowing user addresses (event-based approach)
⚠️ **No Partial Resolution**: Events are all-or-nothing
⚠️ **No Dispute Mechanism**: Oracle decisions are final
⚠️ **Gas Costs**: Resolver pays destination gas for CCTP attestations
⚠️ **USDY Simplified**: Treated as 1:1 with USDC for demo purposes

### Audit Recommendations

Before production deployment:
- [ ] External security audit
- [ ] Economic modeling of incentives
- [ ] Gas optimization review
- [ ] Formal verification of core logic
- [ ] Stress testing with large user counts

---

## CCTP Integration

### How It Works

1. **On Arc (Source Chain)**:
   - Vault calls `TokenMessenger.depositForBurn(amount, destDomain, recipient, USDC)`
   - USDC is burned on Arc
   - CCTP emits event with attestation hash

2. **Off-Chain (Resolver Bot)**:
   - Monitor CCTP events
   - Fetch attestation from Circle API
   - Submit to destination chain

3. **On Destination Chain**:
   - Call `MessageTransmitter.receiveMessage(message, attestation)`
   - USDC is minted to CrossChainSettlementHandler
   - Handler forwards USDC to user

### Supported Chains

CCTP supports:
- Ethereum
- Avalanche
- Optimism
- Arbitrum
- Base
- Polygon PoS
- Solana

Check [Circle CCTP docs](https://developers.circle.com/stablecoins/docs/cctp-getting-started) for latest domains.

---

## Gas Optimization

### Strategies Used

1. **Packed Structs**: Balance struct fits in 3 slots
2. **Unchecked Math**: Where overflow is impossible
3. **Minimal Storage Writes**: Events for off-chain indexing
4. **Batch Settlement**: Per-user settlement to avoid iteration

### Estimated Gas Costs

| Operation | Gas Cost (est.) |
|-----------|-----------------|
| Create Event | ~100k |
| Add Balance | ~80k |
| Transfer Balance | ~60k |
| Resolve Event | ~150k (2 sigs) |
| Settle (per user) | ~100k + CCTP |

---

## Troubleshooting

### Common Issues

**Issue**: `EventNotResolved` error on settlement
- **Fix**: Ensure event is resolved first with `resolveEvent()`

**Issue**: `InvalidSignature` on transfer
- **Fix**: Check signature is from correct address and nonce matches

**Issue**: `InsufficientSignatures` on resolution
- **Fix**: Ensure enough valid oracle signatures provided

**Issue**: CCTP burn not appearing on destination
- **Fix**: Wait for attestation (6-12 confirmations), check Circle attestation API

---

## Architecture Decisions

### Why M-of-N Multisig?

Provides balance between:
- **Decentralization**: Multiple oracles required
- **Liveness**: Not all oracles need to be online
- **Flexibility**: Can configure per-event

### Why Transferable Balances?

Enables:
- **Secondary Markets**: Price discovery before resolution
- **Liquidity**: Early exit without waiting
- **Composability**: Balances as tradable assets

### Why Automatic Settlement?

- **UX**: No manual claim step
- **Atomicity**: All users settled together
- **Cross-Chain Native**: CCTP handles the complexity

---

## Future Enhancements

Potential improvements:
- [ ] User enumeration via events/indexing
- [ ] Partial resolution (multi-outcome events)
- [ ] Dispute period for oracle decisions
- [ ] Delegated settlement (anyone can trigger)
- [ ] ERC-1155 for tradable positions
- [ ] Integration with prediction market UI
- [ ] Gasless transfers via meta-transactions
- [ ] USDY yield distribution to holders

---

## Resources

- [Circle CCTP Documentation](https://developers.circle.com/stablecoins/docs/cctp-getting-started)
- [Arc Blockchain Docs](https://docs.arc.xyz) (TODO: Update with actual URL)
- [Foundry Book](https://book.getfoundry.sh/)
- [Hardhat Documentation](https://hardhat.org/docs)

---

## License

MIT License - see [LICENSE](LICENSE) file

---

## Contact

Built for Arc Hackathon 2025

For questions or issues:
- Open an issue on GitHub
- Join the Arc Discord
- Email: [bengtlofgren8@gmail.com]

---

## Acknowledgments

- Circle for CCTP infrastructure
- Arc team for blockchain platform
- OpenZeppelin for security patterns
- Foundry team for testing framework
