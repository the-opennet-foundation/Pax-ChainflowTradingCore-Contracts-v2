const hre = require("hardhat");
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  console.log("🚀 Starting ChainFlow-v2 Deployment (VERIFIED VERSION)...\n");

  const [deployer] = await ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  const deployments = {};
  const network = hre.network.name;

  // ═══════════════════════════════════════════════════════════════════════
  // 1. DEPLOY CORE CONTRACTS
  // ═══════════════════════════════════════════════════════════════════════

  console.log("📦 Deploying Core Contracts...\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 1/9: OperatorRegistry
  // initialize(admin, governance, operators[], metadata[])
  // ═══════════════════════════════════════════════════════════════════════
  console.log("1/15 Deploying OperatorRegistry...");
  const OperatorRegistry = await ethers.getContractFactory("OperatorRegistry");
  const operatorRegistry = await upgrades.deployProxy(OperatorRegistry, [
    deployer.address,           // _admin
    deployer.address,           // _governance
    [deployer.address],         // _initialOperators
    ["Primary Operator"]        // _operatorMetadata
  ]);
  await operatorRegistry.waitForDeployment();
  deployments.operatorRegistry = await operatorRegistry.getAddress();
  console.log("✅ OperatorRegistry:", deployments.operatorRegistry, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 2/9: Vault (FIXED: Need 2 guardians for 2 required approvals)
  // initialize(guardians[], requiredApprovals, admin, governance)
  // ═══════════════════════════════════════════════════════════════════════
  console.log("2/15 Deploying Vault...");
  const Vault = await ethers.getContractFactory("Vault");
  const vault = await upgrades.deployProxy(Vault, [
    [deployer.address, deployer.address], // _guardians (2 guardians)
    2,                                     // _requiredApprovals
    deployer.address,                      // _admin
    deployer.address                       // _governance
  ]);
  await vault.waitForDeployment();
  deployments.vault = await vault.getAddress();
  console.log("✅ Vault:", deployments.vault, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 3/9: CapitalPool
  // initialize(depositToken, admin, governance) - 3 PARAMS ONLY!
  // ═══════════════════════════════════════════════════════════════════════
  console.log("3/15 Deploying CapitalPool...");
  const CapitalPool = await ethers.getContractFactory("CapitalPool");
  const capitalPool = await upgrades.deployProxy(CapitalPool, [
    "0xb74737f617A7a6aC0699A9c668a23FFFd96f67e4", // USDT from .env
    deployer.address,           // _admin
    deployer.address            // _governance
  ]);
  await capitalPool.waitForDeployment();
  deployments.capitalPool = await capitalPool.getAddress();
  console.log("✅ CapitalPool:", deployments.capitalPool, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 4/9: TraderAccountRegistry
  // initialize(admin, governance, operators[])
  // ═══════════════════════════════════════════════════════════════════════
  console.log("4/15 Deploying TraderAccountRegistry...");
  const TraderAccountRegistry = await ethers.getContractFactory("TraderAccountRegistry");
  const traderRegistry = await upgrades.deployProxy(TraderAccountRegistry, [
    deployer.address,           // _admin
    deployer.address,           // _governance
    [deployer.address]          // _operators
  ]);
  await traderRegistry.waitForDeployment();
  deployments.traderRegistry = await traderRegistry.getAddress();
  console.log("✅ TraderAccountRegistry:", deployments.traderRegistry, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 5/9: TradeLedger
  // initialize(admin, governance, operators[])
  // ═══════════════════════════════════════════════════════════════════════
  console.log("5/15 Deploying TradeLedger...");
  const TradeLedger = await ethers.getContractFactory("TradeLedger");
  const tradeLedger = await upgrades.deployProxy(TradeLedger, [
    deployer.address,           // _admin
    deployer.address,           // _governance
    [deployer.address]          // _operators
  ]);
  await tradeLedger.waitForDeployment();
  deployments.tradeLedger = await tradeLedger.getAddress();
  console.log("✅ TradeLedger:", deployments.tradeLedger, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 6/9: PayoutManager
  // initialize(admin, governance, operators[], tradeLedger, traderRegistry, capitalPool)
  // ═══════════════════════════════════════════════════════════════════════
  console.log("6/15 Deploying PayoutManager...");
  const PayoutManager = await ethers.getContractFactory("PayoutManager");
  const payoutManager = await upgrades.deployProxy(PayoutManager, [
    deployer.address,           // _admin
    deployer.address,           // _governance
    [deployer.address],         // _operators
    deployments.tradeLedger,    // _tradeLedger
    deployments.traderRegistry, // _traderRegistry
    deployments.capitalPool     // _capitalPool
  ]);
  await payoutManager.waitForDeployment();
  deployments.payoutManager = await payoutManager.getAddress();
  console.log("✅ PayoutManager:", deployments.payoutManager, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 7/9: GovernanceManager
  // initialize(admin, emergency, proposers[], executors[])
  // ═══════════════════════════════════════════════════════════════════════
  console.log("7/15 Deploying GovernanceManager...");
  const GovernanceManager = await ethers.getContractFactory("GovernanceManager");
  const governanceManager = await upgrades.deployProxy(GovernanceManager, [
    deployer.address,           // _admin
    deployer.address,           // _emergency
    [deployer.address],         // _proposers
    [deployer.address]          // _executors
  ]);
  await governanceManager.waitForDeployment();
  deployments.governanceManager = await governanceManager.getAddress();
  console.log("✅ GovernanceManager:", deployments.governanceManager, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 8/9: InsuranceFund
  // initialize(admin, governance, emergency, claimers[], initialTokens[])
  // ═══════════════════════════════════════════════════════════════════════
  console.log("8/15 Deploying InsuranceFund...");
  const InsuranceFund = await ethers.getContractFactory("InsuranceFund");
  const insuranceFund = await upgrades.deployProxy(InsuranceFund, [
    deployer.address,           // _admin
    deployer.address,           // _governance
    deployer.address,           // _emergency
    [deployments.payoutManager],// _claimers
    []                          // _initialTokens (add later)
  ]);
  await insuranceFund.waitForDeployment();
  deployments.insuranceFund = await insuranceFund.getAddress();
  console.log("✅ InsuranceFund:", deployments.insuranceFund, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 9/9: KeeperIncentive
  // initialize(admin, governance, rewardToken, minStakeAmount)
  // ═══════════════════════════════════════════════════════════════════════
  console.log("9/15 Deploying KeeperIncentive...");
  const KeeperIncentive = await ethers.getContractFactory("KeeperIncentive");
  const keeperIncentive = await upgrades.deployProxy(KeeperIncentive, [
    deployer.address,           // _admin
    deployer.address,           // _governance
    "0xb74737f617A7a6aC0699A9c668a23FFFd96f67e4", // USDT reward token
    ethers.parseEther("1000")   // _minStakeAmount (1000 tokens)
  ]);
  await keeperIncentive.waitForDeployment();
  deployments.keeperIncentive = await keeperIncentive.getAddress();
  console.log("✅ KeeperIncentive:", deployments.keeperIncentive, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 2. DEPLOY ORACLE SYSTEM
  // ═══════════════════════════════════════════════════════════════════════

  console.log("📡 Deploying Oracle System...\n");

  // All oracles: initialize(admin, feeders[])

  console.log("10/15 Deploying CryptoPriceOracle...");
  const CryptoPriceOracle = await ethers.getContractFactory("CryptoPriceOracle");
  const cryptoOracle = await upgrades.deployProxy(CryptoPriceOracle, [
    deployer.address,
    [deployer.address]
  ]);
  await cryptoOracle.waitForDeployment();
  deployments.cryptoOracle = await cryptoOracle.getAddress();
  console.log("✅ CryptoPriceOracle:", deployments.cryptoOracle, "\n");

  console.log("11/15 Deploying StockPriceOracle...");
  const StockPriceOracle = await ethers.getContractFactory("StockPriceOracle");
  const stockOracle = await upgrades.deployProxy(StockPriceOracle, [
    deployer.address,
    [deployer.address]
  ]);
  await stockOracle.waitForDeployment();
  deployments.stockOracle = await stockOracle.getAddress();
  console.log("✅ StockPriceOracle:", deployments.stockOracle, "\n");

  console.log("12/15 Deploying ForexPriceOracle...");
  const ForexPriceOracle = await ethers.getContractFactory("ForexPriceOracle");
  const forexOracle = await upgrades.deployProxy(ForexPriceOracle, [
    deployer.address,
    [deployer.address]
  ]);
  await forexOracle.waitForDeployment();
  deployments.forexOracle = await forexOracle.getAddress();
  console.log("✅ ForexPriceOracle:", deployments.forexOracle, "\n");

  console.log("13/15 Deploying CommodityPriceOracle...");
  const CommodityPriceOracle = await ethers.getContractFactory("CommodityPriceOracle");
  const commodityOracle = await upgrades.deployProxy(CommodityPriceOracle, [
    deployer.address,
    [deployer.address]
  ]);
  await commodityOracle.waitForDeployment();
  deployments.commodityOracle = await commodityOracle.getAddress();
  console.log("✅ CommodityPriceOracle:", deployments.commodityOracle, "\n");

  console.log("14/15 Deploying IndexPriceOracle...");
  const IndexPriceOracle = await ethers.getContractFactory("IndexPriceOracle");
  const indexOracle = await upgrades.deployProxy(IndexPriceOracle, [
    deployer.address,
    [deployer.address]
  ]);
  await indexOracle.waitForDeployment();
  deployments.indexOracle = await indexOracle.getAddress();
  console.log("✅ IndexPriceOracle:", deployments.indexOracle, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // OracleRegistry: initialize(admin, crypto, stock, forex, commodity, index)
  // ═══════════════════════════════════════════════════════════════════════
  console.log("15/15 Deploying OracleRegistry...");
  const OracleRegistry = await ethers.getContractFactory("OracleRegistry");
  const oracleRegistry = await upgrades.deployProxy(OracleRegistry, [
    deployer.address,
    deployments.cryptoOracle,
    deployments.stockOracle,
    deployments.forexOracle,
    deployments.commodityOracle,
    deployments.indexOracle
  ]);
  await oracleRegistry.waitForDeployment();
  deployments.oracleRegistry = await oracleRegistry.getAddress();
  console.log("✅ OracleRegistry:", deployments.oracleRegistry, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 3. SAVE DEPLOYMENT DATA
  // ═══════════════════════════════════════════════════════════════════════

  const deploymentData = {
    network,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: deployments
  };

  const deploymentsDir = path.join(__dirname, "../deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const filename = `${network}_${Date.now()}.json`;
  const filepath = path.join(deploymentsDir, filename);
  fs.writeFileSync(filepath, JSON.stringify(deploymentData, null, 2));

  console.log("\n" + "=".repeat(80));
  console.log("✅ ALL 15 CONTRACTS DEPLOYED SUCCESSFULLY!");
  console.log("=".repeat(80));
  console.log("\n📝 Deployment saved to:", filepath);
  console.log("\n📋 Contract Addresses:\n");
  
  console.log("Core Contracts (9):");
  console.log("  1. OperatorRegistry    :", deployments.operatorRegistry);
  console.log("  2. Vault               :", deployments.vault);
  console.log("  3. CapitalPool         :", deployments.capitalPool);
  console.log("  4. TraderAccountRegistry:", deployments.traderRegistry);
  console.log("  5. TradeLedger         :", deployments.tradeLedger);
  console.log("  6. PayoutManager       :", deployments.payoutManager);
  console.log("  7. GovernanceManager   :", deployments.governanceManager);
  console.log("  8. InsuranceFund       :", deployments.insuranceFund);
  console.log("  9. KeeperIncentive     :", deployments.keeperIncentive);
  
  console.log("\nOracle System (6):");
  console.log(" 10. CryptoPriceOracle   :", deployments.cryptoOracle);
  console.log(" 11. StockPriceOracle    :", deployments.stockOracle);
  console.log(" 12. ForexPriceOracle    :", deployments.forexOracle);
  console.log(" 13. CommodityPriceOracle:", deployments.commodityOracle);
  console.log(" 14. IndexPriceOracle    :", deployments.indexOracle);
  console.log(" 15. OracleRegistry      :", deployments.oracleRegistry);
  
  console.log("\n" + "=".repeat(80));
  console.log("🎯 Next Steps:");
  console.log("=".repeat(80));
  console.log("1. Setup roles:  pnpm hardhat run scripts/setup-roles.js --network", network);
  console.log("2. Seed data:    pnpm hardhat run scripts/seed-test-data.js --network", network);
  console.log("3. Verify:       pnpm hardhat run scripts/verify-all.js --network", network);
  console.log("=".repeat(80) + "\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ DEPLOYMENT FAILED:");
    console.error(error);
    process.exit(1);
  });
