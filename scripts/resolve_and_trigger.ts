/**
 * Script to resolve events and trigger settlements
 *
 * This demonstrates the full flow:
 * 1. Create event
 * 2. Add conditional balances
 * 3. Transfer balances (optional)
 * 4. Resolve event with oracle signatures
 * 5. Settle event (trigger CCTP burns)
 */

import { ethers } from "hardhat";

// ============ Configuration ============

const DEPLOYED_ADDRESSES = {
  eventRegistry: "0x...", // TODO: Replace with deployed EventRegistry address
  vault: "0x...", // TODO: Replace with deployed ConditionalVault address
  usdc: "0x...", // TODO: Replace with USDC address
};

// ============ Helper Functions ============

/**
 * Creates an event with oracle configuration
 */
async function createEvent(
  eventRegistry: any,
  eventId: string,
  oracles: string[],
  threshold: number
) {
  console.log(`📋 Creating event: ${eventId}`);
  console.log(`   Oracles: ${oracles.join(", ")}`);
  console.log(`   Threshold: ${threshold} of ${oracles.length}`);

  const eventIdBytes = ethers.id(eventId);
  const tx = await eventRegistry.createEvent(eventIdBytes, oracles, threshold);
  await tx.wait();

  console.log("✅ Event created!");
  return eventIdBytes;
}

/**
 * Adds a conditional balance for a user
 */
async function addConditionalBalance(
  vault: any,
  usdc: any,
  user: any,
  eventId: string,
  amount: bigint,
  destChain: number,
  destAddress: string
) {
  console.log(`💰 Adding conditional balance for ${user.address}`);
  console.log(`   Amount: ${ethers.formatUnits(amount, 6)} USDC`);
  console.log(`   Destination: Chain ${destChain}, Address ${destAddress}`);

  // Approve USDC
  const approveTx = await usdc.connect(user).approve(await vault.getAddress(), amount);
  await approveTx.wait();

  // Add balance
  const tx = await vault.connect(user).addConditionalBalance(
    user.address,
    eventId,
    amount,
    destChain,
    destAddress
  );
  await tx.wait();

  console.log("✅ Balance added!");
}

/**
 * Transfers conditional balance from one user to another
 */
async function transferConditionalBalance(
  vault: any,
  from: any,
  to: any,
  eventId: string,
  amount: bigint,
  toDestChain: number,
  toDestAddress: string
) {
  console.log(`🔄 Transferring ${ethers.formatUnits(amount, 6)} USDC from ${from.address} to ${to.address}`);

  const vaultAddress = await vault.getAddress();
  const nonce = await vault.nonces(from.address);

  // Create message hash
  const messageHash = ethers.solidityPackedKeccak256(
    ["address", "address", "address", "bytes32", "uint256", "uint32", "address", "uint256"],
    [vaultAddress, from.address, to.address, eventId, amount, toDestChain, toDestAddress, nonce]
  );

  // Sign with EIP-191 prefix
  const signature = await from.signMessage(ethers.getBytes(messageHash));

  // Execute transfer
  const tx = await vault.transferConditionalBalance(
    from.address,
    to.address,
    eventId,
    amount,
    toDestChain,
    toDestAddress,
    signature
  );
  await tx.wait();

  console.log("✅ Transfer complete!");
}

/**
 * Resolves an event with M-of-N oracle signatures
 */
async function resolveEvent(
  eventRegistry: any,
  eventId: string,
  oracles: any[],
  threshold: number,
  resolutionData: any
) {
  console.log(`🔮 Resolving event with ${threshold} oracle signatures...`);

  const registryAddress = await eventRegistry.getAddress();
  const resolutionBytes = ethers.AbiCoder.defaultAbiCoder().encode(
    ["bool"],
    [resolutionData]
  );

  // Create message hash
  const messageHash = ethers.solidityPackedKeccak256(
    ["address", "bytes32", "bytes"],
    [registryAddress, eventId, resolutionBytes]
  );

  // Collect signatures from oracles
  const signatures: string[] = [];
  for (let i = 0; i < threshold; i++) {
    const signature = await oracles[i].signMessage(ethers.getBytes(messageHash));
    signatures.push(signature);
    console.log(`   ✓ Oracle ${i + 1} signed`);
  }

  // Submit resolution
  const tx = await eventRegistry.resolveEvent(eventId, signatures, resolutionBytes);
  await tx.wait();

  console.log("✅ Event resolved!");
}

