// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title TraderAccountRegistry
 * @notice Registry for trader accounts linking on-chain IDs to off-chain accounts
 * @dev Manages trader registration, tier assignment, and account status tracking
 * 
 * **Key Responsibilities:**
 * - Register traders with operator-signed approval (KYC verification)
 * - Track account tiers (Tier 1-5) with associated capital limits
 * - Monitor account status (Active, Breached, Suspended, Promoted)
 * - Store trader metadata and performance metrics
 * - Provide trader lookup by address or ID
 * 
 * **Tier Structure:**
 * - Tier 1: $50K   | 5% max drawdown  | 70% profit split
 * - Tier 2: $100K  | 6% max drawdown  | 75% profit split
 * - Tier 3: $250K  | 8% max drawdown  | 80% profit split
 * - Tier 4: $500K  | 10% max drawdown | 80% profit split
 * - Tier 5: $1M    | 12% max drawdown | 85% profit split
 * 
 * **Security Features:**
 * - Operator signature validation for registration
 * - Role-based access control
 * - Breach tracking and suspension
 * - Nonce-based replay protection
 * 
 * @custom:security-contact security@propdao.finance
 */
contract TraderAccountRegistry is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable 
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAYOUT_MANAGER_ROLE = keccak256("PAYOUT_MANAGER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    enum AccountStatus {
        Inactive,
        Active,
        Breached,
        Suspended,
        Promoted,
        Liquidated
    }

    struct TierConfig {
        uint8 tier;
        uint256 capitalAllocation;
        uint256 maxDrawdownPct;
        uint256 profitSplitPct;
        uint256 minTradingDays;
        uint256 maxDailyLoss;
        bool active;
    }

    struct TraderAccount {
        bytes32 traderId;
        address traderAddress;
        uint8 currentTier;
        AccountStatus status;
        uint256 registeredAt;
        uint256 activatedAt;
        uint256 lastTierUpdate;
        uint256 totalTrades;
        int256 lifetimePnL;
        uint256 breachCount;
        bool kycVerified;
        string metadata;
    }

    struct PerformanceMetrics {
        uint256 winRate;
        uint256 avgWin;
        uint256 avgLoss;
        uint256 sharpeRatio;
        uint256 maxDrawdown;
        uint256 consistencyScore;
        uint256 lastUpdated;
    }

    uint256 public constant BASIS_POINTS = 10000;
    uint8 public constant MAX_TIER = 5;

    mapping(uint8 => TierConfig) public tierConfigs;
    mapping(bytes32 => TraderAccount) public traderAccounts;
    mapping(address => bytes32) public addressToTraderId;
    mapping(bytes32 => PerformanceMetrics) public performanceMetrics;
    mapping(bytes32 => uint256) public nonces;

    bytes32[] public traderIds;
    uint256 public totalTraders;
    uint256 public activeTraders;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    event TraderRegistered(bytes32 indexed traderId, address indexed traderAddress, uint8 tier, uint256 timestamp);
    event TierUpdated(bytes32 indexed traderId, uint8 oldTier, uint8 newTier, uint256 timestamp);
    event StatusChanged(bytes32 indexed traderId, AccountStatus oldStatus, AccountStatus newStatus, string reason, uint256 timestamp);
    event TierConfigUpdated(uint8 indexed tier, uint256 capitalAllocation, uint256 maxDrawdownPct, uint256 profitSplitPct);
    event PerformanceUpdated(bytes32 indexed traderId, uint256 winRate, uint256 sharpeRatio, uint256 consistencyScore, uint256 timestamp);
    event AccountBreached(bytes32 indexed traderId, string breachType, uint256 timestamp);
    event KYCUpdated(bytes32 indexed traderId, bool verified, uint256 timestamp);

    function initialize(
        address _admin,
        address _governance,
        address[] memory _operators
    ) external initializer {
        require(_admin != address(0), "Registry: Zero admin");
        require(_governance != address(0), "Registry: Zero governance");

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governance);

        for (uint256 i = 0; i < _operators.length; i++) {
            require(_operators[i] != address(0), "Registry: Zero operator");
            _grantRole(OPERATOR_ROLE, _operators[i]);
        }

        _initializeDefaultTiers();
    }

    function _initializeDefaultTiers() internal {
        tierConfigs[1] = TierConfig(1, 50_000e18, 500, 7000, 10, 2_500e18, true);
        tierConfigs[2] = TierConfig(2, 100_000e18, 600, 7500, 15, 6_000e18, true);
        tierConfigs[3] = TierConfig(3, 250_000e18, 800, 8000, 20, 20_000e18, true);
        tierConfigs[4] = TierConfig(4, 500_000e18, 1000, 8000, 25, 50_000e18, true);
        tierConfigs[5] = TierConfig(5, 1_000_000e18, 1200, 8500, 30, 120_000e18, true);
    }

    function registerTrader(
        bytes32 traderId,
        address traderAddress,
        uint8 initialTier,
        string calldata metadata,
        bytes calldata operatorSignature
    ) external nonReentrant whenNotPaused {
        require(traderId != bytes32(0), "Registry: Invalid trader ID");
        require(traderAddress != address(0), "Registry: Zero address");
        require(traderAccounts[traderId].traderId == bytes32(0), "Registry: Already registered");
        require(addressToTraderId[traderAddress] == bytes32(0), "Registry: Address registered");
        require(initialTier >= 1 && initialTier <= MAX_TIER, "Registry: Invalid tier");
        require(tierConfigs[initialTier].active, "Registry: Tier not active");

        _verifyOperatorSignature(traderId, traderAddress, initialTier, nonces[traderId], operatorSignature);
        nonces[traderId]++;

        traderAccounts[traderId] = TraderAccount({
            traderId: traderId,
            traderAddress: traderAddress,
            currentTier: initialTier,
            status: AccountStatus.Inactive,
            registeredAt: block.timestamp,
            activatedAt: 0,
            lastTierUpdate: block.timestamp,
            totalTrades: 0,
            lifetimePnL: 0,
            breachCount: 0,
            kycVerified: true,
            metadata: metadata
        });

        addressToTraderId[traderAddress] = traderId;
        traderIds.push(traderId);
        totalTraders++;

        emit TraderRegistered(traderId, traderAddress, initialTier, block.timestamp);
        emit KYCUpdated(traderId, true, block.timestamp);
    }

    function _verifyOperatorSignature(
        bytes32 traderId,
        address traderAddress,
        uint8 tier,
        uint256 nonce,
        bytes calldata signature
    ) internal view {
        bytes32 messageHash = keccak256(abi.encodePacked(traderId, traderAddress, tier, nonce, block.chainid, address(this)));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedHash.recover(signature);
        require(hasRole(OPERATOR_ROLE, signer), "Registry: Invalid operator signature");
    }

    function activateAccount(bytes32 traderId) external onlyRole(PAYOUT_MANAGER_ROLE) nonReentrant {
        TraderAccount storage account = traderAccounts[traderId];
        require(account.traderId != bytes32(0), "Registry: Trader not found");
        require(account.status == AccountStatus.Inactive, "Registry: Not inactive");

        AccountStatus oldStatus = account.status;
        account.status = AccountStatus.Active;
        account.activatedAt = block.timestamp;
        activeTraders++;

        emit StatusChanged(traderId, oldStatus, AccountStatus.Active, "Account activated", block.timestamp);
    }

    function setTier(bytes32 traderId, uint8 newTier) external onlyRole(PAYOUT_MANAGER_ROLE) nonReentrant {
        require(newTier >= 1 && newTier <= MAX_TIER, "Registry: Invalid tier");
        require(tierConfigs[newTier].active, "Registry: Tier not active");

        TraderAccount storage account = traderAccounts[traderId];
        require(account.traderId != bytes32(0), "Registry: Trader not found");

        uint8 oldTier = account.currentTier;
        require(newTier != oldTier, "Registry: Same tier");

        account.currentTier = newTier;
        account.lastTierUpdate = block.timestamp;

        if (newTier > oldTier && account.status == AccountStatus.Active) {
            AccountStatus oldStatus = account.status;
            account.status = AccountStatus.Promoted;
            emit StatusChanged(traderId, oldStatus, AccountStatus.Promoted, "Tier upgraded", block.timestamp);
        }

        emit TierUpdated(traderId, oldTier, newTier, block.timestamp);
    }

    function updateStatus(bytes32 traderId, AccountStatus newStatus, string calldata reason) external nonReentrant {
        require(hasRole(PAYOUT_MANAGER_ROLE, msg.sender) || hasRole(ADMIN_ROLE, msg.sender), "Registry: Not authorized");

        TraderAccount storage account = traderAccounts[traderId];
        require(account.traderId != bytes32(0), "Registry: Trader not found");

        AccountStatus oldStatus = account.status;
        require(newStatus != oldStatus, "Registry: Same status");

        account.status = newStatus;

        if (oldStatus == AccountStatus.Active && newStatus != AccountStatus.Active) {
            activeTraders--;
        } else if (oldStatus != AccountStatus.Active && newStatus == AccountStatus.Active) {
            activeTraders++;
        }

        if (newStatus == AccountStatus.Breached) {
            account.breachCount++;
            emit AccountBreached(traderId, reason, block.timestamp);
        }

        emit StatusChanged(traderId, oldStatus, newStatus, reason, block.timestamp);
    }

    function updatePerformanceMetrics(
        bytes32 traderId,
        uint256 winRate,
        uint256 avgWin,
        uint256 avgLoss,
        uint256 sharpeRatio,
        uint256 maxDrawdown,
        uint256 consistencyScore
    ) external onlyRole(PAYOUT_MANAGER_ROLE) {
        require(traderAccounts[traderId].traderId != bytes32(0), "Registry: Trader not found");
        require(winRate <= BASIS_POINTS, "Registry: Invalid win rate");
        require(consistencyScore <= BASIS_POINTS, "Registry: Invalid consistency score");

        performanceMetrics[traderId] = PerformanceMetrics(winRate, avgWin, avgLoss, sharpeRatio, maxDrawdown, consistencyScore, block.timestamp);
        emit PerformanceUpdated(traderId, winRate, sharpeRatio, consistencyScore, block.timestamp);
    }

    function updateLifetimePnL(bytes32 traderId, int256 pnl) external onlyRole(PAYOUT_MANAGER_ROLE) {
        require(traderAccounts[traderId].traderId != bytes32(0), "Registry: Trader not found");
        traderAccounts[traderId].lifetimePnL = pnl;
    }

    function incrementTradeCount(bytes32 traderId) external onlyRole(PAYOUT_MANAGER_ROLE) {
        require(traderAccounts[traderId].traderId != bytes32(0), "Registry: Trader not found");
        traderAccounts[traderId].totalTrades++;
    }

    function getTraderInfo(bytes32 traderId) external view returns (TraderAccount memory) {
        return traderAccounts[traderId];
    }

    function getTraderIdByAddress(address traderAddress) external view returns (bytes32) {
        return addressToTraderId[traderAddress];
    }

    function getTierConfig(uint8 tier) external view returns (TierConfig memory) {
        require(tier >= 1 && tier <= MAX_TIER, "Registry: Invalid tier");
        return tierConfigs[tier];
    }

    function getPerformanceMetrics(bytes32 traderId) external view returns (PerformanceMetrics memory) {
        return performanceMetrics[traderId];
    }

    function isActive(bytes32 traderId) external view returns (bool) {
        return traderAccounts[traderId].status == AccountStatus.Active;
    }

    function setPayoutManager(address payoutManager) external onlyRole(ADMIN_ROLE) {
        require(payoutManager != address(0), "Registry: Zero address");
        _grantRole(PAYOUT_MANAGER_ROLE, payoutManager);
    }

    function updateTierConfig(
        uint8 tier,
        uint256 capitalAllocation,
        uint256 maxDrawdownPct,
        uint256 profitSplitPct,
        uint256 minTradingDays,
        uint256 maxDailyLoss
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(tier >= 1 && tier <= MAX_TIER, "Registry: Invalid tier");
        require(maxDrawdownPct <= BASIS_POINTS, "Registry: Invalid drawdown");
        require(profitSplitPct <= BASIS_POINTS, "Registry: Invalid profit split");

        tierConfigs[tier].capitalAllocation = capitalAllocation;
        tierConfigs[tier].maxDrawdownPct = maxDrawdownPct;
        tierConfigs[tier].profitSplitPct = profitSplitPct;
        tierConfigs[tier].minTradingDays = minTradingDays;
        tierConfigs[tier].maxDailyLoss = maxDailyLoss;

        emit TierConfigUpdated(tier, capitalAllocation, maxDrawdownPct, profitSplitPct);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(GOVERNANCE_ROLE) {
        require(newImplementation != address(0), "Registry: Zero implementation");
    }

    uint256[50] private __gap;
}
