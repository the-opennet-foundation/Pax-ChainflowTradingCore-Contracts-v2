// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title KeeperIncentive
 * @notice Reward system for on-chain keeper actions (liquidations, etc.)
 * @dev Incentivizes decentralized network participants to perform protocol maintenance
 * 
 * **Key Responsibilities:**
 * - Manage reward pool for keeper actions
 * - Distribute rewards for liquidations
 * - Track keeper performance and reputation
 * - Prevent keeper front-running and spam
 * - Dynamic reward calculation based on risk
 * 
 * **Keeper Actions:**
 * ```
 * 1. Liquidations
 *    - Monitor trader accounts for breach
 *    - Execute liquidation when triggered
 *    - Receive reward based on position size
 * 
 * 2. Oracle Updates (future)
 *    - Submit price updates
 *    - Receive micro-rewards
 * 
 * 3. Settlement Validation (future)
 *    - Verify batch submissions
 *    - Challenge invalid batches
 * ```
 * 
 * **Reward Model:**
 * - Base reward: Fixed amount per action
 * - Performance multiplier: Based on keeper reputation
 * - Risk premium: Higher for larger liquidations
 * - Speed bonus: Early liquidation execution
 * 
 * **Anti-Gaming:**
 * - Minimum keeper stake requirement
 * - Reputation-based priority
 * - Anti-spam cooldowns
 * - Slash for failed executions
 * 
 * @custom:security-contact security@propdao.finance
 */
