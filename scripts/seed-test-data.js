const hre = require("hardhat");
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  console.log("🌱 Seeding test data...\n");

  const [deployer] = await ethers.getSigners();

  // Load deployment
  const deploymentsDir = path.join(__dirname, "../deployments");
  const files = fs.readdirSync(deploymentsDir);
  const latestFile = files
    .filter(f => f.endsWith('.json'))
    .sort()
    .reverse()[0];

  const deployment = JSON.parse(fs.readFileSync(path.join(deploymentsDir, latestFile), 'utf8'));
  const contracts = deployment.contracts;

  console.log("📄 Using deployment:", latestFile, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 1. SEED ORACLE PRICES
  // ═══════════════════════════════════════════════════════════════════════

  console.log("1. Seeding Oracle Prices...\n");

  const cryptoOracle = await ethers.getContractAt("CryptoPriceOracle", contracts.cryptoOracle);
  
  // BTC/USD
  console.log("  - Setting BTC/USD: $45,000");
  await cryptoOracle.updatePrice(
    ethers.keccak256(ethers.toUtf8Bytes("BTC/USD")),
    45000_00000000n,
    50
  );

  // ETH/USD
  console.log("  - Setting ETH/USD: $2,500");
  await cryptoOracle.updatePrice(
    ethers.keccak256(ethers.toUtf8Bytes("ETH/USD")),
    2500_00000000n,
    50
  );

  // SOL/USD
  console.log("  - Setting SOL/USD: $100");
  await cryptoOracle.updatePrice(
    ethers.keccak256(ethers.toUtf8Bytes("SOL/USD")),
    100_00000000n,
    50
  );

  console.log("✅ Crypto prices seeded\n");

  // Stock Oracle
  const stockOracle = await ethers.getContractAt("StockPriceOracle", contracts.stockOracle);
  
  console.log("  - Setting AAPL/USD: $175");
  await stockOracle.updateStockPrice(
    ethers.keccak256(ethers.toUtf8Bytes("AAPL/USD")),
    175_00000000n,
    50,
    1000000n,
    true
  );

  console.log("  - Setting TSLA/USD: $250");
  await stockOracle.updateStockPrice(
    ethers.keccak256(ethers.toUtf8Bytes("TSLA/USD")),
    250_00000000n,
    50,
    2000000n,
    true
  );

  console.log("✅ Stock prices seeded\n");

  // Forex Oracle
  const forexOracle = await ethers.getContractAt("ForexPriceOracle", contracts.forexOracle);
  
  console.log("  - Setting EUR/USD: 1.08");
  await forexOracle.updateForexPrice(
    ethers.keccak256(ethers.toUtf8Bytes("EUR/USD")),
    1_08000000n,
    1_08050000n,
    10,
    1000000n
  );

  console.log("  - Setting GBP/USD: 1.25");
  await forexOracle.updateForexPrice(
    ethers.keccak256(ethers.toUtf8Bytes("GBP/USD")),
    1_25000000n,
    1_25050000n,
    10,
    800000n
  );

  console.log("✅ Forex prices seeded\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 2. ADD TEST OPERATORS
  // ═══════════════════════════════════════════════════════════════════════

  console.log("2. Adding test operators...");
  const operatorRegistry = await ethers.getContractAt("OperatorRegistry", contracts.operatorRegistry);
  
  // Deployer is already an operator, add metadata
  console.log("  - Operator:", deployer.address);
  console.log("✅ Operators configured\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 3. INITIALIZE DEFAULT TIER CONFIGURATIONS
  // ═══════════════════════════════════════════════════════════════════════

  console.log("3. Tier configurations already initialized during deployment");
  const traderRegistry = await ethers.getContractAt("TraderAccountRegistry", contracts.traderRegistry);
  
  const tier1 = await traderRegistry.getTierConfig(1);
  console.log("  - Tier 1:", ethers.formatEther(tier1.capitalAllocation), "USD allocation");
  
  const tier2 = await traderRegistry.getTierConfig(2);
  console.log("  - Tier 2:", ethers.formatEther(tier2.capitalAllocation), "USD allocation");
  
  console.log("✅ Tier configs verified\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 4. SUBMIT TEST BATCH
  // ═══════════════════════════════════════════════════════════════════════

  console.log("4. Submitting test settlement batch...");
  const tradeLedger = await ethers.getContractAt("TradeLedger", contracts.tradeLedger);
  
  const batchHash = ethers.keccak256(ethers.toUtf8Bytes("test_batch_1"));
  const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("test_root_1"));
  const tradeCount = 10;
  const metadata = "ipfs://QmTestBatch1";
  const volume = ethers.parseEther("100000");
  const pnl = ethers.parseEther("5000");

  await tradeLedger.submitBatch(
    batchHash,
    merkleRoot,
    tradeCount,
    metadata,
    volume,
    pnl
  );

  console.log("  - Batch submitted with 10 trades");
  console.log("  - Volume:", ethers.formatEther(volume), "USD");
  console.log("  - PnL:", ethers.formatEther(pnl), "USD");
  console.log("✅ Test batch created\n");

  console.log("✅ Test data seeding complete!");
  console.log("\n📊 System is ready for testing with:");
  console.log("- Live oracle prices (BTC, ETH, SOL, AAPL, TSLA, EUR/USD, GBP/USD)");
  console.log("- Configured operators");
  console.log("- Default tier configurations");
  console.log("- Sample settlement batch");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
