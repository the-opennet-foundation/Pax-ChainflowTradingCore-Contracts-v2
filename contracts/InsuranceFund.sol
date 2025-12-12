// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title InsuranceFund
 * @notice Protocol insurance and emergency reserve management
 * @dev Safety net for black swan events, abnormal liquidations, and trader losses
 * 
 * **Key Responsibilities:**
 * - Store protocol reserve funds (multi-asset)
 * - Cover abnormal liquidation losses
 * - Provide emergency trader payouts
 * - Accept revenue allocations from protocol
 * - Track coverage history and utilization
 * - Manage coverage limits and thresholds
 * 
 * **Insurance Model:**
 * ```
 * Revenue Sources:
 * - Protocol fees (5% allocation)
 * - LP donations
 * - Governance treasury transfers
 * 
 * Coverage Triggers:
 * - Trader account liquidated with deficit
 * - Abnormal market conditions (flash crash)
 * - PayoutManager shortfall
 * - Emergency trader compensation
 * ```
 * 
 * **Coverage Limits:**
 * - Per-claim maximum: $100K default
 * - Per-trader daily limit: $250K default
 * - Total coverage cap: 20% of reserve
 * - Governance can adjust limits
 * 
 * **Security Features:**
 * - Governance approval for large claims
 * - Multi-sig for emergency withdrawals
 * - Coverage rate limiting
 * - Audit trail for all claims
 * - Reserve health monitoring
 * 
 * @custom:security-contact security@propdao.finance
 */
