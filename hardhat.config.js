require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("dotenv/config"); // Import and configure dotenv

// Retrieve the private key and API keys from the .env file
const privateKey = process.env.PRIVATE_KEY;
const etherscanApiKey = process.env.ETHERSCAN_API_KEY;
const basescanApiKey = process.env.BASESCAN_API_KEY;

// Check if the private key is set
if (!privateKey) {
  console.warn("🚨 WARNING: PRIVATE_KEY is not set in the .env file. Deployments will not be possible.");
}

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  allowUnlimitedContractSize: true,
  solidity: {
    compilers: [
      {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 800, // Increased for better optimization and lower deployment cost
          },
          viaIR: false, // Disabled for deployment to reduce gas
        },
      },
      {
        version: "0.8.21",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: true,
        },
      },
      {
        version: "0.8.27",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: true, // Disabled for faster compilation
        },
      }
    ]
  },
networks: {
    hardhat: {
      allowUnlimitedContractSize: true
    },
    'paxeer-network': {
      url: 'https://public-rpc.paxeer.app/rpc',
      accounts: privateKey ? [privateKey] : [],
      chainId: 229,
      gasPrice: 1000000000, // 1 Gwei
      gas: "auto",
      timeout: 180000,
      allowUnlimitedContractSize: true
    },
  },
  etherscan: {
    apiKey: {
      'paxeer-network': 'empty'
    },
    customChains: [
      {
        network: "paxeer-network",
        chainId: 229,
        urls: {
          apiURL: "https://paxscan.paxeer.app/api",
          browserURL: "https://paxscan.paxeer.app"
        }
      }
    ]
  }
};