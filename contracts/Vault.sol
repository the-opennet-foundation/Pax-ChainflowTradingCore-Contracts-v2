// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Vault
 * @notice Secure multi-signature custody vault for PropDAO capital
 * @dev Provides additional security layer for CapitalPool with timelock and multi-sig
 * 
 * **Key Responsibilities:**
 * - Secure custody of protocol assets (multi-asset support)
 * - Multi-signature approval for large transfers
 * - Timelock mechanism for critical operations
 * - Emergency recovery procedures
 * - Asset whitelist management
 * 
 * **Security Model:**
 * - Requires M-of-N signatures for withdrawals above threshold
 * - 48-hour timelock for large transfers (configurable)
 * - Role-based access control (GUARDIAN, CAPITAL_POOL, EMERGENCY_ADMIN)
 * - Emergency pause with multi-sig override
 * 
 * **Multi-Asset Support:**
 * - Whitelisted ERC20 tokens
 * - Per-asset balance tracking
 * - Asset-specific withdrawal limits
 * 
 * @custom:security-contact security@propdao.finance
 */
contract Vault is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable 
{
    using SafeERC20 for IERC20;

    /// @notice Role identifier for vault guardians (multi-sig signers)
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    
    /// @notice Role identifier for CapitalPool contract
    bytes32 public constant CAPITAL_POOL_ROLE = keccak256("CAPITAL_POOL_ROLE");
    
    /// @notice Role identifier for emergency admin
    bytes32 public constant EMERGENCY_ADMIN_ROLE = keccak256("EMERGENCY_ADMIN_ROLE");
    
    /// @notice Role identifier for governance operations
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /// @notice Minimum threshold for timelock (48 hours)
    uint256 public constant MIN_TIMELOCK_DURATION = 48 hours;
    
    /// @notice Maximum threshold for timelock (7 days)
    uint256 public constant MAX_TIMELOCK_DURATION = 7 days;
    
    /// @notice Default large transfer threshold (1M USDC)
    uint256 public constant DEFAULT_LARGE_TRANSFER_THRESHOLD = 1_000_000e18;

    /**
     * @notice Transfer request requiring multi-sig approval
     * @param id Unique request identifier
     * @param token Asset to transfer
     * @param to Recipient address
     * @param amount Amount to transfer
     * @param requester Address that initiated request
     * @param approvals Number of approvals received
     * @param executed Whether request has been executed
     * @param cancelled Whether request has been cancelled
     * @param createdAt Timestamp of request creation
     * @param executeAfter Earliest execution time (timelock)
     */
    struct TransferRequest {
        bytes32 id;
        address token;
        address to;
        uint256 amount;
        address requester;
        uint256 approvals;
        bool executed;
        bool cancelled;
        uint256 createdAt;
        uint256 executeAfter;
    }

    /**
     * @notice Asset configuration
     * @param token ERC20 token address
     * @param whitelisted Whether asset is approved
     * @param dailyLimit Maximum daily withdrawal amount
     * @param withdrawnToday Amount withdrawn today
     * @param lastResetTime Last daily limit reset
     */
    struct AssetConfig {
        address token;
        bool whitelisted;
        uint256 dailyLimit;
        uint256 withdrawnToday;
        uint256 lastResetTime;
    }

    /// @notice Required approvals for large transfers
    uint256 public requiredApprovals;
    
    /// @notice Timelock duration for large transfers
    uint256 public timelockDuration;
    
    /// @notice Threshold above which transfers require multi-sig
    uint256 public largeTransferThreshold;

    /// @notice Counter for transfer request IDs
    uint256 public requestCounter;

    /// @notice Mapping of request ID to transfer request
    mapping(bytes32 => TransferRequest) public transferRequests;
    
    /// @notice Mapping of request ID => guardian => approval status
    mapping(bytes32 => mapping(address => bool)) public hasApproved;
    
    /// @notice Mapping of token address to asset configuration
    mapping(address => AssetConfig) public assetConfigs;
    
    /// @notice Array of whitelisted token addresses
    address[] public whitelistedTokens;
    
    /// @notice Number of active guardians
    uint256 public guardianCount;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                                EVENTS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when assets are deposited into vault
     * @param token Asset deposited
     * @param from Depositor address
     * @param amount Amount deposited
     * @param timestamp Block timestamp
     */
    event Deposited(
        address indexed token,
        address indexed from,
        uint256 amount,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a transfer request is created
     * @param requestId Unique request identifier
     * @param token Asset to transfer
     * @param to Recipient address
     * @param amount Amount to transfer
     * @param requester Address that initiated request
     * @param executeAfter Earliest execution time
     */
    event TransferRequested(
        bytes32 indexed requestId,
        address indexed token,
        address indexed to,
        uint256 amount,
        address requester,
        uint256 executeAfter
    );

    /**
     * @notice Emitted when a guardian approves a transfer
     * @param requestId Request identifier
     * @param guardian Guardian address
     * @param approvals Total approvals received
     */
    event TransferApproved(
        bytes32 indexed requestId,
        address indexed guardian,
        uint256 approvals
    );

    /**
     * @notice Emitted when a transfer is executed
     * @param requestId Request identifier
     * @param token Asset transferred
     * @param to Recipient address
     * @param amount Amount transferred
     * @param executor Address that executed
     */
    event TransferExecuted(
        bytes32 indexed requestId,
        address indexed token,
        address indexed to,
        uint256 amount,
        address executor
    );

    /**
     * @notice Emitted when a transfer request is cancelled
     * @param requestId Request identifier
     * @param cancelledBy Address that cancelled
     */
    event TransferCancelled(
        bytes32 indexed requestId,
        address cancelledBy
    );

    /**
     * @notice Emitted when an asset is whitelisted
     * @param token Asset address
     * @param dailyLimit Daily withdrawal limit
     */
    event AssetWhitelisted(
        address indexed token,
        uint256 dailyLimit
    );

    /**
     * @notice Emitted when an asset is removed from whitelist
     * @param token Asset address
     */
    event AssetRemoved(
        address indexed token
    );

    /**
     * @notice Emitted when vault parameters are updated
     * @param parameter Parameter name
     * @param oldValue Previous value
     * @param newValue New value
     */
    event ParameterUpdated(
        string parameter,
        uint256 oldValue,
        uint256 newValue
    );

    /**
     * @notice Emitted when emergency withdrawal is executed
     * @param token Asset withdrawn
     * @param to Recipient address
     * @param amount Amount withdrawn
     * @param admin Emergency admin
     */
    event EmergencyWithdrawal(
        address indexed token,
        address indexed to,
        uint256 amount,
        address admin
    );

    // ═════════════════════════════════════════════════════════════════════════
    //                            INITIALIZATION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize the Vault contract
     * @param _guardians Array of guardian addresses
     * @param _requiredApprovals Required approvals for multi-sig
     * @param _admin Address to grant admin roles
     * @param _governance Address to grant governance role
     * @dev Can only be called once due to initializer modifier
     */
    function initialize(
        address[] memory _guardians,
        uint256 _requiredApprovals,
        address _admin,
        address _governance
    ) external initializer {
        require(_guardians.length >= _requiredApprovals, "Vault: Invalid guardian count");
        require(_requiredApprovals >= 2, "Vault: Min 2 approvals required");
        require(_admin != address(0), "Vault: Zero admin");
        require(_governance != address(0), "Vault: Zero governance");

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        requiredApprovals = _requiredApprovals;
        timelockDuration = MIN_TIMELOCK_DURATION;
        largeTransferThreshold = DEFAULT_LARGE_TRANSFER_THRESHOLD;

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governance);

        // Add guardians
        guardianCount = _guardians.length;
        for (uint256 i = 0; i < _guardians.length; i++) {
            require(_guardians[i] != address(0), "Vault: Zero guardian");
            _grantRole(GUARDIAN_ROLE, _guardians[i]);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          DEPOSIT FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit assets into vault
     * @param token Asset to deposit
     * @param amount Amount to deposit
     * @dev Only whitelisted assets can be deposited
     * 
     * **Requirements:**
     * - Asset must be whitelisted
     * - Amount > 0
     * - Sufficient allowance
     */
    function deposit(address token, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(assetConfigs[token].whitelisted, "Vault: Asset not whitelisted");
        require(amount > 0, "Vault: Zero amount");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(token, msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Deposit from CapitalPool (direct transfer)
     * @param token Asset to deposit
     * @param amount Amount to deposit
     * @dev Only callable by CapitalPool contract
     */
    function depositFromCapitalPool(address token, uint256 amount) 
        external 
        onlyRole(CAPITAL_POOL_ROLE) 
        nonReentrant 
    {
        require(assetConfigs[token].whitelisted, "Vault: Asset not whitelisted");
        require(amount > 0, "Vault: Zero amount");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(token, msg.sender, amount, block.timestamp);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                        TRANSFER REQUEST FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Request a transfer from vault
     * @param token Asset to transfer
     * @param to Recipient address
     * @param amount Amount to transfer
     * @return requestId Unique request identifier
     * @dev Creates transfer request requiring multi-sig if amount > threshold
     * 
     * **Transfer Flow:**
     * 1. Request created with timelock
     * 2. Guardians approve (M-of-N)
     * 3. After timelock, anyone can execute
     * 
     * **Small Transfers:**
     * - Below threshold: Instant execution (if CapitalPool)
     * - Above threshold: Multi-sig + timelock
     */
    function requestTransfer(
        address token,
        address to,
        uint256 amount
    ) 
        external 
        onlyRole(CAPITAL_POOL_ROLE) 
        nonReentrant 
        whenNotPaused 
        returns (bytes32 requestId) 
    {
        require(assetConfigs[token].whitelisted, "Vault: Asset not whitelisted");
        require(to != address(0), "Vault: Zero recipient");
        require(amount > 0, "Vault: Zero amount");

        // Check balance
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(amount <= balance, "Vault: Insufficient balance");

        // Check daily limit
        _checkDailyLimit(token, amount);

        // Small transfer: Instant execution
        if (amount <= largeTransferThreshold) {
            IERC20(token).safeTransfer(to, amount);
            emit TransferExecuted(bytes32(0), token, to, amount, msg.sender);
            return bytes32(0);
        }

        // Large transfer: Create request with timelock
        requestId = keccak256(abi.encodePacked(
            token,
            to,
            amount,
            msg.sender,
            requestCounter++,
            block.timestamp
        ));

        transferRequests[requestId] = TransferRequest({
            id: requestId,
            token: token,
            to: to,
            amount: amount,
            requester: msg.sender,
            approvals: 0,
            executed: false,
            cancelled: false,
            createdAt: block.timestamp,
            executeAfter: block.timestamp + timelockDuration
        });

        emit TransferRequested(
            requestId,
            token,
            to,
            amount,
            msg.sender,
            block.timestamp + timelockDuration
        );

        return requestId;
    }

    /**
     * @notice Approve a transfer request
     * @param requestId Request identifier to approve
     * @dev Only guardians can approve
     * 
     * **Requirements:**
     * - Request exists and not executed/cancelled
     * - Guardian hasn't already approved
     */
    function approveTransfer(bytes32 requestId) 
        external 
        onlyRole(GUARDIAN_ROLE) 
        nonReentrant 
    {
        TransferRequest storage request = transferRequests[requestId];
        
        require(request.createdAt > 0, "Vault: Request not found");
        require(!request.executed, "Vault: Already executed");
        require(!request.cancelled, "Vault: Request cancelled");
        require(!hasApproved[requestId][msg.sender], "Vault: Already approved");

        hasApproved[requestId][msg.sender] = true;
        request.approvals++;

        emit TransferApproved(requestId, msg.sender, request.approvals);
    }

    /**
     * @notice Execute an approved transfer request
     * @param requestId Request identifier to execute
     * @dev Can be called by anyone after timelock + sufficient approvals
     * 
     * **Requirements:**
     * - Request has required approvals
     * - Timelock period has passed
     * - Request not already executed/cancelled
     */
    function executeTransfer(bytes32 requestId) 
        external 
        nonReentrant 
    {
        TransferRequest storage request = transferRequests[requestId];
        
        require(request.createdAt > 0, "Vault: Request not found");
        require(!request.executed, "Vault: Already executed");
        require(!request.cancelled, "Vault: Request cancelled");
        require(
            request.approvals >= requiredApprovals,
            "Vault: Insufficient approvals"
        );
        require(
            block.timestamp >= request.executeAfter,
            "Vault: Timelock not passed"
        );

        request.executed = true;

        // Check daily limit again at execution time
        _checkDailyLimit(request.token, request.amount);

        // Execute transfer
        IERC20(request.token).safeTransfer(request.to, request.amount);

        emit TransferExecuted(
            requestId,
            request.token,
            request.to,
            request.amount,
            msg.sender
        );
    }

    /**
     * @notice Cancel a transfer request
     * @param requestId Request identifier to cancel
     * @dev Only requester or emergency admin can cancel
     */
    function cancelTransfer(bytes32 requestId) 
        external 
        nonReentrant 
    {
        TransferRequest storage request = transferRequests[requestId];
        
        require(request.createdAt > 0, "Vault: Request not found");
        require(!request.executed, "Vault: Already executed");
        require(!request.cancelled, "Vault: Already cancelled");
        require(
            msg.sender == request.requester || 
            hasRole(EMERGENCY_ADMIN_ROLE, msg.sender),
            "Vault: Not authorized"
        );

        request.cancelled = true;

        emit TransferCancelled(requestId, msg.sender);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          ASSET MANAGEMENT
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Whitelist an asset for vault operations
     * @param token Asset address to whitelist
     * @param dailyLimit Daily withdrawal limit for asset
     * @dev Only governance can whitelist assets
     */
    function whitelistAsset(address token, uint256 dailyLimit) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(token != address(0), "Vault: Zero token");
        require(!assetConfigs[token].whitelisted, "Vault: Already whitelisted");

        assetConfigs[token] = AssetConfig({
            token: token,
            whitelisted: true,
            dailyLimit: dailyLimit,
            withdrawnToday: 0,
            lastResetTime: block.timestamp
        });

        whitelistedTokens.push(token);

        emit AssetWhitelisted(token, dailyLimit);
    }

    /**
     * @notice Remove asset from whitelist
     * @param token Asset address to remove
     * @dev Only governance can remove assets
     */
    function removeAsset(address token) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(assetConfigs[token].whitelisted, "Vault: Not whitelisted");

        assetConfigs[token].whitelisted = false;

        emit AssetRemoved(token);
    }

    /**
     * @notice Update daily limit for an asset
     * @param token Asset address
     * @param newLimit New daily limit
     * @dev Only governance can update limits
     */
    function updateDailyLimit(address token, uint256 newLimit) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(assetConfigs[token].whitelisted, "Vault: Not whitelisted");

        uint256 oldLimit = assetConfigs[token].dailyLimit;
        assetConfigs[token].dailyLimit = newLimit;

        emit ParameterUpdated("dailyLimit", oldLimit, newLimit);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          INTERNAL FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check and update daily withdrawal limit
     * @param token Asset to check
     * @param amount Amount to withdraw
     * @dev Reverts if daily limit exceeded
     */
    function _checkDailyLimit(address token, uint256 amount) internal {
        AssetConfig storage config = assetConfigs[token];

        // Reset if new day
        if (block.timestamp >= config.lastResetTime + 1 days) {
            config.withdrawnToday = 0;
            config.lastResetTime = block.timestamp;
        }

        // Check limit
        require(
            config.withdrawnToday + amount <= config.dailyLimit,
            "Vault: Daily limit exceeded"
        );

        config.withdrawnToday += amount;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get vault balance for an asset
     * @param token Asset address
     * @return balance Current balance
     */
    function getBalance(address token) external view returns (uint256 balance) {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Get remaining daily limit for an asset
     * @param token Asset address
     * @return remaining Remaining withdrawal amount
     */
    function getRemainingDailyLimit(address token) 
        external 
        view 
        returns (uint256 remaining) 
    {
        AssetConfig storage config = assetConfigs[token];

        // If new day, full limit available
        if (block.timestamp >= config.lastResetTime + 1 days) {
            return config.dailyLimit;
        }

        return config.dailyLimit > config.withdrawnToday 
            ? config.dailyLimit - config.withdrawnToday 
            : 0;
    }

    /**
     * @notice Get number of whitelisted assets
     * @return count Asset count
     */
    function getWhitelistedAssetCount() external view returns (uint256 count) {
        return whitelistedTokens.length;
    }

    /**
     * @notice Check if transfer request is executable
     * @param requestId Request identifier
     * @return executable Whether request can be executed
     */
    function isExecutable(bytes32 requestId) external view returns (bool executable) {
        TransferRequest storage request = transferRequests[requestId];
        
        return request.createdAt > 0 &&
            !request.executed &&
            !request.cancelled &&
            request.approvals >= requiredApprovals &&
            block.timestamp >= request.executeAfter;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set CapitalPool address
     * @param capitalPool Address of CapitalPool contract
     * @dev Only admin can set
     */
    function setCapitalPool(address capitalPool) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(capitalPool != address(0), "Vault: Zero address");
        _grantRole(CAPITAL_POOL_ROLE, capitalPool);
    }

    /**
     * @notice Update required approvals
     * @param newRequired New approval threshold
     * @dev Only governance can update
     */
    function updateRequiredApprovals(uint256 newRequired) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(newRequired >= 2, "Vault: Min 2 required");
        require(newRequired <= guardianCount, "Vault: Exceeds guardian count");

        uint256 oldRequired = requiredApprovals;
        requiredApprovals = newRequired;

        emit ParameterUpdated("requiredApprovals", oldRequired, newRequired);
    }

    /**
     * @notice Update timelock duration
     * @param newDuration New timelock duration
     * @dev Only governance can update
     */
    function updateTimelockDuration(uint256 newDuration) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(newDuration >= MIN_TIMELOCK_DURATION, "Vault: Below minimum");
        require(newDuration <= MAX_TIMELOCK_DURATION, "Vault: Above maximum");

        uint256 oldDuration = timelockDuration;
        timelockDuration = newDuration;

        emit ParameterUpdated("timelockDuration", oldDuration, newDuration);
    }

    /**
     * @notice Update large transfer threshold
     * @param newThreshold New threshold value
     * @dev Only governance can update
     */
    function updateLargeTransferThreshold(uint256 newThreshold) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(newThreshold > 0, "Vault: Zero threshold");

        uint256 oldThreshold = largeTransferThreshold;
        largeTransferThreshold = newThreshold;

        emit ParameterUpdated("largeTransferThreshold", oldThreshold, newThreshold);
    }

    /**
     * @notice Emergency withdrawal (bypass all checks)
     * @param token Asset to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     * @dev Only emergency admin can execute (for critical situations)
     * 
     * **WARNING:** This function bypasses all security checks
     * Should only be used in emergency situations with DAO approval
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) 
        external 
        onlyRole(EMERGENCY_ADMIN_ROLE) 
        nonReentrant 
    {
        require(to != address(0), "Vault: Zero recipient");
        require(amount > 0, "Vault: Zero amount");

        IERC20(token).safeTransfer(to, amount);

        emit EmergencyWithdrawal(token, to, amount, msg.sender);
    }

    /**
     * @notice Add a new guardian
     * @param guardian Address to add
     * @dev Only governance can add guardians
     */
    function addGuardian(address guardian) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(guardian != address(0), "Vault: Zero guardian");
        require(!hasRole(GUARDIAN_ROLE, guardian), "Vault: Already guardian");
        
        _grantRole(GUARDIAN_ROLE, guardian);
        guardianCount++;
    }

    /**
     * @notice Remove a guardian
     * @param guardian Address to remove
     * @dev Only governance can remove guardians
     */
    function removeGuardian(address guardian) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(hasRole(GUARDIAN_ROLE, guardian), "Vault: Not a guardian");
        require(guardianCount > requiredApprovals, "Vault: Cannot remove, would break threshold");
        
        _revokeRole(GUARDIAN_ROLE, guardian);
        guardianCount--;
    }

    /**
     * @notice Pause contract (emergency only)
     * @dev Only emergency admin can pause
     */
    function pause() external onlyRole(EMERGENCY_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract
     * @dev Only emergency admin can unpause
     */
    function unpause() external onlyRole(EMERGENCY_ADMIN_ROLE) {
        _unpause();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          UPGRADE FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize upgrade to new implementation
     * @param newImplementation Address of new implementation
     * @dev Only governance can upgrade (with timelock via GovernanceManager)
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(newImplementation != address(0), "Vault: Zero implementation");
    }

    /**
     * @dev Storage gap for future upgrades
     */
    uint256[50] private __gap;
}