contract InsuranceFund is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable 
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /// @notice Default max claim per request ($100K)
    uint256 public constant DEFAULT_MAX_CLAIM = 100_000e18;
    
    /// @notice Default daily limit per trader ($250K)
    uint256 public constant DEFAULT_DAILY_LIMIT = 250_000e18;
    
    /// @notice Default coverage cap (20% of reserves)
    uint256 public constant DEFAULT_COVERAGE_CAP_BPS = 2000; // 20%
    
    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;

    /**
     * @notice Claim status enumeration
     */
    enum ClaimStatus {
        Pending,        // Submitted, awaiting approval
        Approved,       // Approved, funds transferred
        Rejected,       // Rejected by governance
        Expired         // Expired without action
    }

    /**
     * @notice Claim information
     * @param claimId Unique claim identifier
     * @param claimant Address requesting coverage
     * @param traderId Associated trader (if applicable)
     * @param token Token address
     * @param amount Claim amount
     * @param reason Claim justification
     * @param status Current status
     * @param submittedAt Submission timestamp
     * @param processedAt Processing timestamp
     * @param processedBy Address that processed claim
     */
    struct Claim {
        bytes32 claimId;
        address claimant;
        bytes32 traderId;
        address token;
        uint256 amount;
        string reason;
        ClaimStatus status;
        uint256 submittedAt;
        uint256 processedAt;
        address processedBy;
    }

    /**
     * @notice Reserve asset information
     * @param token Token address
     * @param balance Current balance
     * @param totalDeposited Lifetime deposits
     * @param totalClaimed Lifetime claims paid
     * @param active Whether asset is active for coverage
     */
    struct ReserveAsset {
        address token;
        uint256 balance;
        uint256 totalDeposited;
        uint256 totalClaimed;
        bool active;
    }

    /// @notice Maximum claim amount per request
    uint256 public maxClaimAmount;
    
    /// @notice Daily claim limit per trader
    uint256 public dailyClaimLimit;
    
    /// @notice Coverage cap as percentage of reserves (basis points)
    uint256 public coverageCapBps;

    /// @notice Claim counter
    uint256 public claimCounter;

    /// @notice Mapping of claim ID to claim
    mapping(bytes32 => Claim) public claims;
    
    /// @notice Mapping of token to reserve info
    mapping(address => ReserveAsset) public reserves;
    
    /// @notice Mapping of trader ID to daily claims
    mapping(bytes32 => mapping(uint256 => uint256)) public dailyClaims;
    
    /// @notice Array of all supported tokens
    address[] public supportedTokens;
    
    /// @notice Array of all claim IDs
    bytes32[] public claimIds;

    /// @notice Total value of all reserves (denominated in primary token)
    uint256 public totalReserveValue;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                                EVENTS
    // ═════════════════════════════════════════════════════════════════════════

    event ReserveAdded(address indexed token, address indexed from, uint256 amount, uint256 newBalance);
    event ReserveUsed(bytes32 indexed claimId, address indexed token, uint256 amount, string reason);
    event ClaimSubmitted(bytes32 indexed claimId, address indexed claimant, bytes32 indexed traderId, uint256 amount);
    event ClaimApproved(bytes32 indexed claimId, address indexed approver, uint256 amount);
    event ClaimRejected(bytes32 indexed claimId, address indexed rejector, string reason);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);
    event AssetActivated(address indexed token);
    event AssetDeactivated(address indexed token);
    event CoverageLimitsUpdated(uint256 maxClaim, uint256 dailyLimit, uint256 coverageCapBps);
    event ReserveHealthCheck(uint256 totalReserves, uint256 totalClaimed, uint256 utilizationBps);

    // ═════════════════════════════════════════════════════════════════════════
    //                            INITIALIZATION
    // ═════════════════════════════════════════════════════════════════════════

    function initialize(
        address _admin,
        address _governance,
        address _emergency,
        address[] memory _claimers,
        address[] memory _initialTokens
    ) external initializer {
        require(_admin != address(0), "InsuranceFund: Zero admin");
        require(_governance != address(0), "InsuranceFund: Zero governance");
        require(_emergency != address(0), "InsuranceFund: Zero emergency");

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governance);
        _grantRole(EMERGENCY_ROLE, _emergency);

        for (uint256 i = 0; i < _claimers.length; i++) {
            require(_claimers[i] != address(0), "InsuranceFund: Zero claimer");
            _grantRole(CLAIMER_ROLE, _claimers[i]);
        }

        maxClaimAmount = DEFAULT_MAX_CLAIM;
        dailyClaimLimit = DEFAULT_DAILY_LIMIT;
        coverageCapBps = DEFAULT_COVERAGE_CAP_BPS;

        // Initialize supported tokens
        for (uint256 i = 0; i < _initialTokens.length; i++) {
            _activateAsset(_initialTokens[i]);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          RESERVE MANAGEMENT
    // ═════════════════════════════════════════════════════════════════════════

    function addReserve(
        address token,
        uint256 amount
    ) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(token != address(0), "InsuranceFund: Zero token");
        require(amount > 0, "InsuranceFund: Zero amount");
        require(reserves[token].active, "InsuranceFund: Token not supported");

        // Transfer tokens from sender
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update reserve
        reserves[token].balance += amount;
        reserves[token].totalDeposited += amount;
        totalReserveValue += amount; // Simplified: assumes 1:1 with primary token

        emit ReserveAdded(token, msg.sender, amount, reserves[token].balance);
    }

    function addReserveFrom(
        address token,
        address from,
        uint256 amount
    ) 
        external 
        onlyRole(ADMIN_ROLE) 
        nonReentrant 
    {
        require(token != address(0), "InsuranceFund: Zero token");
        require(from != address(0), "InsuranceFund: Zero from");
        require(amount > 0, "InsuranceFund: Zero amount");
        require(reserves[token].active, "InsuranceFund: Token not supported");

        IERC20(token).safeTransferFrom(from, address(this), amount);

        reserves[token].balance += amount;
        reserves[token].totalDeposited += amount;
        totalReserveValue += amount;

        emit ReserveAdded(token, from, amount, reserves[token].balance);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                            CLAIM SYSTEM
    // ═════════════════════════════════════════════════════════════════════════

    function submitClaim(
        bytes32 traderId,
        address token,
        uint256 amount,
        string calldata reason
    ) 
        external 
        onlyRole(CLAIMER_ROLE) 
        nonReentrant 
        whenNotPaused 
        returns (bytes32 claimId) 
    {
        require(token != address(0), "InsuranceFund: Zero token");
        require(amount > 0, "InsuranceFund: Zero amount");
        require(amount <= maxClaimAmount, "InsuranceFund: Exceeds max claim");
        require(reserves[token].active, "InsuranceFund: Token not supported");
        require(reserves[token].balance >= amount, "InsuranceFund: Insufficient reserves");

        // Check daily limit for trader
        uint256 today = block.timestamp / 1 days;
        uint256 todayClaims = dailyClaims[traderId][today];
        require(todayClaims + amount <= dailyClaimLimit, "InsuranceFund: Daily limit exceeded");

        // Check coverage cap
        uint256 maxCoverage = (totalReserveValue * coverageCapBps) / BASIS_POINTS;
        require(amount <= maxCoverage, "InsuranceFund: Exceeds coverage cap");

        claimId = keccak256(abi.encodePacked(
            traderId,
            token,
            amount,
            block.timestamp,
            claimCounter++
        ));

        claims[claimId] = Claim({
            claimId: claimId,
            claimant: msg.sender,
            traderId: traderId,
            token: token,
            amount: amount,
            reason: reason,
            status: ClaimStatus.Pending,
            submittedAt: block.timestamp,
            processedAt: 0,
            processedBy: address(0)
        });

        claimIds.push(claimId);

        emit ClaimSubmitted(claimId, msg.sender, traderId, amount);

        return claimId;
    }

    function approveClaim(bytes32 claimId) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
    {
        Claim storage claim = claims[claimId];
        
        require(claim.claimId != bytes32(0), "InsuranceFund: Invalid claim");
        require(claim.status == ClaimStatus.Pending, "InsuranceFund: Not pending");
        require(reserves[claim.token].balance >= claim.amount, "InsuranceFund: Insufficient reserves");

        claim.status = ClaimStatus.Approved;
        claim.processedAt = block.timestamp;
        claim.processedBy = msg.sender;

        // Update reserves
        reserves[claim.token].balance -= claim.amount;
        reserves[claim.token].totalClaimed += claim.amount;
        totalReserveValue -= claim.amount;

        // Update daily claims
        uint256 today = block.timestamp / 1 days;
        dailyClaims[claim.traderId][today] += claim.amount;

        // Transfer funds
        IERC20(claim.token).safeTransfer(claim.claimant, claim.amount);

        emit ClaimApproved(claimId, msg.sender, claim.amount);
        emit ReserveUsed(claimId, claim.token, claim.amount, claim.reason);
    }

    function rejectClaim(bytes32 claimId, string calldata reason) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
    {
        Claim storage claim = claims[claimId];
        
        require(claim.claimId != bytes32(0), "InsuranceFund: Invalid claim");
        require(claim.status == ClaimStatus.Pending, "InsuranceFund: Not pending");

        claim.status = ClaimStatus.Rejected;
        claim.processedAt = block.timestamp;
        claim.processedBy = msg.sender;

        emit ClaimRejected(claimId, msg.sender, reason);
    }

    function insurePayout(
        bytes32 traderId,
        address token,
        uint256 amount,
        address recipient
    ) 
        external 
        onlyRole(CLAIMER_ROLE) 
        nonReentrant 
        returns (bool success) 
    {
        require(token != address(0), "InsuranceFund: Zero token");
        require(recipient != address(0), "InsuranceFund: Zero recipient");
        require(amount > 0, "InsuranceFund: Zero amount");
        require(amount <= maxClaimAmount, "InsuranceFund: Exceeds max claim");
        require(reserves[token].active, "InsuranceFund: Token not supported");

        if (reserves[token].balance < amount) {
            return false; // Insufficient reserves
        }

        // Check daily limit
        uint256 today = block.timestamp / 1 days;
        if (dailyClaims[traderId][today] + amount > dailyClaimLimit) {
            return false; // Daily limit exceeded
        }

        // Update reserves
        reserves[token].balance -= amount;
        reserves[token].totalClaimed += amount;
        totalReserveValue -= amount;

        // Update daily claims
        dailyClaims[traderId][today] += amount;

        // Transfer funds
        IERC20(token).safeTransfer(recipient, amount);

        bytes32 claimId = keccak256(abi.encodePacked(traderId, token, amount, block.timestamp));
        emit ReserveUsed(claimId, token, amount, "Auto payout insurance");

        return true;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    function getClaim(bytes32 claimId) external view returns (Claim memory) {
        return claims[claimId];
    }

    function getReserveBalance(address token) external view returns (uint256) {
        return reserves[token].balance;
    }

    function getReserveInfo(address token) external view returns (ReserveAsset memory) {
        return reserves[token];
    }

    function getTotalReserveValue() external view returns (uint256) {
        return totalReserveValue;
    }

    function getUtilizationRate() external view returns (uint256 utilizationBps) {
        if (totalReserveValue == 0) return 0;
        
        uint256 totalClaimed = 0;
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            totalClaimed += reserves[supportedTokens[i]].totalClaimed;
        }
        
        utilizationBps = (totalClaimed * BASIS_POINTS) / (totalReserveValue + totalClaimed);
        return utilizationBps;
    }

    function canClaim(
        bytes32 traderId,
        address token,
        uint256 amount
    ) external view returns (bool eligible, string memory reason) {
        if (!reserves[token].active) {
            return (false, "Token not supported");
        }
        
        if (reserves[token].balance < amount) {
            return (false, "Insufficient reserves");
        }
        
        if (amount > maxClaimAmount) {
            return (false, "Exceeds max claim");
        }
        
        uint256 today = block.timestamp / 1 days;
        if (dailyClaims[traderId][today] + amount > dailyClaimLimit) {
            return (false, "Daily limit exceeded");
        }
        
        uint256 maxCoverage = (totalReserveValue * coverageCapBps) / BASIS_POINTS;
        if (amount > maxCoverage) {
            return (false, "Exceeds coverage cap");
        }
        
        return (true, "Eligible");
    }

    function getPendingClaims() external view returns (bytes32[] memory pendingClaimIds) {
        uint256 count = 0;
        
        for (uint256 i = 0; i < claimIds.length; i++) {
            if (claims[claimIds[i]].status == ClaimStatus.Pending) {
                count++;
            }
        }
        
        pendingClaimIds = new bytes32[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < claimIds.length; i++) {
            if (claims[claimIds[i]].status == ClaimStatus.Pending) {
                pendingClaimIds[index++] = claimIds[i];
            }
        }
        
        return pendingClaimIds;
    }

    function getHealthMetrics() 
        external 
        view 
        returns (
            uint256 totalReserves,
            uint256 totalClaimed,
            uint256 utilizationBps,
            uint256 coverageRemaining
        ) 
    {
        totalReserves = totalReserveValue;
        
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            totalClaimed += reserves[supportedTokens[i]].totalClaimed;
        }
        
        if (totalReserves > 0) {
            utilizationBps = (totalClaimed * BASIS_POINTS) / (totalReserves + totalClaimed);
        }
        
        coverageRemaining = (totalReserves * coverageCapBps) / BASIS_POINTS;
        
        return (totalReserves, totalClaimed, utilizationBps, coverageRemaining);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    function activateAsset(address token) external onlyRole(GOVERNANCE_ROLE) {
        _activateAsset(token);
    }

    function _activateAsset(address token) internal {
        require(token != address(0), "InsuranceFund: Zero token");
        require(!reserves[token].active, "InsuranceFund: Already active");

        reserves[token] = ReserveAsset({
            token: token,
            balance: 0,
            totalDeposited: 0,
            totalClaimed: 0,
            active: true
        });

        supportedTokens.push(token);

        emit AssetActivated(token);
    }

    function deactivateAsset(address token) external onlyRole(GOVERNANCE_ROLE) {
        require(reserves[token].active, "InsuranceFund: Not active");
        require(reserves[token].balance == 0, "InsuranceFund: Has balance");

        reserves[token].active = false;

        emit AssetDeactivated(token);
    }

    function updateCoverageLimits(
        uint256 newMaxClaim,
        uint256 newDailyLimit,
        uint256 newCoverageCapBps
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(newMaxClaim > 0, "InsuranceFund: Zero max claim");
        require(newDailyLimit >= newMaxClaim, "InsuranceFund: Daily < max");
        require(newCoverageCapBps <= BASIS_POINTS, "InsuranceFund: Invalid cap");

        maxClaimAmount = newMaxClaim;
        dailyClaimLimit = newDailyLimit;
        coverageCapBps = newCoverageCapBps;

        emit CoverageLimitsUpdated(newMaxClaim, newDailyLimit, newCoverageCapBps);
    }

    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        require(token != address(0), "InsuranceFund: Zero token");
        require(to != address(0), "InsuranceFund: Zero to");
        require(amount > 0, "InsuranceFund: Zero amount");
        require(reserves[token].balance >= amount, "InsuranceFund: Insufficient balance");

        reserves[token].balance -= amount;
        totalReserveValue -= amount;

        IERC20(token).safeTransfer(to, amount);

        emit EmergencyWithdrawal(token, to, amount);
    }

    function performHealthCheck() external {
        (uint256 totalReserves, uint256 totalClaimed, uint256 utilizationBps,) = this.getHealthMetrics();
        emit ReserveHealthCheck(totalReserves, totalClaimed, utilizationBps);
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
        require(newImplementation != address(0), "InsuranceFund: Zero implementation");
    }

    uint256[50] private __gap;
}
