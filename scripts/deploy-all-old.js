const hre = require("hardhat");
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  console.log("🚀 Starting ChainFlow-v2 Deployment...\n");

  const [deployer] = await ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  const deployments = {};
  const network = hre.network.name;

  // ═══════════════════════════════════════════════════════════════════════
  // 1. DEPLOY CORE CONTRACTS
  // ═══════════════════════════════════════════════════════════════════════

  console.log("📦 Deploying Core Contracts...\n");

  // Deploy OperatorRegistry first (needed by other contracts)
  console.log("1/10 Deploying OperatorRegistry...");
  const OperatorRegistry = await ethers.getContractFactory("OperatorRegistry");
  const operatorRegistry = await upgrades.deployProxy(OperatorRegistry, [
    deployer.address, // admin
    deployer.address, // governance
    [deployer.address], // initial operators
    ["Primary Operator"] // operator metadata
  ]);
  await operatorRegistry.waitForDeployment();
  deployments.operatorRegistry = await operatorRegistry.getAddress();
  console.log("✅ OperatorRegistry deployed to:", deployments.operatorRegistry, "\n");

  // Deploy Vault
  console.log("2/10 Deploying Vault...");
  const Vault = await ethers.getContractFactory("Vault");
  const vault = await upgrades.deployProxy(Vault, [
    [deployer.address], // guardians
    2, // required approvals
    deployer.address, // admin
    deployer.address // governance
  ]);
  await vault.waitForDeployment();
  deployments.vault = await vault.getAddress();
  console.log("✅ Vault deployed to:", deployments.vault, "\n");

  // Deploy CapitalPool (needs vault address)
  console.log("3/10 Deploying CapitalPool...");
  const CapitalPool = await ethers.getContractFactory("CapitalPool");
  const capitalPool = await upgrades.deployProxy(CapitalPool, [
    deployer.address, // admin
    deployer.address, // governance
    deployments.vault,
    ethers.ZeroAddress // primaryToken (set later)
  ]);
  await capitalPool.waitForDeployment();
  deployments.capitalPool = await capitalPool.getAddress();
  console.log("✅ CapitalPool deployed to:", deployments.capitalPool, "\n");

  // Deploy TraderAccountRegistry
  console.log("4/10 Deploying TraderAccountRegistry...");
  const TraderAccountRegistry = await ethers.getContractFactory("TraderAccountRegistry");
  const traderRegistry = await upgrades.deployProxy(TraderAccountRegistry, [
    deployer.address, // admin
    deployer.address, // governance
    [deployer.address] // initial operators
  ]);
  await traderRegistry.waitForDeployment();
  deployments.traderRegistry = await traderRegistry.getAddress();
  console.log("✅ TraderAccountRegistry deployed to:", deployments.traderRegistry, "\n");

  // Deploy TradeLedger
  console.log("5/10 Deploying TradeLedger...");
  const TradeLedger = await ethers.getContractFactory("TradeLedger");
  const tradeLedger = await upgrades.deployProxy(TradeLedger, [
    deployer.address, // admin
    deployer.address, // governance
    [deployer.address] // initial operators
  ]);
  await tradeLedger.waitForDeployment();
  deployments.tradeLedger = await tradeLedger.getAddress();
  console.log("✅ TradeLedger deployed to:", deployments.tradeLedger, "\n");

  // Deploy PayoutManager
  console.log("6/10 Deploying PayoutManager...");
  const PayoutManager = await ethers.getContractFactory("PayoutManager");
  const payoutManager = await upgrades.deployProxy(PayoutManager, [
    deployer.address, // admin
    deployer.address, // governance
    [deployer.address], // initial operators
    deployments.tradeLedger,
    deployments.traderRegistry,
    deployments.capitalPool
  ]);
  await payoutManager.waitForDeployment();
  deployments.payoutManager = await payoutManager.getAddress();
  console.log("✅ PayoutManager deployed to:", deployments.payoutManager, "\n");

  // Deploy GovernanceManager
  console.log("7/10 Deploying GovernanceManager...");
  const GovernanceManager = await ethers.getContractFactory("GovernanceManager");
  const governanceManager = await upgrades.deployProxy(GovernanceManager, [
    deployer.address, // admin
    deployer.address, // emergency
    [deployer.address], // proposers
    [deployer.address] // executors
  ]);
  await governanceManager.waitForDeployment();
  deployments.governanceManager = await governanceManager.getAddress();
  console.log("✅ GovernanceManager deployed to:", deployments.governanceManager, "\n");

  // Deploy InsuranceFund
  console.log("8/10 Deploying InsuranceFund...");
  const InsuranceFund = await ethers.getContractFactory("InsuranceFund");
  const insuranceFund = await upgrades.deployProxy(InsuranceFund, [
    deployer.address, // admin
    deployer.address, // governance
    deployer.address, // emergency
    [deployments.payoutManager], // claimers
    [] // initial tokens (add later)
  ]);
  await insuranceFund.waitForDeployment();
  deployments.insuranceFund = await insuranceFund.getAddress();
  console.log("✅ InsuranceFund deployed to:", deployments.insuranceFund, "\n");

  // Deploy KeeperIncentive
  console.log("9/10 Deploying KeeperIncentive...");
  const KeeperIncentive = await ethers.getContractFactory("KeeperIncentive");
  const keeperIncentive = await upgrades.deployProxy(KeeperIncentive, [
    deployer.address, // admin
    deployer.address, // governance
    ethers.ZeroAddress, // reward token (set later)
    ethers.parseEther("1000") // min stake
  ]);
  await keeperIncentive.waitForDeployment();
  deployments.keeperIncentive = await keeperIncentive.getAddress();
  console.log("✅ KeeperIncentive deployed to:", deployments.keeperIncentive, "\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 2. DEPLOY ORACLE SYSTEM
  // ═══════════════════════════════════════════════════════════════════════

  console.log("📡 Deploying Oracle System...\n");

  // Deploy CryptoPriceOracle
  console.log("10/15 Deploying CryptoPriceOracle...");
  const CryptoPriceOracle = await ethers.getContractFactory("CryptoPriceOracle");
  const cryptoOracle = await upgrades.deployProxy(CryptoPriceOracle, [
    deployer.address,
    [deployer.address]
  ]);
  await cryptoOracle.waitForDeployment();
  deployments.cryptoOracle = await cryptoOracle.getAddress();
  console.log("✅ CryptoPriceOracle deployed to:", deployments.cryptoOracle, "\n");

  // Deploy StockPriceOracle
  console.log("11/15 Deploying StockPriceOracle...");
  const StockPriceOracle = await ethers.getContractFactory("StockPriceOracle");
  const stockOracle = await upgrades.deployProxy(StockPriceOracle, [
    deployer.address,
    [deployer.address]
  ]);
  await stockOracle.waitForDeployment();
  deployments.stockOracle = await stockOracle.getAddress();
  console.log("✅ StockPriceOracle deployed to:", deployments.stockOracle, "\n");

  // Deploy ForexPriceOracle
  console.log("12/15 Deploying ForexPriceOracle...");
  const ForexPriceOracle = await ethers.getContractFactory("ForexPriceOracle");
  const forexOracle = await upgrades.deployProxy(ForexPriceOracle, [
    deployer.address,
    [deployer.address]
  ]);
  await forexOracle.waitForDeployment();
  deployments.forexOracle = await forexOracle.getAddress();
  console.log("✅ ForexPriceOracle deployed to:", deployments.forexOracle, "\n");

  // Deploy CommodityPriceOracle
  console.log("13/15 Deploying CommodityPriceOracle...");
  const CommodityPriceOracle = await ethers.getContractFactory("CommodityPriceOracle");
  const commodityOracle = await upgrades.deployProxy(CommodityPriceOracle, [
    deployer.address,
    [deployer.address]
  ]);
  await commodityOracle.waitForDeployment();
  deployments.commodityOracle = await commodityOracle.getAddress();
  console.log("✅ CommodityPriceOracle deployed to:", deployments.commodityOracle, "\n");

  // Deploy IndexPriceOracle
  console.log("14/15 Deploying IndexPriceOracle...");
  const IndexPriceOracle = await ethers.getContractFactory("IndexPriceOracle");
  const indexOracle = await upgrades.deployProxy(IndexPriceOracle, [
    deployer.address,
    [deployer.address]
  ]);
  await indexOracle.waitForDeployment();
  deployments.indexOracle = await indexOracle.getAddress();
  console.log("✅ IndexPriceOracle deployed to:", deployments.indexOracle, "\n");

  // Deploy OracleRegistry
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
  console.log("✅ OracleRegistry deployed to:", deployments.oracleRegistry, "\n");

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

  console.log("\n✅ All contracts deployed successfully!");
  console.log("📝 Deployment data saved to:", filepath);
  console.log("\n📋 Deployment Summary:");
  console.log(JSON.stringify(deploymentData, null, 2));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
