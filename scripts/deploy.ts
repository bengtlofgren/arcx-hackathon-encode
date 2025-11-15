/**
 * Deployment script for Arc Conditional Settlement Protocol
 *
 * Deploys:
 * 1. EventRegistry
 * 2. ConditionalVault
 * 3. CrossChainSettlementHandler (on destination chains)
 */

import { ethers } from "hardhat";

// ============ Configuration ============

// Arc Testnet Configuration
const ARC_CONFIG = {
  USDC_ADDRESS: "0x...", // TODO: Replace with Arc testnet USDC address
  USDY_ADDRESS: "0x...", // TODO: Replace with Arc testnet USDY address (or mock)
  TOKEN_MESSENGER: "0x...", // TODO: Replace with Arc CCTP TokenMessenger
  MESSAGE_TRANSMITTER: "0x...", // TODO: Replace with Arc MessageTransmitter
  CCTP_DOMAIN: 0, // TODO: Replace with Arc's CCTP domain ID
};

// Destination Chain Configuration (e.g., Ethereum Sepolia)
const DESTINATION_CONFIG = {
  USDC_ADDRESS: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", // Sepolia USDC
  MESSAGE_TRANSMITTER: "0x7865fAfC2db2093669d92c0F33AeEF291086BEFD", // Sepolia MessageTransmitter
  CCTP_DOMAIN: 0, // Ethereum Sepolia
};

// ============ Main Deployment Function ============

async function main() {
  console.log("🚀 Starting Arc Conditional Settlement Protocol deployment...\n");

  const [deployer] = await ethers.getSigners();
  console.log("📝 Deploying with account:", deployer.address);
  console.log("💰 Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  // ============ Deploy EventRegistry ============

  console.log("📋 Deploying EventRegistry...");
  const EventRegistry = await ethers.getContractFactory("EventRegistry");
  const eventRegistry = await EventRegistry.deploy();
  await eventRegistry.waitForDeployment();
  const eventRegistryAddress = await eventRegistry.getAddress();
  console.log("✅ EventRegistry deployed to:", eventRegistryAddress);
  console.log();

  // ============ Deploy ConditionalVault ============

  console.log("🏦 Deploying ConditionalVault...");
  const ConditionalVault = await ethers.getContractFactory("ConditionalVault");
  const vault = await ConditionalVault.deploy(
    eventRegistryAddress,
    ARC_CONFIG.USDC_ADDRESS,
    ARC_CONFIG.USDY_ADDRESS,
    ARC_CONFIG.TOKEN_MESSENGER
  );
  await vault.waitForDeployment();
  const vaultAddress = await vault.getAddress();
  console.log("✅ ConditionalVault deployed to:", vaultAddress);
  console.log();

  // ============ Summary ============

  console.log("📊 ========== DEPLOYMENT SUMMARY ==========");
  console.log("Network:", (await ethers.provider.getNetwork()).name);
  console.log();
  console.log("Deployed Contracts:");
  console.log("  - EventRegistry:      ", eventRegistryAddress);
  console.log("  - ConditionalVault:   ", vaultAddress);
  console.log();
  console.log("Configuration:");
  console.log("  - USDC:              ", ARC_CONFIG.USDC_ADDRESS);
  console.log("  - USDY:              ", ARC_CONFIG.USDY_ADDRESS);
  console.log("  - TokenMessenger:    ", ARC_CONFIG.TOKEN_MESSENGER);
  console.log();
  console.log("🎉 Deployment complete!");
  console.log();

  // ============ Save Deployment Info ============

  const deploymentInfo = {
    network: (await ethers.provider.getNetwork()).name,
    chainId: (await ethers.provider.getNetwork()).chainId,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      EventRegistry: eventRegistryAddress,
      ConditionalVault: vaultAddress,
    },
    config: ARC_CONFIG,
  };

  console.log("💾 Deployment info:");
  console.log(JSON.stringify(deploymentInfo, null, 2));
  console.log();

  // ============ Verification Instructions ============

  console.log("📝 To verify on block explorer:");
  console.log();
  console.log("EventRegistry:");
  console.log(`  npx hardhat verify --network <network> ${eventRegistryAddress}`);
  console.log();
  console.log("ConditionalVault:");
  console.log(`  npx hardhat verify --network <network> ${vaultAddress} \\`);
  console.log(`    "${eventRegistryAddress}" \\`);
  console.log(`    "${ARC_CONFIG.USDC_ADDRESS}" \\`);
  console.log(`    "${ARC_CONFIG.USDY_ADDRESS}" \\`);
  console.log(`    "${ARC_CONFIG.TOKEN_MESSENGER}"`);
  console.log();
}

// ============ Deploy Destination Chain Handler ============

async function deployDestinationHandler() {
  console.log("🌉 Deploying CrossChainSettlementHandler on destination chain...\n");

  const [deployer] = await ethers.getSigners();
  console.log("📝 Deploying with account:", deployer.address);

  // You need to provide the ConditionalVault address from Arc as bytes32
  const vaultAddressFromArc = "0x..."; // TODO: Replace with deployed ConditionalVault address
  const trustedSender = ethers.zeroPadValue(vaultAddressFromArc, 32);

  console.log("🏗️ Deploying CrossChainSettlementHandler...");
  const Handler = await ethers.getContractFactory("CrossChainSettlementHandler");
  const handler = await Handler.deploy(
    DESTINATION_CONFIG.USDC_ADDRESS,
    DESTINATION_CONFIG.MESSAGE_TRANSMITTER,
    trustedSender,
    ARC_CONFIG.CCTP_DOMAIN // Arc's domain ID
  );
  await handler.waitForDeployment();
  const handlerAddress = await handler.getAddress();
  console.log("✅ CrossChainSettlementHandler deployed to:", handlerAddress);
  console.log();

  console.log("📊 ========== HANDLER DEPLOYMENT SUMMARY ==========");
  console.log("Network:", (await ethers.provider.getNetwork()).name);
  console.log("Handler Address:", handlerAddress);
  console.log("Trusted Sender (Vault):", vaultAddressFromArc);
  console.log("Source Domain (Arc):", ARC_CONFIG.CCTP_DOMAIN);
  console.log();

  console.log("📝 To verify:");
  console.log(`  npx hardhat verify --network <network> ${handlerAddress} \\`);
  console.log(`    "${DESTINATION_CONFIG.USDC_ADDRESS}" \\`);
  console.log(`    "${DESTINATION_CONFIG.MESSAGE_TRANSMITTER}" \\`);
  console.log(`    "${trustedSender}" \\`);
  console.log(`    ${ARC_CONFIG.CCTP_DOMAIN}`);
  console.log();
}

// ============ Execute ============

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  });

// Export for separate destination deployment
export { deployDestinationHandler };