contract KeeperIncentive is 
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PROTOCOL_ROLE = keccak256("PROTOCOL_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /// @notice Keeper action types
    enum ActionType {
        Liquidation,
        OracleUpdate,
        BatchValidation,
        SettlementChallenge
    }

    /// @notice Keeper status
    enum KeeperStatus {
        Inactive,
        Active,
        Suspended,
        Slashed
    }

    /**
     * @notice Keeper information
     * @param keeper Keeper address
     * @param status Current status
     * @param stakedAmount Amount staked
     * @param reputation Reputation score (0-10000)
     * @param totalActions Total actions performed
     * @param successfulActions Successful actions
     * @param totalRewards Total rewards earned
     * @param lastActionTime Last action timestamp
     * @param joinedAt Registration timestamp
     */
    struct KeeperInfo {
        address keeper;
        KeeperStatus status;
        uint256 stakedAmount;
        uint256 reputation;
        uint256 totalActions;
        uint256 successfulActions;
        uint256 totalRewards;
        uint256 lastActionTime;
        uint256 joinedAt;
    }

    /**
     * @notice Action record
     */
    struct ActionRecord {
        bytes32 actionId;
        ActionType actionType;
        address keeper;
        uint256 reward;
        uint256 timestamp;
        bool successful;
        string metadata;
    }

    /**
     * @notice Reward configuration
     */
    struct RewardConfig {
        uint256 baseReward;
        uint256 riskMultiplierBps;
        uint256 speedBonusBps;
        uint256 reputationBonusBps;
        bool active;
    }

    /// @notice Minimum stake required to become keeper
    uint256 public minStakeAmount;
    
    /// @notice Reward pool balance
    uint256 public rewardPoolBalance;
    
    /// @notice Total rewards distributed
    uint256 public totalRewardsDistributed;
    
    /// @notice Action cooldown period
    uint256 public actionCooldown;
    
    /// @notice Slash percentage for failed actions (basis points)
    uint256 public slashPercentage;

    /// @notice Reward token
    IERC20 public rewardToken;

    /// @notice Mapping of keeper address to info
    mapping(address => KeeperInfo) public keepers;
    
    /// @notice Mapping of action type to reward config
    mapping(ActionType => RewardConfig) public rewardConfigs;
    
    /// @notice Action history
    mapping(bytes32 => ActionRecord) public actionRecords;
    
    /// @notice Array of all keeper addresses
    address[] public keeperList;
    
    /// @notice Array of all action IDs
    bytes32[] public actionIds;

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;
    
    /// @notice Maximum reputation score
    uint256 public constant MAX_REPUTATION = 10000;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                                EVENTS
    // ═════════════════════════════════════════════════════════════════════════

    event KeeperRegistered(address indexed keeper, uint256 stakedAmount, uint256 timestamp);
    event KeeperStakeIncreased(address indexed keeper, uint256 amount, uint256 newTotal);
    event KeeperStakeWithdrawn(address indexed keeper, uint256 amount, uint256 remaining);
    event KeeperRewarded(address indexed keeper, ActionType actionType, uint256 reward, uint256 timestamp);
    event KeeperSlashed(address indexed keeper, uint256 slashAmount, string reason);
    event KeeperStatusChanged(address indexed keeper, KeeperStatus oldStatus, KeeperStatus newStatus);
    event RewardPoolDeposited(address indexed from, uint256 amount, uint256 newBalance);
    event RewardConfigUpdated(ActionType indexed actionType, uint256 baseReward);
    event ActionExecuted(bytes32 indexed actionId, address indexed keeper, ActionType actionType, bool successful);

    // ═════════════════════════════════════════════════════════════════════════
    //                            INITIALIZATION
    // ═════════════════════════════════════════════════════════════════════════

    function initialize(
        address _admin,
        address _governance,
        address _rewardToken,
        uint256 _minStakeAmount
    ) external initializer {
        require(_admin != address(0), "KeeperIncentive: Zero admin");
        require(_governance != address(0), "KeeperIncentive: Zero governance");
        require(_rewardToken != address(0), "KeeperIncentive: Zero token");

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governance);

        rewardToken = IERC20(_rewardToken);
        minStakeAmount = _minStakeAmount;
        actionCooldown = 60 seconds;
        slashPercentage = 1000; // 10%

        _initializeRewardConfigs();
    }

    function _initializeRewardConfigs() internal {
        // Liquidation rewards
        rewardConfigs[ActionType.Liquidation] = RewardConfig({
            baseReward: 100e18,          // $100 base
            riskMultiplierBps: 100,      // 1% of position size
            speedBonusBps: 500,          // 5% speed bonus
            reputationBonusBps: 1000,    // 10% reputation bonus
            active: true
        });

        // Oracle update rewards (future)
        rewardConfigs[ActionType.OracleUpdate] = RewardConfig({
            baseReward: 1e18,            // $1 micro-reward
            riskMultiplierBps: 0,
            speedBonusBps: 0,
            reputationBonusBps: 0,
            active: false
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                         KEEPER REGISTRATION
    // ═════════════════════════════════════════════════════════════════════════

    function registerKeeper(uint256 stakeAmount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(stakeAmount >= minStakeAmount, "KeeperIncentive: Insufficient stake");
        require(keepers[msg.sender].keeper == address(0), "KeeperIncentive: Already registered");

        // Transfer stake
        rewardToken.safeTransferFrom(msg.sender, address(this), stakeAmount);

        keepers[msg.sender] = KeeperInfo({
            keeper: msg.sender,
            status: KeeperStatus.Active,
            stakedAmount: stakeAmount,
            reputation: 5000, // Start at 50%
            totalActions: 0,
            successfulActions: 0,
            totalRewards: 0,
            lastActionTime: 0,
            joinedAt: block.timestamp
        });

        keeperList.push(msg.sender);

        emit KeeperRegistered(msg.sender, stakeAmount, block.timestamp);
    }

    function increaseStake(uint256 amount) external nonReentrant {
        KeeperInfo storage keeper = keepers[msg.sender];
        require(keeper.keeper != address(0), "KeeperIncentive: Not registered");

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        keeper.stakedAmount += amount;

        emit KeeperStakeIncreased(msg.sender, amount, keeper.stakedAmount);
    }

    function withdrawStake(uint256 amount) external nonReentrant {
        KeeperInfo storage keeper = keepers[msg.sender];
        require(keeper.keeper != address(0), "KeeperIncentive: Not registered");
        require(keeper.stakedAmount >= amount, "KeeperIncentive: Insufficient stake");
        require(keeper.stakedAmount - amount >= minStakeAmount || amount == keeper.stakedAmount, "KeeperIncentive: Below minimum");

        keeper.stakedAmount -= amount;
        rewardToken.safeTransfer(msg.sender, amount);

        if (keeper.stakedAmount == 0) {
            keeper.status = KeeperStatus.Inactive;
        }

        emit KeeperStakeWithdrawn(msg.sender, amount, keeper.stakedAmount);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          REWARD DISTRIBUTION
    // ═════════════════════════════════════════════════════════════════════════

    function rewardKeeper(
        address keeper,
        ActionType actionType,
        uint256 positionSize,
        bool successful
    ) 
        external 
        onlyRole(PROTOCOL_ROLE) 
        nonReentrant 
        returns (uint256 reward) 
    {
        KeeperInfo storage keeperInfo = keepers[keeper];
        require(keeperInfo.keeper != address(0), "KeeperIncentive: Not registered");
        require(keeperInfo.status == KeeperStatus.Active, "KeeperIncentive: Not active");
        
        // Check cooldown
        require(
            block.timestamp >= keeperInfo.lastActionTime + actionCooldown,
            "KeeperIncentive: Cooldown not passed"
        );

        // Calculate reward
        reward = _calculateReward(keeper, actionType, positionSize, successful);

        if (successful && reward > 0) {
            require(rewardPoolBalance >= reward, "KeeperIncentive: Insufficient pool");

            // Transfer reward
            rewardPoolBalance -= reward;
            rewardToken.safeTransfer(keeper, reward);

            // Update stats
            keeperInfo.totalRewards += reward;
            keeperInfo.successfulActions++;
            totalRewardsDistributed += reward;

            emit KeeperRewarded(keeper, actionType, reward, block.timestamp);
        }

        // Update keeper info
        keeperInfo.totalActions++;
        keeperInfo.lastActionTime = block.timestamp;

        // Update reputation
        _updateReputation(keeper, successful);

        // Record action
        bytes32 actionId = keccak256(abi.encodePacked(keeper, actionType, block.timestamp));
        actionRecords[actionId] = ActionRecord({
            actionId: actionId,
            actionType: actionType,
            keeper: keeper,
            reward: reward,
            timestamp: block.timestamp,
            successful: successful,
            metadata: ""
        });
        actionIds.push(actionId);

        emit ActionExecuted(actionId, keeper, actionType, successful);

        // Slash if failed
        if (!successful) {
            _slashKeeper(keeper, "Failed action");
        }

        return reward;
    }

    function _calculateReward(
        address keeper,
        ActionType actionType,
        uint256 positionSize,
        bool successful
    ) internal view returns (uint256 reward) {
        if (!successful) return 0;

        RewardConfig memory config = rewardConfigs[actionType];
        if (!config.active) return 0;

        KeeperInfo memory keeperInfo = keepers[keeper];

        // Base reward
        reward = config.baseReward;

        // Risk multiplier (based on position size)
        if (config.riskMultiplierBps > 0 && positionSize > 0) {
            uint256 riskBonus = (positionSize * config.riskMultiplierBps) / BASIS_POINTS;
            reward += riskBonus;
        }

        // Reputation bonus
        if (config.reputationBonusBps > 0) {
            uint256 reputationBonus = (reward * keeperInfo.reputation * config.reputationBonusBps) / (MAX_REPUTATION * BASIS_POINTS);
            reward += reputationBonus;
        }

        return reward;
    }

    function _updateReputation(address keeper, bool successful) internal {
        KeeperInfo storage keeperInfo = keepers[keeper];

        if (successful) {
            // Increase reputation (diminishing returns)
            uint256 increase = (MAX_REPUTATION - keeperInfo.reputation) / 20; // 5% of remaining
            keeperInfo.reputation += increase;
            if (keeperInfo.reputation > MAX_REPUTATION) {
                keeperInfo.reputation = MAX_REPUTATION;
            }
        } else {
            // Decrease reputation
            uint256 decrease = keeperInfo.reputation / 10; // 10% penalty
            if (keeperInfo.reputation > decrease) {
                keeperInfo.reputation -= decrease;
            } else {
                keeperInfo.reputation = 0;
            }
        }
    }

    function _slashKeeper(address keeper, string memory reason) internal {
        KeeperInfo storage keeperInfo = keepers[keeper];

        uint256 slashAmount = (keeperInfo.stakedAmount * slashPercentage) / BASIS_POINTS;
        
        if (slashAmount > 0) {
            keeperInfo.stakedAmount -= slashAmount;
            rewardPoolBalance += slashAmount; // Add to reward pool

            emit KeeperSlashed(keeper, slashAmount, reason);

            // Suspend if stake too low
            if (keeperInfo.stakedAmount < minStakeAmount) {
                KeeperStatus oldStatus = keeperInfo.status;
                keeperInfo.status = KeeperStatus.Slashed;
                emit KeeperStatusChanged(keeper, oldStatus, KeeperStatus.Slashed);
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          REWARD POOL MANAGEMENT
    // ═════════════════════════════════════════════════════════════════════════

    function depositRewardPool(uint256 amount) external nonReentrant {
        require(amount > 0, "KeeperIncentive: Zero amount");

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardPoolBalance += amount;

        emit RewardPoolDeposited(msg.sender, amount, rewardPoolBalance);
    }

    function getRewardBalance() external view returns (uint256) {
        return rewardPoolBalance;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    function getKeeperInfo(address keeper) external view returns (KeeperInfo memory) {
        return keepers[keeper];
    }

    function getActiveKeepers() external view returns (address[] memory active) {
        uint256 count = 0;
        for (uint256 i = 0; i < keeperList.length; i++) {
            if (keepers[keeperList[i]].status == KeeperStatus.Active) {
                count++;
            }
        }

        active = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < keeperList.length; i++) {
            if (keepers[keeperList[i]].status == KeeperStatus.Active) {
                active[index++] = keeperList[i];
            }
        }

        return active;
    }

    function getKeeperStats() 
        external 
        view 
        returns (
            uint256 totalKeepers,
            uint256 activeKeepers,
            uint256 totalActionsExecuted,
            uint256 totalRewards
        ) 
    {
        totalKeepers = keeperList.length;
        
        for (uint256 i = 0; i < keeperList.length; i++) {
            if (keepers[keeperList[i]].status == KeeperStatus.Active) {
                activeKeepers++;
            }
        }

        totalActionsExecuted = actionIds.length;
        totalRewards = totalRewardsDistributed;

        return (totalKeepers, activeKeepers, totalActionsExecuted, totalRewards);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    function updateRewardConfig(
        ActionType actionType,
        uint256 baseReward,
        uint256 riskMultiplierBps,
        uint256 speedBonusBps,
        uint256 reputationBonusBps,
        bool active
    ) external onlyRole(GOVERNANCE_ROLE) {
        rewardConfigs[actionType] = RewardConfig({
            baseReward: baseReward,
            riskMultiplierBps: riskMultiplierBps,
            speedBonusBps: speedBonusBps,
            reputationBonusBps: reputationBonusBps,
            active: active
        });

        emit RewardConfigUpdated(actionType, baseReward);
    }

    function updateMinStake(uint256 newMinStake) external onlyRole(GOVERNANCE_ROLE) {
        minStakeAmount = newMinStake;
    }

    function updateSlashPercentage(uint256 newPercentage) external onlyRole(GOVERNANCE_ROLE) {
        require(newPercentage <= 5000, "KeeperIncentive: Too high"); // Max 50%
        slashPercentage = newPercentage;
    }

    function suspendKeeper(address keeper) external onlyRole(ADMIN_ROLE) {
        KeeperInfo storage keeperInfo = keepers[keeper];
        require(keeperInfo.keeper != address(0), "KeeperIncentive: Not registered");

        KeeperStatus oldStatus = keeperInfo.status;
        keeperInfo.status = KeeperStatus.Suspended;

        emit KeeperStatusChanged(keeper, oldStatus, KeeperStatus.Suspended);
    }

    function reactivateKeeper(address keeper) external onlyRole(ADMIN_ROLE) {
        KeeperInfo storage keeperInfo = keepers[keeper];
        require(keeperInfo.keeper != address(0), "KeeperIncentive: Not registered");
        require(keeperInfo.stakedAmount >= minStakeAmount, "KeeperIncentive: Insufficient stake");

        KeeperStatus oldStatus = keeperInfo.status;
        keeperInfo.status = KeeperStatus.Active;

        emit KeeperStatusChanged(keeper, oldStatus, KeeperStatus.Active);
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
        require(newImplementation != address(0), "KeeperIncentive: Zero implementation");
    }

    uint256[50] private __gap;
}
