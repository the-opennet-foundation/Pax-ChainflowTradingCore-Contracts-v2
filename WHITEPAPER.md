# 📘 **PropDAO Whitepaper**

*A Decentralized, Transparent, High-Leverage Proprietary Trading Ecosystem Powered by Paxeer*

**Version 1.0**
**2025**

---

# **Table of Contents**

1. Abstract
2. Introduction
3. Market Problem
4. Vision & Mission
5. System Overview
6. Account Tiers & Scaling
7. Trading Engine Architecture
8. Microservice Ecosystem
9. Paxeer On-Chain Smart Contract Suite
10. Transparency Framework
11. Governance Model
12. Tokenomics (Optional)
13. Risk Management Model
14. Security Architecture
15. Compliance & Regulatory Considerations
16. Go-To-Market Strategy
17. Competitive Positioning
18. Economic Sustainability
19. Roadmap
20. Conclusion
21. Appendix

---

# **1. Abstract**

PropDAO is a decentralized proprietary trading ecosystem designed to democratize access to funded trading capital while delivering unprecedented transparency, fairness, and trust. Leveraging the Paxeer blockchain, PropDAO introduces a hybrid architecture: off-chain microservices provide high-speed execution and risk management, while all trades, payouts, and funding activities are immutably recorded on-chain for public verifiability.

Traders gain access to funded accounts from $50,000 to $1,000,000 and may scale based on performance. The system integrates perpetual futures support with leverage up to **1000×**, advanced risk controls, automated scaling logic, a capital pool backed by investors, and transparent payout mechanics enforced by smart contracts.

PropDAO merges the speed of modern financial infrastructure with the transparency of Web3, creating a new industry standard for proprietary trading.

---

# **2. Introduction**

Proprietary trading ("prop trading") has traditionally been exclusive, opaque, and geographically restricted. While modern retail “funded account” prop firms have democratized access, they are plagued by several issues:

* Lack of transparency around payouts
* Off-chain ledgers that cannot be audited
* Hidden risk rules and subjective enforcement
* Centralized custody of trader performance data
* Inconsistent payouts and trust issues

In contrast, blockchain technology offers transparency, immutability, and trustless verification. However, on-chain trading can be slow and expensive, and unsuitable for high-frequency or professional-level execution. Thus, neither traditional prop firms nor fully on-chain systems provide an optimal solution.

**PropDAO solves this by introducing a hybrid architecture:
High-performance off-chain trading + on-chain transparency.**

Built on **Paxeer**, a high-performance EVM-based blockchain (Chain ID 229), PropDAO leverages fast finality and low fees to create a global, decentralized, transparent prop trading protocol.

---

# **3. Market Problem**

Legacy and retail prop firms face major structural issues:

### **3.1 Opaqueness**

Most prop firms operate black-box systems:

* No proof of performance
* No transparent record of trades
* Ambiguous payout schedules
* Traders forced to “trust” the firm

This creates distrust, disputes, and lost opportunities.

### **3.2 Operational Inefficiency**

Scaling trader accounts, distributing payouts, and enforcing risk rules are labor-intensive manual processes.

### **3.3 Lack of Transparency for Investors**

Capital backers cannot verify how risk is being managed or whether the firm is solvent.

### **3.4 No Global Accessibility**

Traditional prop firms rely on centralized infrastructure with geographical restrictions, banking limits, and compliance inconsistencies.

---

# **4. Vision & Mission**

## **Vision**

To build the world’s most transparent, performance-driven, and decentralized prop trading ecosystem where traders earn based on skill—not trust in a centralized entity.

## **Mission**

To empower traders worldwide with access to institutional-level capital, fair payout mechanisms, transparent trade records, and scalable on-chain auditing powered by Paxeer.

---

# **5. System Overview**

PropDAO operates on a hybrid structure:

### **5.1 Off-Chain Execution Layer**

* Ultra-low latency matching
* Perpetual futures support
* Real-time risk & margin calculations
* PnL streaming
* High-frequency friendly

### **5.2 Microservices Coordination Layer**

A comprehensive suite of distributed microservices handles:

* Trade ingestion
* PnL calculation
* Risk & liquidation monitoring
* Scaling eligibility
* Profit distribution
* Data snapshots for on-chain reporting

### **5.3 Paxeer On-Chain Transparency Layer**

Every critical event is recorded on-chain:

* Trades
* PnL settlements
* Account upgrades
* Payouts
* Liquidation events
* Pool liquidity changes

This creates a **public audit trail** with perfect transparency.

---

# **6. Funded Account Tiers & Scaling Program**

### **6.1 Tier Breakdown**

| Tier   | Capital Allocation | Max Drawdown | Profit Split | Scaling Frequency |
| ------ | ------------------ | ------------ | ------------ | ----------------- |
| Tier 1 | $50,000            | 5%           | 70%          | Monthly           |
| Tier 2 | $100,000           | 6%           | 75%          | Monthly           |
| Tier 3 | $250,000           | 8%           | 80%          | Monthly           |
| Tier 4 | $500,000           | 10%          | 80%          | Monthly           |
| Tier 5 | $1,000,000         | 12%          | 85%          | Bi-Weekly         |

### **6.2 Scaling Logic**

Scaling is triggered when:

* Trader has positive net profit after payout
* Drawdown rules remained intact
* Consistency score remains above threshold
* No risk violations occurred

Scaling transactions are written to-chain through the **PayoutManager** contract.

### **6.3 Evaluation Phase (Optional)**

Traders may enter via a performance challenge:

* Low-cost challenge fee
* Transparent evaluation rules
* All evaluation trades logged on-chain
* Unambiguous pass/fail conditions

---

# **7. Perpetual Trading Engine**

### **7.1 Key Features**

* 1000× leverage (for qualified traders)
* Multi-asset perps
* Cross & Isolated margin
* Auto-liquidation engine
* High-frequency friendly execution

### **7.2 Price Oracles**

Multiple independent data sources are aggregated:

* CEX feeds
* Chainlink / DIA / Paxeer oracles
* Volume-weighted composite index

The index price is periodically anchored on-chain for verifiability.

### **7.3 Liquidation Mechanics**

Risk Engine initiates liquidation if:

* Margin ratio < maintenance margin
* Losses exceed allowed threshold

Liquidation receipts are published on-chain.

---

# **8. Microservice Architecture**

PropDAO uses a fully decoupled microservice architecture similar to modern fintech platforms.

### **Key Services**

1. **Order Execution Service**
2. **Risk Engine**
3. **PnL Computation Service**
4. **Position Service**
5. **Settlement Batch Service**
6. **Payout Engine**
7. **Account Management Service**
8. **Compliance / Access Service**
9. **Trade Streamer → On-Chain Reporter**
10. **Audit & Analytics Service**

This architecture ensures:

* Fault isolation
* Independent updates
* Horizontal scaling
* Global availability

---

# **9. Paxeer On-Chain Smart Contract Suite**

The on-chain layer is the backbone of transparency.

### **9.1 CapitalPool Contract**

* Holds investor LP funds
* Multi-asset support
* Records inflows/outflows
* LP share issuance

### **9.2 TraderAccountRegistry**

* Maps on-chain IDs to off-chain trader accounts
* Stores tier, qualification, and permissions

### **9.3 TradeLedger**

Stores immutable trade records:

* Trade ID
* Asset
* Size
* Side
* Price
* PnL
* Timestamp

### **9.4 PayoutManager**

* Distributes payouts
* Executes scaling
* Updates tier status
* Enforces profit splits

### **9.5 Governance Contract**

* DAO-controlled parameters
* Upgrades
* Risk model configurations

### **9.6 Insurance Fund Contract**

* Covers losses exceeding risk thresholds
* Grows via protocol revenue

---

# **10. Transparency Framework**

### **10.1 Real-Time On-Chain Reporting**

Each trade, payout, or liquidation triggers:

* On-chain event log
* Public visibility
* Immutable audit trail

### **10.2 Public Dashboard**

Provides:

* Real-time PnL
* Trader rankings
* Account histories
* Capital pool reserves
* Governance decisions

### **10.3 Digital Notary System**