/**
 * Settles an event and triggers CCTP burns
 */
async function settleEvent(vault: any, eventId: string, users: string[]) {
  console.log(`⚡ Settling event...`);

  // Mark event as settling
  let tx = await vault.settleEvent(eventId);
  await tx.wait();
  console.log("✅ Event marked for settlement");

  // Settle each user's balances
  for (const user of users) {
    console.log(`   💸 Settling balances for ${user}...`);
    tx = await vault.settleUserBalances(eventId, user);
    const receipt = await tx.wait();

    // Log CCTP nonces from events
    const events = receipt.logs;
    console.log(`   ✅ Settlement executed (${events.length} CCTP burns)`);
  }

  console.log("✅ All settlements complete!");
}

// ============ Main Demo Flow ============

async function main() {
  console.log("🎯 Arc Conditional Settlement Protocol - Demo Flow\n");

  const [deployer, oracle1, oracle2, oracle3, alice, bob] = await ethers.getSigners();

  // Connect to deployed contracts
  const eventRegistry = await ethers.getContractAt("EventRegistry", DEPLOYED_ADDRESSES.eventRegistry);
  const vault = await ethers.getContractAt("ConditionalVault", DEPLOYED_ADDRESSES.vault);
  const usdc = await ethers.getContractAt("IUSDC", DEPLOYED_ADDRESSES.usdc);

  console.log("📦 Connected to contracts:");
  console.log("   EventRegistry:", DEPLOYED_ADDRESSES.eventRegistry);
  console.log("   Vault:", DEPLOYED_ADDRESSES.vault);
  console.log("\n");

  // ============ Step 1: Create Event ============

  const eventId = await createEvent(
    eventRegistry,
    "ETH > $5000 by Dec 31, 2025",
    [oracle1.address, oracle2.address, oracle3.address],
    2 // 2-of-3 multisig
  );
  console.log("\n");

  // ============ Step 2: Add Conditional Balances ============

  // Alice deposits 1000 USDC
  await addConditionalBalance(
    vault,
    usdc,
    alice,
    eventId,
    ethers.parseUnits("1000", 6),
    0, // Ethereum mainnet
    alice.address
  );
  console.log("\n");

  // Bob deposits 500 USDC
  await addConditionalBalance(
    vault,
    usdc,
    bob,
    eventId,
    ethers.parseUnits("500", 6),
    10, // Optimism
    bob.address
  );
  console.log("\n");

  // ============ Step 3: Alice Transfers to Bob ============

  await transferConditionalBalance(
    vault,
    alice,
    bob,
    eventId,
    ethers.parseUnits("400", 6),
    10, // Optimism
    bob.address
  );
  console.log("   Alice now has 600 USDC, Bob has 900 USDC\n");

  // ============ Step 4: Resolve Event ============

  await resolveEvent(
    eventRegistry,
    eventId,
    [oracle1, oracle2, oracle3],
    2, // Need 2 signatures
    true // ETH did reach $5000
  );
  console.log("\n");

  // ============ Step 5: Settle Event ============

  await settleEvent(
    vault,
    eventId,
    [alice.address, bob.address]
  );
  console.log("\n");

  console.log("🎉 Demo complete!");
  console.log("\n📊 Final State:");
  console.log("   - Event resolved: TRUE");
  console.log("   - Alice: 600 USDC sent to Ethereum");
  console.log("   - Bob: 900 USDC sent to Optimism");
  console.log("\n✨ CCTP attestations must be submitted by resolver bot to complete cross-chain transfer");
}

// ============ Execute ============

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Script failed:", error);
    process.exit(1);
  });
