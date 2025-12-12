// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./TradeLedger.sol";
import "./TraderAccountRegistry.sol";
import "./CapitalPool.sol";

/**
 * @title PayoutManager
 * @notice Orchestrates trader payouts and tier promotions with full verification
 * @dev Integrates TradeLedger, TraderAccountRegistry, and CapitalPool
 * 
 * **Key Responsibilities:**
 * - Validate trader PnL via TradeLedger Merkle proofs
 * - Calculate profit splits based on tier configuration
 * - Execute payouts through CapitalPool
 * - Authorize tier upgrades for qualified traders
 * - Manage payout schedules and minimums
 * - Track payout history and statistics
 * 
 * **Payout Flow:**
 * ```
 * 1. Trader accumulates PnL (verified in TradeLedger batch)
 * 2. requestPayout() called with Merkle proofs
 * 3. Verify PnL via TradeLedger.verifyAndRecordTraderPnL()
 * 4. Calculate profit split (trader gets 70-85%, pool keeps rest)
 * 5. Execute payout via CapitalPool.transferToTrader()
 * 6. Update trader account status
 * ```
 * 
 * **Tier Upgrade Flow:**
 * ```
 * 1. Trader meets performance criteria
 * 2. authorizeScaling() called by operator
 * 3. Verify eligibility (PnL, consistency, no breaches)
 * 4. Update tier in TraderAccountRegistry
 * 5. Reallocate capital via CapitalPool
 * ```
 * 
 * **Security Features:**
 * - Dual verification: Merkle proofs + operator signatures
 * - Nonce-based replay protection
 * - Minimum payout thresholds
 * - Cooldown periods between payouts
 * - Role-based access control
 * 
 * @custom:security-contact security@propdao.finance
 */
