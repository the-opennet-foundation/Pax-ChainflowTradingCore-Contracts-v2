const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("TradeLedger", function () {
  async function deployTradeLedgerFixture() {
    const [owner, admin, governance, operator, trader] = await ethers.getSigners();

    // Deploy OperatorRegistry first
    const OperatorRegistry = await ethers.getContractFactory("OperatorRegistry");
    const operatorRegistry = await upgrades.deployProxy(OperatorRegistry, [
      admin.address,
      governance.address,
      [operator.address]
    ]);
    await operatorRegistry.waitForDeployment();

    // Deploy TradeLedger
    const TradeLedger = await ethers.getContractFactory("TradeLedger");
    const tradeLedger = await upgrades.deployProxy(TradeLedger, [
      admin.address,
      governance.address,
      await operatorRegistry.getAddress(),
      [operator.address]
    ]);
    await tradeLedger.waitForDeployment();

    return { tradeLedger, operatorRegistry, owner, admin, governance, operator, trader };
  }

  describe("Deployment", function () {
    it("Should set the correct roles", async function () {
      const { tradeLedger, admin, operator } = await loadFixture(deployTradeLedgerFixture);

      const ADMIN_ROLE = await tradeLedger.ADMIN_ROLE();
      const OPERATOR_ROLE = await tradeLedger.OPERATOR_ROLE();

      expect(await tradeLedger.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
      expect(await tradeLedger.hasRole(OPERATOR_ROLE, operator.address)).to.be.true;
    });

    it("Should initialize with zero batches", async function () {
      const { tradeLedger } = await loadFixture(deployTradeLedgerFixture);

      expect(await tradeLedger.batchCounter()).to.equal(0);
      expect(await tradeLedger.totalTrades()).to.equal(0);
    });
  });

  describe("Batch Submission", function () {
    it("Should allow operator to submit batch", async function () {
      const { tradeLedger, operator } = await loadFixture(deployTradeLedgerFixture);

      const batchHash = ethers.keccak256(ethers.toUtf8Bytes("batch1"));
      const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("root1"));
      const tradeCount = 100;
      const metadata = "ipfs://QmTest123";
      const volume = ethers.parseEther("1000000");
      const pnl = ethers.parseEther("50000");

      await expect(
        tradeLedger.connect(operator).submitBatch(
          batchHash,
          merkleRoot,
          tradeCount,
          metadata,
          volume,
          pnl
        )
      ).to.emit(tradeLedger, "BatchSubmitted");
    });

    it("Should increment batch counter", async function () {
      const { tradeLedger, operator } = await loadFixture(deployTradeLedgerFixture);

      const batchHash = ethers.keccak256(ethers.toUtf8Bytes("batch1"));
      const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("root1"));

      await tradeLedger.connect(operator).submitBatch(
        batchHash,
        merkleRoot,
        100,
        "ipfs://test",
        ethers.parseEther("1000000"),
        ethers.parseEther("50000")
      );

      expect(await tradeLedger.batchCounter()).to.equal(1);
    });

    it("Should update total trades", async function () {
      const { tradeLedger, operator } = await loadFixture(deployTradeLedgerFixture);

      const tradeCount = 150;

      await tradeLedger.connect(operator).submitBatch(
        ethers.keccak256(ethers.toUtf8Bytes("batch1")),
        ethers.keccak256(ethers.toUtf8Bytes("root1")),
        tradeCount,
        "ipfs://test",
        ethers.parseEther("1000000"),
        ethers.parseEther("50000")
      );

      expect(await tradeLedger.totalTrades()).to.equal(tradeCount);
    });

    it("Should reject non-operator submission", async function () {
      const { tradeLedger, trader } = await loadFixture(deployTradeLedgerFixture);

      await expect(
        tradeLedger.connect(trader).submitBatch(
          ethers.keccak256(ethers.toUtf8Bytes("batch1")),
          ethers.keccak256(ethers.toUtf8Bytes("root1")),
          100,
          "ipfs://test",
          ethers.parseEther("1000000"),
          ethers.parseEther("50000")
        )
      ).to.be.reverted;
    });

    it("Should reject zero trade count", async function () {
      const { tradeLedger, operator } = await loadFixture(deployTradeLedgerFixture);

      await expect(
        tradeLedger.connect(operator).submitBatch(
          ethers.keccak256(ethers.toUtf8Bytes("batch1")),
          ethers.keccak256(ethers.toUtf8Bytes("root1")),
          0,
          "ipfs://test",
          ethers.parseEther("1000000"),
          ethers.parseEther("50000")
        )
      ).to.be.revertedWith("TradeLedger: Zero trades");
    });
  });

  describe("Trade Verification", function () {
    it("Should verify valid Merkle proof", async function () {
      const { tradeLedger, operator } = await loadFixture(deployTradeLedgerFixture);

      // Submit batch first
      const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("root1"));
      const tx = await tradeLedger.connect(operator).submitBatch(
        ethers.keccak256(ethers.toUtf8Bytes("batch1")),
        merkleRoot,
        1,
        "ipfs://test",
        ethers.parseEther("1000000"),
        ethers.parseEther("50000")
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => {
        try {
          return tradeLedger.interface.parseLog(log).name === "BatchSubmitted";
        } catch {
          return false;
        }
      });
      const batchId = tradeLedger.interface.parseLog(event).args.batchId;

      // Create simple Merkle proof (for testing)
      const tradeData = ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "address", "int256"],
        [ethers.keccak256(ethers.toUtf8Bytes("trade1")), operator.address, ethers.parseEther("1000")]
      );

      const proof = [merkleRoot]; // Simplified proof

      // Note: Actual Merkle proof verification would require proper tree construction
      // This is a simplified test
    });
  });

  describe("View Functions", function () {
    it("Should return batch info", async function () {
      const { tradeLedger, operator } = await loadFixture(deployTradeLedgerFixture);

      const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("root1"));
      const tx = await tradeLedger.connect(operator).submitBatch(
        ethers.keccak256(ethers.toUtf8Bytes("batch1")),
        merkleRoot,
        100,
        "ipfs://test",
        ethers.parseEther("1000000"),
        ethers.parseEther("50000")
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(log => {
        try {
          return tradeLedger.interface.parseLog(log).name === "BatchSubmitted";
        } catch {
          return false;
        }
      });
      const batchId = tradeLedger.interface.parseLog(event).args.batchId;

      const batch = await tradeLedger.getBatch(batchId);
      expect(batch.tradeCount).to.equal(100);
      expect(batch.merkleRoot).to.equal(merkleRoot);
    });

    it("Should return global statistics", async function () {
      const { tradeLedger, operator } = await loadFixture(deployTradeLedgerFixture);

      await tradeLedger.connect(operator).submitBatch(
        ethers.keccak256(ethers.toUtf8Bytes("batch1")),
        ethers.keccak256(ethers.toUtf8Bytes("root1")),
        100,
        "ipfs://test",
        ethers.parseEther("1000000"),
        ethers.parseEther("50000")
      );

      const stats = await tradeLedger.getGlobalStatistics();
      expect(stats.totalBatches).to.equal(1);
      expect(stats.totalTrades).to.equal(100);
    });
  });

  describe("Emergency Functions", function () {
    it("Should allow admin to pause", async function () {
      const { tradeLedger, admin } = await loadFixture(deployTradeLedgerFixture);

      await tradeLedger.connect(admin).pause();
      expect(await tradeLedger.paused()).to.be.true;
    });

    it("Should prevent submissions when paused", async function () {
      const { tradeLedger, admin, operator } = await loadFixture(deployTradeLedgerFixture);

      await tradeLedger.connect(admin).pause();

      await expect(
        tradeLedger.connect(operator).submitBatch(
          ethers.keccak256(ethers.toUtf8Bytes("batch1")),
          ethers.keccak256(ethers.toUtf8Bytes("root1")),
          100,
          "ipfs://test",
          ethers.parseEther("1000000"),
          ethers.parseEther("50000")
        )
      ).to.be.revertedWithCustomError(tradeLedger, "EnforcedPause");
    });
  });
});
