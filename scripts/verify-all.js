const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  console.log("🔍 Starting contract verification on Etherscan/Block Explorer...\n");

  // Load latest deployment
  const deploymentsDir = path.join(__dirname, "../deployments");
  const files = fs.readdirSync(deploymentsDir);
  const latestFile = files
    .filter(f => f.endsWith('.json'))
    .sort()
    .reverse()[0];

  if (!latestFile) {
    console.error("❌ No deployment file found!");
    process.exit(1);
  }

  const deploymentPath = path.join(deploymentsDir, latestFile);
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));

  console.log("📄 Using deployment:", latestFile);
  console.log("Network:", deployment.network);
  console.log("Chain ID:", deployment.chainId, "\n");

  const contracts = deployment.contracts;

  // Verify each contract
  for (const [name, address] of Object.entries(contracts)) {
    try {
      console.log(`Verifying ${name} at ${address}...`);
      
      await hre.run("verify:verify", {
        address: address,
        constructorArguments: []
      });

      console.log(`✅ ${name} verified\n`);
    } catch (error) {
      if (error.message.includes("Already Verified")) {
        console.log(`✅ ${name} already verified\n`);
      } else {
        console.log(`❌ ${name} verification failed:`, error.message, "\n");
      }
    }
  }

  console.log("✅ Verification complete!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
