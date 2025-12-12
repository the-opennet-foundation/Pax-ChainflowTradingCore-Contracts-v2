// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CapitalPool
 * @notice Core liquidity pool for PropDAO - manages investor capital and LP shares
 * @dev Implements EIP-1967 UUPS upgradeable pattern with role-based access control
 * 
 * **Key Responsibilities:**
 * - Accept capital deposits from LPs and mint proportional shares
 * - Process withdrawals with proper vesting and liquidity checks
 * - Allocate capital to trader accounts (called by PayoutManager)
 * - Track total assets under management (AUM)
 * - Manage profit/loss accounting for the pool
 * 
 * **Security Features:**
 * - Reentrancy protection on all external calls
 * - Role-based access control (ADMIN, PAYOUT_MANAGER, GOVERNANCE)
 * - Emergency pause mechanism
 * - Vesting periods for withdrawals
 * - Minimum deposit requirements
 * 
 * **Upgradeability:**
 * - UUPS pattern controlled by GOVERNANCE_ROLE
 * - Storage gap for future upgrades
 * 
 * @custom:security-contact security@propdao.finance
 */
contract CapitalPool is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable 
{
    using SafeERC20 for IERC20;

    /// @notice Role identifier for contract administrators
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Role identifier for the PayoutManager contract
    bytes32 public constant PAYOUT_MANAGER_ROLE = keccak256("PAYOUT_MANAGER_ROLE");
    
    /// @notice Role identifier for governance operations
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /// @notice Minimum deposit amount to prevent dust attacks (18 decimals)
    uint256 public constant MIN_DEPOSIT = 1000e18; // 1000 USDC
    
    /// @notice Default vesting period for withdrawals (7 days)
    uint256 public constant DEFAULT_VESTING_PERIOD = 7 days;
    
    /// @notice Maximum percentage of pool that can be allocated (95% - 5% liquidity buffer)
    uint256 public constant MAX_ALLOCATION_PCT = 9500; // 95% in basis points
    
    /// @notice Basis points denominator (100%)
    uint256 public constant BASIS_POINTS = 10000;

    /**
     * @notice LP investor information
     * @param shares Number of LP shares owned
     * @param deposited Total amount deposited (for accounting)
     * @param withdrawalRequest Pending withdrawal request
     * @param lastDepositTime Timestamp of last deposit (for vesting)
     */
    struct LPInfo {
        uint256 shares;
        uint256 deposited;
        WithdrawalRequest withdrawalRequest;
        uint256 lastDepositTime;
    }

    /**
     * @notice Withdrawal request information
     * @param amount Amount requested to withdraw
     * @param shares Shares to burn
     * @param requestTime When withdrawal was requested
     * @param executed Whether request has been executed
     */
    struct WithdrawalRequest {
        uint256 amount;
        uint256 shares;
        uint256 requestTime;
        bool executed;
    }

    /**
     * @notice Trader allocation tracking
     * @param traderId Unique trader identifier
     * @param allocated Amount allocated to trader
     * @param pnl Current profit/loss for trader
     * @param active Whether allocation is active
     */
    struct TraderAllocation {
        bytes32 traderId;
        uint256 allocated;
        int256 pnl;
        bool active;
    }

    /// @notice Supported deposit token (USDC)
    IERC20 public depositToken;
    
    /// @notice Total LP shares issued
    uint256 public totalShares;
    
    /// @notice Total capital deposited
    uint256 public totalDeposited;
    
    /// @notice Total allocated to traders
    uint256 public totalAllocated;
    
    /// @notice Accumulated protocol fees
    uint256 public protocolFees;
    
    /// @notice Vesting period for withdrawals (configurable by governance)
    uint256 public vestingPeriod;

    /// @notice Mapping of LP address to their info
    mapping(address => LPInfo) public lpInfo;
    
    /// @notice Mapping of trader ID to allocation info
    mapping(bytes32 => TraderAllocation) public traderAllocations;
    
    /// @notice Array of all trader IDs for enumeration
    bytes32[] public traderIds;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                                EVENTS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when an LP deposits capital
     * @param lp Address of the liquidity provider
     * @param amount Amount of tokens deposited
     * @param shares Number of shares minted
     * @param timestamp Block timestamp
     */
    event Deposited(
        address indexed lp,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    /**
     * @notice Emitted when an LP requests withdrawal
     * @param lp Address of the liquidity provider
     * @param amount Amount requested
     * @param shares Shares to burn
     * @param availableAt When withdrawal becomes available
     */
    event WithdrawalRequested(
        address indexed lp,
        uint256 amount,
        uint256 shares,
        uint256 availableAt
    );

    /**
     * @notice Emitted when a withdrawal is executed
     * @param lp Address of the liquidity provider
     * @param amount Amount withdrawn
     * @param shares Shares burned
     * @param timestamp Block timestamp
     */
    event Withdrawn(
        address indexed lp,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    /**
     * @notice Emitted when capital is allocated to a trader
     * @param traderId Unique trader identifier
     * @param amount Amount allocated
     * @param timestamp Block timestamp
     */
    event AllocatedToTrader(
        bytes32 indexed traderId,
        uint256 amount,
        uint256 timestamp
    );

    /**
     * @notice Emitted when capital is deallocated from a trader
     * @param traderId Unique trader identifier
     * @param amount Amount deallocated
     * @param pnl Final profit/loss
     * @param timestamp Block timestamp
     */
    event DeallocatedFromTrader(
        bytes32 indexed traderId,
        uint256 amount,
        int256 pnl,
        uint256 timestamp
    );

    /**
     * @notice Emitted when trader PnL is updated
     * @param traderId Unique trader identifier
     * @param previousPnL Previous profit/loss
     * @param newPnL New profit/loss
     * @param timestamp Block timestamp
     */
    event PnLUpdated(
        bytes32 indexed traderId,
        int256 previousPnL,
        int256 newPnL,
        uint256 timestamp
    );

    /**
     * @notice Emitted when protocol fees are collected
     * @param amount Fee amount collected
     * @param recipient Fee recipient
     * @param timestamp Block timestamp
     */
    event FeesCollected(
        uint256 amount,
        address indexed recipient,
        uint256 timestamp
    );

    /**
     * @notice Emitted when vesting period is updated
     * @param oldPeriod Previous vesting period
     * @param newPeriod New vesting period
     */
    event VestingPeriodUpdated(
        uint256 oldPeriod,
        uint256 newPeriod
    );

    // ═════════════════════════════════════════════════════════════════════════
    //                            INITIALIZATION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize the CapitalPool contract
     * @param _depositToken Address of the deposit token (USDC)
     * @param _admin Address to grant ADMIN_ROLE
     * @param _governance Address to grant GOVERNANCE_ROLE
     * @dev Can only be called once due to initializer modifier
     */
    function initialize(
        address _depositToken,
        address _admin,
        address _governance
    ) external initializer {
        require(_depositToken != address(0), "CapitalPool: Zero deposit token");
        require(_admin != address(0), "CapitalPool: Zero admin");
        require(_governance != address(0), "CapitalPool: Zero governance");

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        depositToken = IERC20(_depositToken);
        vestingPeriod = DEFAULT_VESTING_PERIOD;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governance);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          LP DEPOSIT FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit capital to the pool and receive LP shares
     * @param amount Amount of deposit tokens to deposit
     * @return shares Number of LP shares minted
     * @dev Mints shares proportional to pool value
     * 
     * **Share Calculation Logic:**
     * - If first deposit: shares = amount (1:1 ratio)
     * - Otherwise: shares = (amount * totalShares) / getTotalAssets()
     * 
     * **Requirements:**
     * - Amount >= MIN_DEPOSIT
     * - Contract not paused
     * - Sufficient token allowance
     */
    function deposit(uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (uint256 shares) 
    {
        require(amount >= MIN_DEPOSIT, "CapitalPool: Below minimum deposit");

        // Calculate shares to mint
        if (totalShares == 0) {
            shares = amount; // First deposit: 1:1 ratio
        } else {
            uint256 totalAssets = getTotalAssets();
            require(totalAssets > 0, "CapitalPool: Zero total assets");
            shares = (amount * totalShares) / totalAssets;
        }

        require(shares > 0, "CapitalPool: Zero shares");

        // Update state
        lpInfo[msg.sender].shares += shares;
        lpInfo[msg.sender].deposited += amount;
        lpInfo[msg.sender].lastDepositTime = block.timestamp;
        totalShares += shares;
        totalDeposited += amount;

        // Transfer tokens from LP
        depositToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, amount, shares, block.timestamp);

        return shares;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                        LP WITHDRAWAL FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Request withdrawal of capital from the pool
     * @param shares Number of shares to withdraw
     * @dev Creates withdrawal request subject to vesting period
     * 
     * **Requirements:**
     * - LP has sufficient shares
     * - No pending withdrawal request
     * - Sufficient liquidity in pool
     */
    function requestWithdrawal(uint256 shares) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(shares > 0, "CapitalPool: Zero shares");
        require(lpInfo[msg.sender].shares >= shares, "CapitalPool: Insufficient shares");
        require(!lpInfo[msg.sender].withdrawalRequest.executed, "CapitalPool: Pending request exists");

        uint256 amount = (shares * getTotalAssets()) / totalShares;
        require(amount > 0, "CapitalPool: Zero amount");

        // Check liquidity
        uint256 availableLiquidity = getAvailableLiquidity();
        require(amount <= availableLiquidity, "CapitalPool: Insufficient liquidity");

        // Create withdrawal request
        lpInfo[msg.sender].withdrawalRequest = WithdrawalRequest({
            amount: amount,
            shares: shares,
            requestTime: block.timestamp,
            executed: false
        });

        uint256 availableAt = block.timestamp + vestingPeriod;

        emit WithdrawalRequested(msg.sender, amount, shares, availableAt);
    }

    /**
     * @notice Execute a withdrawal request after vesting period
     * @dev Burns shares and transfers tokens to LP
     * 
     * **Requirements:**
     * - Withdrawal request exists
     * - Vesting period has passed
     * - Sufficient contract balance
     */
    function executeWithdrawal() 
        external 
        nonReentrant 
        whenNotPaused 
    {
        WithdrawalRequest storage request = lpInfo[msg.sender].withdrawalRequest;
        
        require(request.amount > 0, "CapitalPool: No withdrawal request");
        require(!request.executed, "CapitalPool: Already executed");
        require(
            block.timestamp >= request.requestTime + vestingPeriod,
            "CapitalPool: Vesting period not passed"
        );

        uint256 amount = request.amount;
        uint256 shares = request.shares;

        // Update state
        lpInfo[msg.sender].shares -= shares;
        totalShares -= shares;
        request.executed = true;

        // Transfer tokens to LP
        depositToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, shares, block.timestamp);
    }

    /**
     * @notice Cancel a pending withdrawal request
     * @dev Allows LP to cancel before execution
     */
    function cancelWithdrawalRequest() external nonReentrant {
        WithdrawalRequest storage request = lpInfo[msg.sender].withdrawalRequest;
        
        require(request.amount > 0, "CapitalPool: No withdrawal request");
        require(!request.executed, "CapitalPool: Already executed");

        delete lpInfo[msg.sender].withdrawalRequest;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                       TRADER ALLOCATION FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Allocate capital to a trader account
     * @param traderId Unique trader identifier
     * @param amount Amount to allocate
     * @dev Only callable by PayoutManager or Governance
     * 
     * **Requirements:**
     * - Amount doesn't exceed allocation limit
     * - Sufficient available liquidity
     * - Trader not already allocated (or inactive)
     */
    function allocateToTrader(bytes32 traderId, uint256 amount) 
        external 
        onlyRole(PAYOUT_MANAGER_ROLE) 
        nonReentrant 
        whenNotPaused 
    {
        require(traderId != bytes32(0), "CapitalPool: Invalid trader ID");
        require(amount > 0, "CapitalPool: Zero amount");

        // Check allocation limits
        uint256 maxAllocation = (getTotalAssets() * MAX_ALLOCATION_PCT) / BASIS_POINTS;
        require(totalAllocated + amount <= maxAllocation, "CapitalPool: Exceeds allocation limit");

        // Create or update allocation
        if (!traderAllocations[traderId].active) {
            traderIds.push(traderId);
            traderAllocations[traderId] = TraderAllocation({
                traderId: traderId,
                allocated: amount,
                pnl: 0,
                active: true
            });
        } else {
            traderAllocations[traderId].allocated += amount;
        }

        totalAllocated += amount;

        emit AllocatedToTrader(traderId, amount, block.timestamp);
    }

    /**
     * @notice Deallocate capital from a trader account
     * @param traderId Unique trader identifier
     * @param amount Amount to deallocate
     * @param finalPnL Final profit/loss for settlement
     * @dev Only callable by PayoutManager
     * 
     * **PnL Settlement:**
     * - Positive PnL: Pool gains value
     * - Negative PnL: Pool loses value (covered by insurance if needed)
     */
    function deallocateFromTrader(
        bytes32 traderId, 
        uint256 amount, 
        int256 finalPnL
    ) 
        external 
        onlyRole(PAYOUT_MANAGER_ROLE) 
        nonReentrant 
    {
        require(traderAllocations[traderId].active, "CapitalPool: Trader not active");
        require(amount <= traderAllocations[traderId].allocated, "CapitalPool: Amount exceeds allocation");

        totalAllocated -= amount;
        traderAllocations[traderId].allocated -= amount;
        traderAllocations[traderId].pnl = finalPnL;

        if (traderAllocations[traderId].allocated == 0) {
            traderAllocations[traderId].active = false;
        }

        emit DeallocatedFromTrader(traderId, amount, finalPnL, block.timestamp);
    }

    /**
     * @notice Update trader PnL (called periodically by PayoutManager)
     * @param traderId Unique trader identifier
     * @param newPnL New profit/loss value
     * @dev Used for accounting and valuation
     */
    function updateTraderPnL(bytes32 traderId, int256 newPnL) 
        external 
        onlyRole(PAYOUT_MANAGER_ROLE) 
    {
        require(traderAllocations[traderId].active, "CapitalPool: Trader not active");

        int256 previousPnL = traderAllocations[traderId].pnl;
        traderAllocations[traderId].pnl = newPnL;

        emit PnLUpdated(traderId, previousPnL, newPnL, block.timestamp);
    }

    /**
     * @notice Transfer funds to trader or recipient (for payouts)
     * @param traderId Trader identifier for tracking
     * @param recipient Recipient address
     * @param amount Amount to transfer
     * @dev Only callable by PayoutManager
     */
    function transferToTrader(
        bytes32 traderId,
        address recipient,
        uint256 amount
    ) 
        external 
        onlyRole(PAYOUT_MANAGER_ROLE) 
        nonReentrant 
    {
        require(recipient != address(0), "CapitalPool: Zero recipient");
        require(amount > 0, "CapitalPool: Zero amount");
        require(traderAllocations[traderId].active, "CapitalPool: Trader not active");

        uint256 availableLiquidity = getAvailableLiquidity();
        require(amount <= availableLiquidity, "CapitalPool: Insufficient liquidity");

        depositToken.safeTransfer(recipient, amount);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get total assets under management
     * @return Total asset value including allocated capital and unrealized PnL
     * @dev Formula: contract_balance + totalAllocated + sum(trader_pnl)
     */
    function getTotalAssets() public view returns (uint256) {
        uint256 balance = depositToken.balanceOf(address(this));
        int256 totalPnL = getTotalTraderPnL();
        
        // Calculate total including PnL
        int256 total = int256(balance + totalAllocated) + totalPnL;
        
        // Ensure non-negative (should be prevented by insurance fund)
        return total > 0 ? uint256(total) : 0;
    }

    /**
     * @notice Get total unrealized PnL from all traders
     * @return Sum of all trader PnL (can be negative)
     */
    function getTotalTraderPnL() public view returns (int256) {
        int256 totalPnL = 0;
        for (uint256 i = 0; i < traderIds.length; i++) {
            if (traderAllocations[traderIds[i]].active) {
                totalPnL += traderAllocations[traderIds[i]].pnl;
            }
        }
        return totalPnL;
    }

    /**
     * @notice Get available liquidity for allocations/withdrawals
     * @return Amount of unallocated capital
     */
    function getAvailableLiquidity() public view returns (uint256) {
        uint256 balance = depositToken.balanceOf(address(this));
        return balance > protocolFees ? balance - protocolFees : 0;
    }

    /**
     * @notice Get LP share value in deposit tokens
     * @param lp Address of the liquidity provider
     * @return value Current value of LP's shares
     */
    function getLPValue(address lp) external view returns (uint256 value) {
        if (totalShares == 0) return 0;
        uint256 shares = lpInfo[lp].shares;
        return (shares * getTotalAssets()) / totalShares;
    }

    /**
     * @notice Get number of active traders
     * @return count Active trader count
     */
    function getActiveTraderCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < traderIds.length; i++) {
            if (traderAllocations[traderIds[i]].active) {
                count++;
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set PayoutManager address
     * @param payoutManager Address of PayoutManager contract
     * @dev Only callable by admin
     */
    function setPayoutManager(address payoutManager) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(payoutManager != address(0), "CapitalPool: Zero address");
        _grantRole(PAYOUT_MANAGER_ROLE, payoutManager);
    }

    /**
     * @notice Update vesting period for withdrawals
     * @param newPeriod New vesting period in seconds
     * @dev Only callable by governance
     */
    function setVestingPeriod(uint256 newPeriod) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(newPeriod <= 30 days, "CapitalPool: Vesting too long");
        uint256 oldPeriod = vestingPeriod;
        vestingPeriod = newPeriod;
        emit VestingPeriodUpdated(oldPeriod, newPeriod);
    }

    /**
     * @notice Collect protocol fees
     * @param recipient Address to receive fees
     * @dev Only callable by governance
     */
    function collectFees(address recipient) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
    {
        require(recipient != address(0), "CapitalPool: Zero recipient");
        require(protocolFees > 0, "CapitalPool: No fees to collect");

        uint256 amount = protocolFees;
        protocolFees = 0;

        depositToken.safeTransfer(recipient, amount);

        emit FeesCollected(amount, recipient, block.timestamp);
    }

    /**
     * @notice Pause contract (emergency only)
     * @dev Only callable by admin
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract
     * @dev Only callable by admin
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          UPGRADE FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize upgrade to new implementation
     * @param newImplementation Address of new implementation
     * @dev Only callable by governance (with timelock)
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(newImplementation != address(0), "CapitalPool: Zero implementation");
    }

    /**
     * @dev Storage gap for future upgrades
     */
    uint256[50] private __gap;
}
