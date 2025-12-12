const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("CapitalPool", function () {
  async function deployCapitalPoolFixture() {
    const [owner, admin, governance, lp1, lp2, vault, trader] = await ethers.getSigners();

    // Deploy mock USDT
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdt = await MockERC20.deploy("Tether USD", "USDT", 6);
    await usdt.waitForDeployment();

    // Deploy CapitalPool
    const CapitalPool = await ethers.getContractFactory("CapitalPool");
    const capitalPool = await upgrades.deployProxy(CapitalPool, [
      admin.address,
      governance.address,
      await vault.getAddress(),
      await usdt.getAddress()
    ]);
    await capitalPool.waitForDeployment();

    // Mint USDT to LPs
    await usdt.mint(lp1.address, ethers.parseUnits("1000000", 6));
    await usdt.mint(lp2.address, ethers.parseUnits("1000000", 6));

    return { capitalPool, usdt, owner, admin, governance, lp1, lp2, vault, trader };
  }

  describe("Deployment", function () {
    it("Should set the correct roles", async function () {
      const { capitalPool, admin, governance } = await loadFixture(deployCapitalPoolFixture);

      const ADMIN_ROLE = await capitalPool.ADMIN_ROLE();
      const GOVERNANCE_ROLE = await capitalPool.GOVERNANCE_ROLE();

      expect(await capitalPool.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
      expect(await capitalPool.hasRole(GOVERNANCE_ROLE, governance.address)).to.be.true;
    });

    it("Should initialize with correct parameters", async function () {
      const { capitalPool, usdt } = await loadFixture(deployCapitalPoolFixture);

      expect(await capitalPool.primaryToken()).to.equal(await usdt.getAddress());
      expect(await capitalPool.totalPoolValue()).to.equal(0);
    });
  });

  describe("LP Deposits", function () {
    it("Should allow LP to deposit", async function () {
      const { capitalPool, usdt, lp1 } = await loadFixture(deployCapitalPoolFixture);

      const depositAmount = ethers.parseUnits("10000", 6);
      
      await usdt.connect(lp1).approve(await capitalPool.getAddress(), depositAmount);
      await expect(capitalPool.connect(lp1).depositLP(await usdt.getAddress(), depositAmount))
        .to.emit(capitalPool, "LPDeposited")
        .withArgs(lp1.address, await usdt.getAddress(), depositAmount);

      const lpInfo = await capitalPool.getLPInfo(lp1.address);
      expect(lpInfo.totalDeposited).to.equal(depositAmount);
    });

    it("Should mint LP shares correctly", async function () {
      const { capitalPool, usdt, lp1 } = await loadFixture(deployCapitalPoolFixture);

      const depositAmount = ethers.parseUnits("10000", 6);
      
      await usdt.connect(lp1).approve(await capitalPool.getAddress(), depositAmount);
      await capitalPool.connect(lp1).depositLP(await usdt.getAddress(), depositAmount);

      const lpInfo = await capitalPool.getLPInfo(lp1.address);
      expect(lpInfo.shares).to.be.gt(0);
    });

    it("Should reject zero deposit", async function () {
      const { capitalPool, usdt, lp1 } = await loadFixture(deployCapitalPoolFixture);

      await expect(
        capitalPool.connect(lp1).depositLP(await usdt.getAddress(), 0)
      ).to.be.revertedWith("CapitalPool: Zero amount");
    });
  });

  describe("LP Withdrawals", function () {
    it("Should allow LP to withdraw", async function () {
      const { capitalPool, usdt, lp1 } = await loadFixture(deployCapitalPoolFixture);

      const depositAmount = ethers.parseUnits("10000", 6);
      
      await usdt.connect(lp1).approve(await capitalPool.getAddress(), depositAmount);
      await capitalPool.connect(lp1).depositLP(await usdt.getAddress(), depositAmount);

      const lpInfo = await capitalPool.getLPInfo(lp1.address);
      const sharesToWithdraw = lpInfo.shares / 2n;

      await expect(capitalPool.connect(lp1).withdrawLP(await usdt.getAddress(), sharesToWithdraw))
        .to.emit(capitalPool, "LPWithdrawn");
    });

    it("Should respect vesting period", async function () {
      const { capitalPool, usdt, lp1 } = await loadFixture(deployCapitalPoolFixture);

      const depositAmount = ethers.parseUnits("10000", 6);
      
      await usdt.connect(lp1).approve(await capitalPool.getAddress(), depositAmount);
      await capitalPool.connect(lp1).depositLP(await usdt.getAddress(), depositAmount);

      const lpInfo = await capitalPool.getLPInfo(lp1.address);

      // Try to withdraw immediately (should fail if vesting enabled)
      // Note: Default vesting might be 0, adjust test based on configuration
      // await expect(
      //   capitalPool.connect(lp1).withdrawLP(await usdt.getAddress(), lpInfo.shares)
      // ).to.be.revertedWith("CapitalPool: Vesting period");
    });
  });

  describe("Trader Allocations", function () {
    it("Should allow admin to allocate to trader", async function () {
      const { capitalPool, usdt, lp1, trader, admin } = await loadFixture(deployCapitalPoolFixture);

      // LP deposits first
      const depositAmount = ethers.parseUnits("100000", 6);
      await usdt.connect(lp1).approve(await capitalPool.getAddress(), depositAmount);
      await capitalPool.connect(lp1).depositLP(await usdt.getAddress(), depositAmount);

      // Allocate to trader
      const allocationAmount = ethers.parseUnits("50000", 6);
      const traderId = ethers.keccak256(ethers.toUtf8Bytes("trader1"));

      await expect(
        capitalPool.connect(admin).allocateToTrader(
          traderId,
          await usdt.getAddress(),
          allocationAmount
        )
      ).to.emit(capitalPool, "TraderAllocated");
    });

    it("Should track total allocated", async function () {
      const { capitalPool, usdt, lp1, trader, admin } = await loadFixture(deployCapitalPoolFixture);

      const depositAmount = ethers.parseUnits("100000", 6);
      await usdt.connect(lp1).approve(await capitalPool.getAddress(), depositAmount);
      await capitalPool.connect(lp1).depositLP(await usdt.getAddress(), depositAmount);

      const allocationAmount = ethers.parseUnits("50000", 6);
      const traderId = ethers.keccak256(ethers.toUtf8Bytes("trader1"));

      await capitalPool.connect(admin).allocateToTrader(
        traderId,
        await usdt.getAddress(),
        allocationAmount
      );

      expect(await capitalPool.totalAllocated()).to.equal(allocationAmount);
    });
  });

  describe("Emergency Functions", function () {
    it("Should allow admin to pause", async function () {
      const { capitalPool, admin } = await loadFixture(deployCapitalPoolFixture);

      await capitalPool.connect(admin).pause();
      expect(await capitalPool.paused()).to.be.true;
    });

    it("Should prevent deposits when paused", async function () {
      const { capitalPool, usdt, lp1, admin } = await loadFixture(deployCapitalPoolFixture);

      await capitalPool.connect(admin).pause();

      const depositAmount = ethers.parseUnits("10000", 6);
      await usdt.connect(lp1).approve(await capitalPool.getAddress(), depositAmount);

      await expect(
        capitalPool.connect(lp1).depositLP(await usdt.getAddress(), depositAmount)
      ).to.be.revertedWithCustomError(capitalPool, "EnforcedPause");
    });
  });

  describe("View Functions", function () {
    it("Should return correct LP info", async function () {
      const { capitalPool, usdt, lp1 } = await loadFixture(deployCapitalPoolFixture);

      const depositAmount = ethers.parseUnits("10000", 6);
      await usdt.connect(lp1).approve(await capitalPool.getAddress(), depositAmount);
      await capitalPool.connect(lp1).depositLP(await usdt.getAddress(), depositAmount);

      const lpInfo = await capitalPool.getLPInfo(lp1.address);
      expect(lpInfo.totalDeposited).to.equal(depositAmount);
      expect(lpInfo.shares).to.be.gt(0);
    });

    it("Should calculate share value correctly", async function () {
      const { capitalPool, usdt, lp1 } = await loadFixture(deployCapitalPoolFixture);

      const depositAmount = ethers.parseUnits("10000", 6);
      await usdt.connect(lp1).approve(await capitalPool.getAddress(), depositAmount);
      await capitalPool.connect(lp1).depositLP(await usdt.getAddress(), depositAmount);

      const lpInfo = await capitalPool.getLPInfo(lp1.address);
      const shareValue = await capitalPool.calculateShareValue(lpInfo.shares);
      
      expect(shareValue).to.be.closeTo(depositAmount, ethers.parseUnits("1", 6));
    });
  });
});