All off-chain settlement batches are hashed and notarized on-chain.

---

# **11. Governance Model**

### **11.1 DAO Voting**

Holders may vote on:

* Risk parameters
* Tier requirements
* Fee structures
* New market listings
* Treasury deployment

### **11.2 Safeguards**

* Time-locked governance actions
* Multi-sig for emergency powers
* Upgrade delays to avoid exploit risk

---

# **12. Tokenomics (Optional)**

If a token is introduced, recommended utility includes:

### **12.1 Utility**

* Governance
* Fee discounts
* Priority scaling
* Staking rewards
* Insurance fund backstop

### **12.2 Revenue Flows**

* Buyback & burn
* Staking yield
* Treasury growth

### **12.3 Distribution**

* 40% Community & Traders
* 25% Liquidity Providers
* 20% Treasury
* 10% Team & Advisors
* 5% Insurance Fund

---

# **13. Risk Management Framework**

### **13.1 On-Chain Controls**

* Hard-coded max leverage
* Hard-coded drawdown caps
* Tier upgrade throttles

### **13.2 Off-Chain Controls**

* Real-time exposure limits
* Margin monitoring
* Circuit breakers

### **13.3 Insurance Backstop**

* Automatic coverage for abnormal liquidation events

---

# **14. Security Architecture**

### **14.1 Smart Contract Security**

* Formal verification
* Third-party audits
* Time-lock governance

### **14.2 Off-Chain Infrastructure Security**

* API signature verification
* TLS encrypted data flow
* Strict role-based access
* Redundant servers

### **14.3 Data Integrity Measures**

* Settlement batch hashing
* Trade logs stored redundantly
* Chain notarization

---

# **15. Compliance & Regulation**

* Regional access restrictions via Compliance Service
* Optional KYC tiers
* AML screening on fiat on/off-ramps
* DAO legal wrapper if required

---

# **16. Go-To-Market Strategy**

### **Phase 1 — Closed Alpha**

* Limited traders from private networks
* Low capital tiers ($50K / $100K)
* Stress testing

### **Phase 2 — Public Evaluation Mode**

* Open challenge
* Global trader onboarding

### **Phase 3 — DAO Launch & Token Issuance**

* Governance decentralization
* Global LP onboarding

### **Phase 4 — Institutional Integration**

* Broker integrations
* Automated market makers
* API-based quant access

---

# **17. Competitive Positioning**

PropDAO differentiates itself by:

* **Full transparency** (all trades on-chain)
* **High scalability** via microservices
* **Decentralized governance**
* **Verifiable payouts**
* **Investor-grade accounting tools**
* **Multichain readiness**

This positions PropDAO as the first hybrid prop firm built for Web3-native traders and institutions alike.

---

# **18. Economic Sustainability**

### **Revenue Streams**

* Profit share
* Challenge fees
* DAO token utilities
* Staking and LP fees
* Treasury growth mechanisms

### **Sustainability Guarantees**

* Controlled emissions
* Dynamic scaling
* Regimented payout cycles

---

# **19. Roadmap**

### **Q1**

* Smart contract prototypes
* Off-chain engine MVP
* Paxeer Testnet deployments

### **Q2**

* Mainnet launch
* Onboarding of alpha traders
* Deploy analytics dashboard

### **Q3**

* DAO governance
* Institutional tier launch
* Token release (optional)

### **Q4**

* Global scaling
* Automated LP vaults
* Expanded markets & assets

---

# **20. Conclusion**

PropDAO represents the next evolution of proprietary trading:
**fully transparent, globally accessible, high-performance, and trustless.**

By leveraging Paxeer's advanced blockchain infrastructure and combining it with a sophisticated microservice trading engine, PropDAO brings institutional-level trading capabilities to a decentralized environment — giving traders fair access to capital and giving investors verifiable proof of performance.

This model replaces trust with cryptographic truth and transforms prop trading into a transparent, auditable, and accessible public good.

---

# **21. Appendix**

* Contract ABIs
* Risk formula algorithms
* PnL calculation models
* Oracle aggregation methods
* Data schemas
* Glossary

---