contract PayoutManager is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable 
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /// @notice Minimum payout amount (prevents dust payouts)
    uint256 public constant MIN_PAYOUT = 100e18; // $100
    
    /// @notice Default cooldown between payouts (7 days)
    uint256 public constant DEFAULT_PAYOUT_COOLDOWN = 7 days;
    
    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;

    /**
     * @notice Payout request information
     * @param requestId Unique request identifier
     * @param traderId Trader identifier
     * @param recipient Payout recipient address
     * @param batchId TradeLedger batch ID for verification
     * @param grossPnL Total PnL before split
     * @param traderShare Trader's portion after split
     * @param poolShare Pool's portion
     * @param status Request status
     * @param requestTime Request timestamp
     * @param executedTime Execution timestamp
     */
    struct PayoutRequest {
        bytes32 requestId;
        bytes32 traderId;
        address recipient;
        bytes32 batchId;
        int256 grossPnL;
        uint256 traderShare;
        uint256 poolShare;
        PayoutStatus status;
        uint256 requestTime;
        uint256 executedTime;
    }

    /**
     * @notice Payout status enumeration
     */
    enum PayoutStatus {
        Pending,
        Verified,
        Executed,
        Rejected,
        Cancelled
    }

    /**
     * @notice Tier upgrade request
     * @param traderId Trader identifier
     * @param currentTier Current tier
     * @param newTier Requested tier
     * @param requiredPnL Minimum PnL required
     * @param requiredConsistency Minimum consistency score
     * @param approved Whether upgrade is approved
     */
    struct TierUpgradeRequest {
        bytes32 traderId;
        uint8 currentTier;
        uint8 newTier;
        int256 requiredPnL;
        uint256 requiredConsistency;
        bool approved;
    }

    /// @notice TradeLedger contract
    TradeLedger public tradeLedger;
    
    /// @notice TraderAccountRegistry contract
    TraderAccountRegistry public traderRegistry;
    
    /// @notice CapitalPool contract
    CapitalPool public capitalPool;

    /// @notice Cooldown period between payouts
    uint256 public payoutCooldown;

    /// @notice Mapping of request ID to payout request
    mapping(bytes32 => PayoutRequest) public payoutRequests;
    
    /// @notice Mapping of trader ID to last payout time
    mapping(bytes32 => uint256) public lastPayoutTime;
    
    /// @notice Mapping of trader ID to total payouts received
    mapping(bytes32 => uint256) public totalPayouts;
    
    /// @notice Mapping of trader ID to payout nonce (replay protection)
    mapping(bytes32 => uint256) public payoutNonces;

    /// @notice Array of all payout request IDs
    bytes32[] public payoutRequestIds;

    /// @notice Total payouts executed
    uint256 public totalPayoutsExecuted;
    
    /// @notice Total amount paid out
    uint256 public totalAmountPaidOut;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                                EVENTS
    // ═════════════════════════════════════════════════════════════════════════

    event PayoutRequested(bytes32 indexed requestId, bytes32 indexed traderId, address recipient, int256 grossPnL, uint256 traderShare);
    event PayoutExecuted(bytes32 indexed requestId, bytes32 indexed traderId, address recipient, uint256 amount, uint256 timestamp);
    event PayoutRejected(bytes32 indexed requestId, bytes32 indexed traderId, string reason);
    event TierUpgradeAuthorized(bytes32 indexed traderId, uint8 oldTier, uint8 newTier, uint256 timestamp);
    event PayoutCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event ContractsUpdated(address tradeLedger, address traderRegistry, address capitalPool);

    // ═════════════════════════════════════════════════════════════════════════
    //                            INITIALIZATION
    // ═════════════════════════════════════════════════════════════════════════

    function initialize(
        address _admin,
        address _governance,
        address[] memory _operators,
        address _tradeLedger,
        address _traderRegistry,
        address _capitalPool
    ) external initializer {
        require(_admin != address(0), "PayoutManager: Zero admin");
        require(_governance != address(0), "PayoutManager: Zero governance");
        require(_tradeLedger != address(0), "PayoutManager: Zero tradeLedger");
        require(_traderRegistry != address(0), "PayoutManager: Zero traderRegistry");
        require(_capitalPool != address(0), "PayoutManager: Zero capitalPool");

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governance);

        for (uint256 i = 0; i < _operators.length; i++) {
            require(_operators[i] != address(0), "PayoutManager: Zero operator");
            _grantRole(OPERATOR_ROLE, _operators[i]);
        }

        tradeLedger = TradeLedger(_tradeLedger);
        traderRegistry = TraderAccountRegistry(_traderRegistry);
        capitalPool = CapitalPool(_capitalPool);
        payoutCooldown = DEFAULT_PAYOUT_COOLDOWN;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          PAYOUT FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    function requestPayout(
        bytes32 traderId,
        address recipient,
        bytes32 batchId,
        bytes32[][] calldata proofs,
        TradeLedger.Trade[] calldata trades,
        bytes calldata operatorSignature
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (bytes32 requestId) 
    {
        require(recipient != address(0), "PayoutManager: Zero recipient");
        require(trades.length > 0, "PayoutManager: No trades");

        // Verify trader exists and is active
        TraderAccountRegistry.TraderAccount memory trader = traderRegistry.getTraderInfo(traderId);
        require(trader.traderId != bytes32(0), "PayoutManager: Trader not found");
        require(trader.status == TraderAccountRegistry.AccountStatus.Active || 
                trader.status == TraderAccountRegistry.AccountStatus.Promoted, 
                "PayoutManager: Trader not active");

        // Check cooldown period
        require(
            block.timestamp >= lastPayoutTime[traderId] + payoutCooldown,
            "PayoutManager: Cooldown not passed"
        );

        // Verify operator signature
        _verifyOperatorSignature(traderId, recipient, batchId, payoutNonces[traderId], operatorSignature);
        payoutNonces[traderId]++;

        // Verify PnL via TradeLedger with Merkle proofs
        int256 grossPnL = tradeLedger.verifyAndRecordTraderPnL(batchId, traderId, proofs, trades);
        
        require(grossPnL > 0, "PayoutManager: Non-positive PnL");
        require(uint256(grossPnL) >= MIN_PAYOUT, "PayoutManager: Below minimum");

        // Calculate profit split based on tier
        TraderAccountRegistry.TierConfig memory tierConfig = traderRegistry.getTierConfig(trader.currentTier);
        uint256 traderShare = (uint256(grossPnL) * tierConfig.profitSplitPct) / BASIS_POINTS;
        uint256 poolShare = uint256(grossPnL) - traderShare;

        // Generate request ID
        requestId = keccak256(abi.encodePacked(
            traderId,
            recipient,
            batchId,
            block.timestamp,
            payoutRequestIds.length
        ));

        // Create payout request
        payoutRequests[requestId] = PayoutRequest({
            requestId: requestId,
            traderId: traderId,
            recipient: recipient,
            batchId: batchId,
            grossPnL: grossPnL,
            traderShare: traderShare,
            poolShare: poolShare,
            status: PayoutStatus.Verified,
            requestTime: block.timestamp,
            executedTime: 0
        });

        payoutRequestIds.push(requestId);

        emit PayoutRequested(requestId, traderId, recipient, grossPnL, traderShare);

        // Auto-execute if verified (instant payouts)
        _executePayout(requestId);

        return requestId;
    }

    function _executePayout(bytes32 requestId) internal {
        PayoutRequest storage request = payoutRequests[requestId];
        
        require(request.status == PayoutStatus.Verified, "PayoutManager: Not verified");

        // Update status
        request.status = PayoutStatus.Executed;
        request.executedTime = block.timestamp;

        // Update statistics
        lastPayoutTime[request.traderId] = block.timestamp;
        totalPayouts[request.traderId] += request.traderShare;
        totalPayoutsExecuted++;
        totalAmountPaidOut += request.traderShare;

        // Execute transfer via CapitalPool
        capitalPool.transferToTrader(request.traderId, request.recipient, request.traderShare);

        // Update trader's lifetime PnL in registry
        TraderAccountRegistry.TraderAccount memory trader = traderRegistry.getTraderInfo(request.traderId);
        traderRegistry.updateLifetimePnL(request.traderId, trader.lifetimePnL + request.grossPnL);

        emit PayoutExecuted(
            requestId,
            request.traderId,
            request.recipient,
            request.traderShare,
            block.timestamp
        );
    }

    function _verifyOperatorSignature(
        bytes32 traderId,
        address recipient,
        bytes32 batchId,
        uint256 nonce,
        bytes calldata signature
    ) internal view {
        bytes32 messageHash = keccak256(abi.encodePacked(
            traderId,
            recipient,
            batchId,
            nonce,
            block.chainid,
            address(this)
        ));

        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedHash.recover(signature);

        require(hasRole(OPERATOR_ROLE, signer), "PayoutManager: Invalid operator signature");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          TIER UPGRADE FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    function authorizeScaling(
        bytes32 traderId,
        uint8 newTier,
        bytes calldata operatorSignature
    ) 
        external 
        onlyRole(OPERATOR_ROLE) 
        nonReentrant 
        whenNotPaused 
    {
        TraderAccountRegistry.TraderAccount memory trader = traderRegistry.getTraderInfo(traderId);
        require(trader.traderId != bytes32(0), "PayoutManager: Trader not found");
        require(trader.status == TraderAccountRegistry.AccountStatus.Active, "PayoutManager: Not active");
        require(newTier > trader.currentTier, "PayoutManager: Not an upgrade");
        require(newTier <= 5, "PayoutManager: Invalid tier");

        // Verify eligibility criteria
        TraderAccountRegistry.PerformanceMetrics memory metrics = traderRegistry.getPerformanceMetrics(traderId);
        
        // Check minimum consistency score (80% for tier 2+)
        require(metrics.consistencyScore >= 8000, "PayoutManager: Low consistency");
        
        // Check no recent breaches
        require(trader.breachCount == 0, "PayoutManager: Has breaches");
        
        // Check positive lifetime PnL
        require(trader.lifetimePnL > 0, "PayoutManager: Negative PnL");

        // Get old and new tier configs
        TraderAccountRegistry.TierConfig memory oldTierConfig = traderRegistry.getTierConfig(trader.currentTier);
        TraderAccountRegistry.TierConfig memory newTierConfig = traderRegistry.getTierConfig(newTier);

        uint8 oldTier = trader.currentTier;

        // Update tier in registry (activates account)
        traderRegistry.setTier(traderId, newTier);

        // Reallocate capital if needed
        if (newTierConfig.capitalAllocation > oldTierConfig.capitalAllocation) {
            uint256 additionalCapital = newTierConfig.capitalAllocation - oldTierConfig.capitalAllocation;
            capitalPool.allocateToTrader(traderId, additionalCapital);
        }

        // Activate account if it was inactive
        if (trader.status == TraderAccountRegistry.AccountStatus.Inactive) {
            traderRegistry.activateAccount(traderId);
            capitalPool.allocateToTrader(traderId, newTierConfig.capitalAllocation);
        }

        emit TierUpgradeAuthorized(traderId, oldTier, newTier, block.timestamp);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    function getPayoutRequest(bytes32 requestId) external view returns (PayoutRequest memory) {
        return payoutRequests[requestId];
    }

    function getTraderPayoutHistory(bytes32 traderId) 
        external 
        view 
        returns (bytes32[] memory requests) 
    {
        uint256 count = 0;
        
        for (uint256 i = 0; i < payoutRequestIds.length; i++) {
            if (payoutRequests[payoutRequestIds[i]].traderId == traderId) {
                count++;
            }
        }
        
        requests = new bytes32[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < payoutRequestIds.length; i++) {
            if (payoutRequests[payoutRequestIds[i]].traderId == traderId) {
                requests[index++] = payoutRequestIds[i];
            }
        }
        
        return requests;
    }

    function calculateProfitSplit(bytes32 traderId, uint256 grossPnL) 
        external 
        view 
        returns (uint256 traderShare, uint256 poolShare) 
    {
        TraderAccountRegistry.TraderAccount memory trader = traderRegistry.getTraderInfo(traderId);
        require(trader.traderId != bytes32(0), "PayoutManager: Trader not found");

        TraderAccountRegistry.TierConfig memory tierConfig = traderRegistry.getTierConfig(trader.currentTier);
        
        traderShare = (grossPnL * tierConfig.profitSplitPct) / BASIS_POINTS;
        poolShare = grossPnL - traderShare;
        
        return (traderShare, poolShare);
    }

    function canRequestPayout(bytes32 traderId) external view returns (bool eligible, string memory reason) {
        TraderAccountRegistry.TraderAccount memory trader = traderRegistry.getTraderInfo(traderId);
        
        if (trader.traderId == bytes32(0)) {
            return (false, "Trader not found");
        }
        
        if (trader.status != TraderAccountRegistry.AccountStatus.Active && 
            trader.status != TraderAccountRegistry.AccountStatus.Promoted) {
            return (false, "Trader not active");
        }
        
        if (block.timestamp < lastPayoutTime[traderId] + payoutCooldown) {
            return (false, "Cooldown not passed");
        }
        
        return (true, "Eligible");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    function updateContracts(
        address _tradeLedger,
        address _traderRegistry,
        address _capitalPool
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(_tradeLedger != address(0), "PayoutManager: Zero tradeLedger");
        require(_traderRegistry != address(0), "PayoutManager: Zero traderRegistry");
        require(_capitalPool != address(0), "PayoutManager: Zero capitalPool");

        tradeLedger = TradeLedger(_tradeLedger);
        traderRegistry = TraderAccountRegistry(_traderRegistry);
        capitalPool = CapitalPool(_capitalPool);

        emit ContractsUpdated(_tradeLedger, _traderRegistry, _capitalPool);
    }

    function updatePayoutCooldown(uint256 newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        require(newCooldown >= 1 days, "PayoutManager: Cooldown too short");
        require(newCooldown <= 30 days, "PayoutManager: Cooldown too long");

        uint256 oldCooldown = payoutCooldown;
        payoutCooldown = newCooldown;

        emit PayoutCooldownUpdated(oldCooldown, newCooldown);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(newImplementation != address(0), "PayoutManager: Zero implementation");
    }

    uint256[50] private __gap;
}
