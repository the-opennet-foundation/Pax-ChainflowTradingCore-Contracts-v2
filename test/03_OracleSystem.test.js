const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("Oracle System", function () {
  async function deployOracleSystemFixture() {
    const [owner, admin, feeder1, feeder2] = await ethers.getSigners();

    // Deploy all oracle contracts
    const CryptoPriceOracle = await ethers.getContractFactory("CryptoPriceOracle");
    const cryptoOracle = await upgrades.deployProxy(CryptoPriceOracle, [
      admin.address,
      [feeder1.address]
    ]);
    await cryptoOracle.waitForDeployment();

    const StockPriceOracle = await ethers.getContractFactory("StockPriceOracle");
    const stockOracle = await upgrades.deployProxy(StockPriceOracle, [
      admin.address,
      [feeder1.address]
    ]);
    await stockOracle.waitForDeployment();

    const ForexPriceOracle = await ethers.getContractFactory("ForexPriceOracle");
    const forexOracle = await upgrades.deployProxy(ForexPriceOracle, [
      admin.address,
      [feeder1.address]
    ]);
    await forexOracle.waitForDeployment();

    const CommodityPriceOracle = await ethers.getContractFactory("CommodityPriceOracle");
    const commodityOracle = await upgrades.deployProxy(CommodityPriceOracle, [
      admin.address,
      [feeder1.address]
    ]);
    await commodityOracle.waitForDeployment();

    const IndexPriceOracle = await ethers.getContractFactory("IndexPriceOracle");
    const indexOracle = await upgrades.deployProxy(IndexPriceOracle, [
      admin.address,
      [feeder1.address]
    ]);
    await indexOracle.waitForDeployment();

    // Deploy OracleRegistry
    const OracleRegistry = await ethers.getContractFactory("OracleRegistry");
    const oracleRegistry = await upgrades.deployProxy(OracleRegistry, [
      admin.address,
      await cryptoOracle.getAddress(),
      await stockOracle.getAddress(),
      await forexOracle.getAddress(),
      await commodityOracle.getAddress(),
      await indexOracle.getAddress()
    ]);
    await oracleRegistry.waitForDeployment();

    return {
      cryptoOracle,
      stockOracle,
      forexOracle,
      commodityOracle,
      indexOracle,
      oracleRegistry,
      owner,
      admin,
      feeder1,
      feeder2
    };
  }

  describe("CryptoPriceOracle", function () {
    it("Should allow feeder to update price", async function () {
      const { cryptoOracle, feeder1 } = await loadFixture(deployOracleSystemFixture);

      const symbol = ethers.keccak256(ethers.toUtf8Bytes("BTC/USD"));
      const price = 45000_00000000n; // $45,000 with 8 decimals
      const confidence = 50; // 0.5% confidence interval

      await expect(
        cryptoOracle.connect(feeder1).updatePrice(symbol, price, confidence)
      ).to.emit(cryptoOracle, "PriceUpdated");
    });

    it("Should return current price", async function () {
      const { cryptoOracle, feeder1 } = await loadFixture(deployOracleSystemFixture);

      const symbol = ethers.keccak256(ethers.toUtf8Bytes("BTC/USD"));
      const price = 45000_00000000n;
      const confidence = 50;

      await cryptoOracle.connect(feeder1).updatePrice(symbol, price, confidence);

      const [returnedPrice, timestamp] = await cryptoOracle.getPrice(symbol);
      expect(returnedPrice).to.equal(price);
    });

    it("Should update 24h statistics", async function () {
      const { cryptoOracle, feeder1 } = await loadFixture(deployOracleSystemFixture);

      const symbol = ethers.keccak256(ethers.toUtf8Bytes("BTC/USD"));
      const price = 45000_00000000n;
      const confidence = 50;
      const volume = ethers.parseEther("1000000");

      await cryptoOracle.connect(feeder1).updatePriceWithVolume(
        symbol,
        price,
        confidence,
        volume
      );

      const cryptoData = await cryptoOracle.getCryptoPrice(symbol);
      expect(cryptoData.price).to.equal(price);
      expect(cryptoData.volume).to.equal(volume);
    });

    it("Should detect stale price", async function () {
      const { cryptoOracle, feeder1 } = await loadFixture(deployOracleSystemFixture);

      const symbol = ethers.keccak256(ethers.toUtf8Bytes("ETH/USD"));
      const price = 2500_00000000n;
      const confidence = 50;

      await cryptoOracle.connect(feeder1).updatePrice(symbol, price, confidence);

      // Price should not be stale immediately
      expect(await cryptoOracle.isStale(symbol)).to.be.false;

      // After staleness threshold (60s), should be stale
      await ethers.provider.send("evm_increaseTime", [61]);
      await ethers.provider.send("evm_mine");

      expect(await cryptoOracle.isStale(symbol)).to.be.true;
    });
  });

  describe("ForexPriceOracle", function () {
    it("Should update forex price with spread", async function () {
      const { forexOracle, feeder1 } = await loadFixture(deployOracleSystemFixture);

      const symbol = ethers.keccak256(ethers.toUtf8Bytes("EUR/USD"));
      const bidPrice = 1_08000000n; // 1.08
      const askPrice = 1_08050000n; // 1.0805
      const confidence = 10;
      const liquidity = 1000000n;

      await expect(
        forexOracle.connect(feeder1).updateForexPrice(
          symbol,
          bidPrice,
          askPrice,
          confidence,
          liquidity
        )
      ).to.emit(forexOracle, "PriceUpdated");
    });

    it("Should calculate spread correctly", async function () {
      const { forexOracle, feeder1 } = await loadFixture(deployOracleSystemFixture);

      const symbol = ethers.keccak256(ethers.toUtf8Bytes("EUR/USD"));
      const bidPrice = 1_08000000n;
      const askPrice = 1_08050000n;

      await forexOracle.connect(feeder1).updateForexPrice(
        symbol,
        bidPrice,
        askPrice,
        10,
        1000000n
      );

      const forexData = await forexOracle.getForexPrice(symbol);
      expect(forexData.bidPrice).to.equal(bidPrice);
      expect(forexData.askPrice).to.equal(askPrice);
      expect(forexData.spread).to.be.gt(0);
    });
  });

  describe("OracleRegistry", function () {
    it("Should route to correct oracle", async function () {
      const { oracleRegistry, cryptoOracle, feeder1 } = await loadFixture(deployOracleSystemFixture);

      const symbol = ethers.keccak256(ethers.toUtf8Bytes("BTC/USD"));
      const price = 45000_00000000n;

      // Update price in crypto oracle
      await cryptoOracle.connect(feeder1).updatePrice(symbol, price, 50);

      // Query through registry
      const [returnedPrice] = await oracleRegistry.getPrice(symbol);
      expect(returnedPrice).to.equal(price);
    });

    it("Should return price quotes for multiple symbols", async function () {
      const { oracleRegistry, cryptoOracle, feeder1 } = await loadFixture(deployOracleSystemFixture);

      // Update multiple symbols
      const btcSymbol = ethers.keccak256(ethers.toUtf8Bytes("BTC/USD"));
      const ethSymbol = ethers.keccak256(ethers.toUtf8Bytes("ETH/USD"));

      await cryptoOracle.connect(feeder1).updatePrice(btcSymbol, 45000_00000000n, 50);
      await cryptoOracle.connect(feeder1).updatePrice(ethSymbol, 2500_00000000n, 50);

      // Get batch prices
      const quotes = await oracleRegistry.getPriceBatch([btcSymbol, ethSymbol]);
      expect(quotes.length).to.equal(2);
      expect(quotes[0].isValid).to.be.true;
      expect(quotes[1].isValid).to.be.true;
    });

    it("Should return oracle health status", async function () {
      const { oracleRegistry } = await loadFixture(deployOracleSystemFixture);

      const healthReports = await oracleRegistry.getOracleHealth();
      expect(healthReports.length).to.equal(5);
      
      // All oracles should be active
      for (const report of healthReports) {
        expect(report.isActive).to.be.true;
      }
    });
  });

  describe("Price Validation", function () {
    it("Should reject invalid price", async function () {
      const { cryptoOracle, feeder1 } = await loadFixture(deployOracleSystemFixture);

      const symbol = ethers.keccak256(ethers.toUtf8Bytes("BTC/USD"));

      await expect(
        cryptoOracle.connect(feeder1).updatePrice(symbol, 0, 50)
      ).to.be.revertedWith("Invalid price");
    });

    it("Should reject price with excessive deviation", async function () {
      const { cryptoOracle, feeder1 } = await loadFixture(deployOracleSystemFixture);

      const symbol = ethers.keccak256(ethers.toUtf8Bytes("BTC/USD"));
      
      // Set initial price
      await cryptoOracle.connect(feeder1).updatePrice(symbol, 45000_00000000n, 50);

      // Try to update with 20% deviation (should fail if max deviation is 10%)
      await expect(
        cryptoOracle.connect(feeder1).updatePrice(symbol, 54000_00000000n, 50)
      ).to.be.revertedWith("Price deviation too high");
    });
  });

  describe("Access Control", function () {
    it("Should reject non-feeder price updates", async function () {
      const { cryptoOracle, owner } = await loadFixture(deployOracleSystemFixture);

      const symbol = ethers.keccak256(ethers.toUtf8Bytes("BTC/USD"));

      await expect(
        cryptoOracle.connect(owner).updatePrice(symbol, 45000_00000000n, 50)
      ).to.be.reverted;
    });

    it("Should allow admin to add symbols", async function () {
      const { cryptoOracle, admin } = await loadFixture(deployOracleSystemFixture);

      const newSymbol = ethers.keccak256(ethers.toUtf8Bytes("LINK/USD"));

      await expect(
        cryptoOracle.connect(admin).addSymbol(newSymbol, "Chainlink")
      ).to.emit(cryptoOracle, "SymbolAdded");
    });
  });
});
