# ChainFlow-v2 Testing & Deployment Guide

## 📋 Table of Contents
- [Testing](#testing)
- [Deployment](#deployment)
- [Scripts](#scripts)
- [Contract Addresses](#contract-addresses)

---

## 🧪 Testing

### Run All Tests
```bash
pnpm test
```

### Run Specific Test File
```bash
pnpm test test/01_CapitalPool.test.js
pnpm test test/02_TradeLedger.test.js
pnpm test test/03_OracleSystem.test.js
```

### Run Tests with Coverage
```bash
pnpm coverage
```

### Run Tests with Gas Reporter
```bash
REPORT_GAS=true pnpm test
```

---

## 🚀 Deployment

### 1. Deploy to Local Hardhat Network
```bash
# Start local node
pnpm hardhat node

# In another terminal, deploy
pnpm hardhat run scripts/deploy-all.js --network localhost
```

### 2. Deploy to Paxeer Testnet
```bash
pnpm hardhat run scripts/deploy-all.js --network paxeerTestnet
```

### 3. Deploy to Paxeer Mainnet
```bash
pnpm hardhat run scripts/deploy-all.js --network paxeerMainnet
```

### Deployment Output
Deployments are saved to: `/deployments/{network}_{timestamp}.json`

Example:
```json
{
  "network": "paxeerTestnet",
  "chainId": "229",
  "deployer": "0x...",
  "timestamp": "2025-01-15T10:30:00.000Z",
  "contracts": {
    "capitalPool": "0x...",
    "vault": "0x...",
    "tradeLedger": "0x...",
    ...
  }
}
```

---

## 📜 Scripts

### Deploy All Contracts
```bash
pnpm hardhat run scripts/deploy-all.js --network <network>
```

### Setup Roles & Permissions
```bash
pnpm hardhat run scripts/setup-roles.js --network <network>
```

### Seed Test Data
```bash
pnpm hardhat run scripts/seed-test-data.js --network <network>
```

### Verify Contracts on Explorer
```bash
pnpm hardhat run scripts/verify-all.js --network <network>
```

---

## 📐 Test Structure

```
test/
├── 01_CapitalPool.test.js          # LP deposits, withdrawals, allocations
├── 02_TradeLedger.test.js          # Batch submission, Merkle proofs
├── 03_OracleSystem.test.js         # Multi-oracle price feeds
├── helpers/
│   ├── MockERC20.sol               # Mock token for testing
│   └── merkle.js                   # Merkle tree utilities
```

---

## 🏗️ Contract Architecture

### Core Contracts (9)
1. **CapitalPool** - LP capital management
2. **Vault** - Multi-sig custody
3. **TraderAccountRegistry** - Identity & tiers
4. **TradeLedger** - Immutable trade ledger
5. **PayoutManager** - Payout orchestration
6. **OperatorRegistry** - Operator authorization
7. **GovernanceManager** - DAO governance
8. **InsuranceFund** - Emergency reserves
9. **KeeperIncentive** - Liquidation rewards

### Oracle System (6)
1. **CryptoPriceOracle** - Crypto prices (BTC, ETH, SOL...)
2. **StockPriceOracle** - Stock prices (AAPL, TSLA...)
3. **ForexPriceOracle** - Forex pairs (EUR/USD, GBP/USD...)
4. **CommodityPriceOracle** - Commodities (Gold, Oil...)
5. **IndexPriceOracle** - Indices (SPX, NDX...)
6. **OracleRegistry** - Central coordinator

**Total: 15 Contracts**

---

## 🔗 Integration Flow

```
LP Deposit → CapitalPool → Vault (custody)
                ↓
        Allocate to Trader
                ↓
    Trader Executes (off-chain)
                ↓
        Operator Submits Batch
                ↓
        TradeLedger (Merkle root)
                ↓
        PayoutManager (verify + pay)
                ↓
        InsuranceFund (if needed)
```

---

## 🧩 Testing Patterns

### LP Deposit Flow
```javascript
// Approve tokens
await usdt.connect(lp).approve(capitalPool.address, amount);

// Deposit
await capitalPool.connect(lp).depositLP(usdt.address, amount);

// Verify shares minted
const lpInfo = await capitalPool.getLPInfo(lp.address);
expect(lpInfo.shares).to.be.gt(0);
```

### Trade Batch Submission
```javascript
// Submit batch
const tx = await tradeLedger.connect(operator).submitBatch(
  batchHash,
  merkleRoot,
  tradeCount,
  metadata,
  volume,
  pnl
);

// Verify event
await expect(tx).to.emit(tradeLedger, "BatchSubmitted");
```

### Oracle Price Update
```javascript
// Update crypto price
await cryptoOracle.connect(feeder).updatePrice(
  ethers.keccak256(ethers.toUtf8Bytes("BTC/USD")),
  45000_00000000n, // $45,000 with 8 decimals
  50 // 0.5% confidence
);

// Query through registry
const [price, timestamp] = await oracleRegistry.getPrice(symbol);
```

---

## 🔐 Security Checklist

- [ ] All contracts deployed via upgradeable proxies
- [ ] Roles configured correctly (see setup-roles.js)
- [ ] Multi-sig guardians set for Vault
- [ ] Timelock configured for governance
- [ ] Operators added to OperatorRegistry
- [ ] Oracle feeders configured
- [ ] Emergency pause tested
- [ ] Contracts verified on explorer

---

## 📊 Gas Estimates

| Contract | Deploy Gas | Key Function Gas |
|----------|------------|------------------|
| CapitalPool | ~3.5M | depositLP: ~150K |
| TradeLedger | ~3.0M | submitBatch: ~200K |
| OracleRegistry | ~2.5M | getPrice: ~2K (view) |
| PayoutManager | ~3.5M | requestPayout: ~300K |

---

## 🐛 Debugging

### Enable Hardhat Console Logs
```solidity
import "hardhat/console.sol";

console.log("Debug:", value);
```

### Fork Mainnet for Testing
```javascript
await hre.network.provider.request({
  method: "hardhat_reset",
  params: [{
    forking: {
      jsonRpcUrl: "https://rpc.paxeer.network",
      blockNumber: 12345678
    }
  }]
});
```

### Time Travel
```javascript
// Increase time by 7 days
await ethers.provider.send("evm_increaseTime", [7 * 24 * 60 * 60]);
await ethers.provider.send("evm_mine");
```

---

## 📞 Support

- **Documentation**: `/docs`
- **Issues**: GitHub Issues
- **Discord**: [PropDAO Community]

---

## ✅ Deployment Checklist

### Pre-Deployment
- [ ] Compile all contracts: `pnpm compile`
- [ ] Run all tests: `pnpm test`
- [ ] Check gas usage: `REPORT_GAS=true pnpm test`
- [ ] Audit contracts (if mainnet)
- [ ] Prepare deployer wallet with funds

### Deployment
- [ ] Deploy all contracts: `deploy-all.js`
- [ ] Save deployment addresses
- [ ] Setup roles: `setup-roles.js`
- [ ] Verify contracts: `verify-all.js`

### Post-Deployment
- [ ] Test on deployed contracts
- [ ] Seed test data (testnet): `seed-test-data.js`
- [ ] Monitor contract events
- [ ] Document deployment in CHANGELOG

---

## 🎓 Learn More

- [Hardhat Documentation](https://hardhat.org/docs)
- [OpenZeppelin Upgrades](https://docs.openzeppelin.com/upgrades-plugins)
- [Ethers.js v6](https://docs.ethers.org/v6/)

---

**Built with ❤️ by ChainFlow Team**
