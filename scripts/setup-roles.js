const hre = require("hardhat");
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  console.log("🔐 Setting up contract roles and permissions...\n");

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
  // 1. GRANT CAPITAL POOL ROLE TO VAULT
  // ═══════════════════════════════════════════════════════════════════════

  console.log("1. Granting CAPITAL_POOL_ROLE to Vault...");
  const vault = await ethers.getContractAt("Vault", contracts.vault);
  const capitalPool = await ethers.getContractAt("CapitalPool", contracts.capitalPool);
  
  const CAPITAL_POOL_ROLE = await vault.CAPITAL_POOL_ROLE();
  const tx1 = await vault.grantRole(CAPITAL_POOL_ROLE, contracts.capitalPool);
  await tx1.wait();
  console.log("✅ Done\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 2. GRANT PAYOUT MANAGER ROLES
  // ═══════════════════════════════════════════════════════════════════════

  console.log("2. Granting PayoutManager permissions...");
  const traderRegistry = await ethers.getContractAt("TraderAccountRegistry", contracts.traderRegistry);
  const PAYOUT_MANAGER_ROLE = await traderRegistry.PAYOUT_MANAGER_ROLE();
  
  const tx2 = await traderRegistry.grantRole(PAYOUT_MANAGER_ROLE, contracts.payoutManager);
  await tx2.wait();
  
  const tx3 = await capitalPool.grantRole(PAYOUT_MANAGER_ROLE, contracts.payoutManager);
  await tx3.wait();
  console.log("✅ Done\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 3. GRANT CLAIMER ROLE TO PAYOUT MANAGER IN INSURANCE FUND
  // ═══════════════════════════════════════════════════════════════════════

  console.log("3. Granting CLAIMER_ROLE to PayoutManager in InsuranceFund...");
  const insuranceFund = await ethers.getContractAt("InsuranceFund", contracts.insuranceFund);
  const CLAIMER_ROLE = await insuranceFund.CLAIMER_ROLE();
  
  const tx4 = await insuranceFund.grantRole(CLAIMER_ROLE, contracts.payoutManager);
  await tx4.wait();
  console.log("✅ Done\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 4. GRANT PROTOCOL ROLE TO CONTRACTS IN KEEPER INCENTIVE
  // ═══════════════════════════════════════════════════════════════════════

  console.log("4. Granting PROTOCOL_ROLE to relevant contracts in KeeperIncentive...");
  const keeperIncentive = await ethers.getContractAt("KeeperIncentive", contracts.keeperIncentive);
  const PROTOCOL_ROLE = await keeperIncentive.PROTOCOL_ROLE();
  
  // PayoutManager can trigger keeper rewards for liquidations
  const tx5 = await keeperIncentive.grantRole(PROTOCOL_ROLE, contracts.payoutManager);
  await tx5.wait();
  console.log("✅ Done\n");

  // ═══════════════════════════════════════════════════════════════════════
  // 5. ADD ORACLE FEEDERS
  // ═══════════════════════════════════════════════════════════════════════

  console.log("5. Setting up Oracle feeders...");
  const cryptoOracle = await ethers.getContractAt("CryptoPriceOracle", contracts.cryptoOracle);
  const FEEDER_ROLE = await cryptoOracle.FEEDER_ROLE();
  
  // Grant FEEDER_ROLE to deployer (replace with actual feeder addresses later)
  const oracles = [
    contracts.cryptoOracle,
    contracts.stockOracle,
    contracts.forexOracle,
    contracts.commodityOracle,
    contracts.indexOracle
  ];

  for (const oracleAddr of oracles) {
    const oracle = await ethers.getContractAt("OracleBase", oracleAddr);
    const tx = await oracle.grantRole(FEEDER_ROLE, deployer.address);
    await tx.wait();
  }
  console.log("✅ Done\n");

  console.log("✅ All roles and permissions configured!");
  console.log("\n📋 Summary:");
  console.log("- Vault ← CapitalPool access");
  console.log("- PayoutManager ← Trader registry & Capital pool access");
  console.log("- PayoutManager ← Insurance fund claimer");
  console.log("- KeeperIncentive ← Protocol access");
  console.log("- Oracles ← Feeder roles configured");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
