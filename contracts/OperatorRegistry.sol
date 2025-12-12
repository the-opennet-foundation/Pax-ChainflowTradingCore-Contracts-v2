// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title OperatorRegistry
 * @notice Central registry for authorized off-chain operators (execution engines)
 * @dev Single source of truth for operator permissions across all contracts
 * 
 * **Key Responsibilities:**
 * - Maintain whitelist of authorized operator addresses
 * - Track operator metadata (status, registration time, approver)
 * - Provide verification interface for other contracts
 * - Support multi-operator architecture for redundancy
 * - Emit events for operator lifecycle changes
 * 
 * **Operator Model:**
 * ```
 * Operators = Off-chain execution engines that:
 * - Sign trade settlement batches
 * - Authorize trader registrations (post-KYC)
 * - Sign payout requests
 * - Submit Merkle roots to TradeLedger
 * ```
 * 
 * **Security Model:**
 * - Multiple operators supported (no single point of failure)
 * - Governance-controlled additions/removals
 * - Emergency suspension capability
 * - Immutable audit trail of all changes
 * 
 * **Integration Points:**
 * - TraderAccountRegistry: Verifies operator signatures for registration
 * - TradeLedger: Verifies operator for batch submission
 * - PayoutManager: Verifies operator signatures for payouts
 * 
 * @custom:security-contact security@propdao.finance
 */
contract OperatorRegistry is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable 
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /**
     * @notice Operator status enumeration
     */
    enum OperatorStatus {
        Inactive,      // Not an operator or removed
        Active,        // Currently authorized
        Suspended      // Temporarily suspended
    }

    /**
     * @notice Operator information
     * @param operator Operator address
     * @param status Current status
     * @param addedBy Address that added this operator
     * @param addedAt Timestamp when added
     * @param lastStatusChange Last status change timestamp
     * @param batchesSubmitted Number of batches submitted
     * @param metadata IPFS hash or description
     */
    struct OperatorInfo {
        address operator;
        OperatorStatus status;
        address addedBy;
        uint256 addedAt;
        uint256 lastStatusChange;
        uint256 batchesSubmitted;
        string metadata;
    }

    /// @notice Mapping of operator address to operator info
    mapping(address => OperatorInfo) public operators;

    /// @notice Array of all operator addresses (for enumeration)
    address[] public operatorList;

    /// @notice Total number of active operators
    uint256 public activeOperatorCount;

    /// @notice Total number of operators ever added
    uint256 public totalOperatorsAdded;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                                EVENTS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when an operator is added
     * @param operator Operator address
     * @param addedBy Address that added the operator
     * @param timestamp Addition timestamp
     * @param metadata Operator metadata
     */
    event OperatorAdded(
        address indexed operator,
        address indexed addedBy,
        uint256 timestamp,
        string metadata
    );

    /**
     * @notice Emitted when an operator is removed
     * @param operator Operator address
     * @param removedBy Address that removed the operator
     * @param timestamp Removal timestamp
     */
    event OperatorRemoved(
        address indexed operator,
        address indexed removedBy,
        uint256 timestamp
    );

    /**
     * @notice Emitted when an operator is suspended
     * @param operator Operator address
     * @param suspendedBy Address that suspended the operator
     * @param timestamp Suspension timestamp
     * @param reason Suspension reason
     */
    event OperatorSuspended(
        address indexed operator,
        address indexed suspendedBy,
        uint256 timestamp,
        string reason
    );

    /**
     * @notice Emitted when an operator is reactivated
     * @param operator Operator address
     * @param reactivatedBy Address that reactivated the operator
     * @param timestamp Reactivation timestamp
     */
    event OperatorReactivated(
        address indexed operator,
        address indexed reactivatedBy,
        uint256 timestamp
    );

    /**
     * @notice Emitted when operator submits a batch
     * @param operator Operator address
     * @param batchCount New total batch count
     */
    event OperatorBatchSubmitted(
        address indexed operator,
        uint256 batchCount
    );

    // ═════════════════════════════════════════════════════════════════════════
    //                            INITIALIZATION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize the OperatorRegistry contract
     * @param _admin Address to grant admin roles
     * @param _governance Address to grant governance role
     * @param _initialOperators Array of initial operator addresses
     * @param _operatorMetadata Array of metadata for initial operators
     * @dev Can only be called once due to initializer modifier
     */
    function initialize(
        address _admin,
        address _governance,
        address[] memory _initialOperators,
        string[] memory _operatorMetadata
    ) external initializer {
        require(_admin != address(0), "OperatorRegistry: Zero admin");
        require(_governance != address(0), "OperatorRegistry: Zero governance");
        require(
            _initialOperators.length == _operatorMetadata.length,
            "OperatorRegistry: Length mismatch"
        );

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governance);

        // Add initial operators
        for (uint256 i = 0; i < _initialOperators.length; i++) {
            _addOperator(_initialOperators[i], _operatorMetadata[i], _admin);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                       OPERATOR MANAGEMENT
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Add a new operator
     * @param operator Address to add as operator
     * @param metadata IPFS hash or description
     * @dev Only governance can add operators
     * 
     * **Requirements:**
     * - Caller must have GOVERNANCE_ROLE
     * - Operator address not zero
     * - Operator not already active
     * 
     * **Use Cases:**
     * - Adding new execution engine instance
     * - Replacing compromised operator
     * - Scaling to multi-region deployment
     */
    function addOperator(address operator, string calldata metadata) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
    {
        _addOperator(operator, metadata, msg.sender);
    }

    /**
     * @notice Internal function to add operator
     * @param operator Operator address
     * @param metadata Operator metadata
     * @param addedBy Address adding the operator
     */
    function _addOperator(
        address operator,
        string memory metadata,
        address addedBy
    ) internal {
        require(operator != address(0), "OperatorRegistry: Zero operator");
        require(
            operators[operator].status == OperatorStatus.Inactive,
            "OperatorRegistry: Already active"
        );

        operators[operator] = OperatorInfo({
            operator: operator,
            status: OperatorStatus.Active,
            addedBy: addedBy,
            addedAt: block.timestamp,
            lastStatusChange: block.timestamp,
            batchesSubmitted: 0,
            metadata: metadata
        });

        operatorList.push(operator);
        activeOperatorCount++;
        totalOperatorsAdded++;

        emit OperatorAdded(operator, addedBy, block.timestamp, metadata);
    }

    /**
     * @notice Remove an operator
     * @param operator Address to remove
     * @dev Only governance can remove operators
     * 
     * **Requirements:**
     * - Caller must have GOVERNANCE_ROLE
     * - Operator must be active or suspended
     * - At least one other active operator remains
     * 
     * **Use Cases:**
     * - Decommissioning execution engine
     * - Removing compromised operator
     * - Rotating operator keys
     */
    function removeOperator(address operator) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
    {
        require(operator != address(0), "OperatorRegistry: Zero operator");
        require(
            operators[operator].status != OperatorStatus.Inactive,
            "OperatorRegistry: Not active"
        );
        require(
            activeOperatorCount > 1,
            "OperatorRegistry: Cannot remove last operator"
        );

        OperatorStatus oldStatus = operators[operator].status;
        operators[operator].status = OperatorStatus.Inactive;
        operators[operator].lastStatusChange = block.timestamp;

        if (oldStatus == OperatorStatus.Active) {
            activeOperatorCount--;
        }

        emit OperatorRemoved(operator, msg.sender, block.timestamp);
    }

    /**
     * @notice Suspend an operator temporarily
     * @param operator Address to suspend
     * @param reason Suspension reason
     * @dev Only admin can suspend (emergency action)
     * 
     * **Requirements:**
     * - Caller must have ADMIN_ROLE
     * - Operator must be active
     * - At least one other active operator remains
     * 
     * **Use Cases:**
     * - Emergency response to suspicious activity
     * - Maintenance on execution engine
     * - Investigation of anomaly
     */
    function suspendOperator(address operator, string calldata reason) 
        external 
        onlyRole(ADMIN_ROLE) 
        nonReentrant 
    {
        require(operator != address(0), "OperatorRegistry: Zero operator");
        require(
            operators[operator].status == OperatorStatus.Active,
            "OperatorRegistry: Not active"
        );
        require(
            activeOperatorCount > 1,
            "OperatorRegistry: Cannot suspend last operator"
        );

        operators[operator].status = OperatorStatus.Suspended;
        operators[operator].lastStatusChange = block.timestamp;
        activeOperatorCount--;

        emit OperatorSuspended(operator, msg.sender, block.timestamp, reason);
    }

    /**
     * @notice Reactivate a suspended operator
     * @param operator Address to reactivate
     * @dev Only governance can reactivate
     * 
     * **Requirements:**
     * - Caller must have GOVERNANCE_ROLE
     * - Operator must be suspended
     */
    function reactivateOperator(address operator) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
        nonReentrant 
    {
        require(operator != address(0), "OperatorRegistry: Zero operator");
        require(
            operators[operator].status == OperatorStatus.Suspended,
            "OperatorRegistry: Not suspended"
        );

        operators[operator].status = OperatorStatus.Active;
        operators[operator].lastStatusChange = block.timestamp;
        activeOperatorCount++;

        emit OperatorReactivated(operator, msg.sender, block.timestamp);
    }

    /**
     * @notice Record a batch submission by operator
     * @param operator Operator address
     * @dev Called by TradeLedger when batch is submitted
     * 
     * **Requirements:**
     * - Operator must be active
     */
    function recordBatchSubmission(address operator) 
        external 
        nonReentrant 
    {
        require(
            operators[operator].status == OperatorStatus.Active,
            "OperatorRegistry: Operator not active"
        );

        operators[operator].batchesSubmitted++;

        emit OperatorBatchSubmitted(operator, operators[operator].batchesSubmitted);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if address is an active operator
     * @param operator Address to check
     * @return active Whether operator is active
     * @dev Called by other contracts to verify operator status
     * 
     * **Used by:**
     * - TradeLedger.submitBatch()
     * - TraderAccountRegistry.registerTrader()
     * - PayoutManager.requestPayout()
     */
    function isOperator(address operator) external view returns (bool active) {
        return operators[operator].status == OperatorStatus.Active;
    }

    /**
     * @notice Get operator information
     * @param operator Operator address
     * @return info OperatorInfo struct
     */
    function getOperatorInfo(address operator) 
        external 
        view 
        returns (OperatorInfo memory info) 
    {
        return operators[operator];
    }

    /**
     * @notice Get all active operators
     * @return activeOperators Array of active operator addresses
     */
    function getActiveOperators() 
        external 
        view 
        returns (address[] memory activeOperators) 
    {
        uint256 count = 0;
        
        // Count active operators
        for (uint256 i = 0; i < operatorList.length; i++) {
            if (operators[operatorList[i]].status == OperatorStatus.Active) {
                count++;
            }
        }
        
        // Collect active operators
        activeOperators = new address[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < operatorList.length; i++) {
            if (operators[operatorList[i]].status == OperatorStatus.Active) {
                activeOperators[index++] = operatorList[i];
            }
        }
        
        return activeOperators;
    }

    /**
     * @notice Get all operators (any status)
     * @return allOperators Array of all operator addresses
     */
    function getAllOperators() external view returns (address[] memory allOperators) {
        return operatorList;
    }

    /**
     * @notice Get operator count by status
     * @param status Status to count
     * @return count Number of operators with status
     */
    function getOperatorCountByStatus(OperatorStatus status) 
        external 
        view 
        returns (uint256 count) 
    {
        for (uint256 i = 0; i < operatorList.length; i++) {
            if (operators[operatorList[i]].status == status) {
                count++;
            }
        }
        return count;
    }

    /**
     * @notice Get operator statistics
     * @return total Total operators ever added
     * @return active Currently active operators
     * @return suspended Currently suspended operators
     * @return inactive Inactive operators
     */
    function getOperatorStatistics() 
        external 
        view 
        returns (
            uint256 total,
            uint256 active,
            uint256 suspended,
            uint256 inactive
        ) 
    {
        total = operatorList.length;
        active = 0;
        suspended = 0;
        inactive = 0;
        
        for (uint256 i = 0; i < operatorList.length; i++) {
            OperatorStatus status = operators[operatorList[i]].status;
            if (status == OperatorStatus.Active) {
                active++;
            } else if (status == OperatorStatus.Suspended) {
                suspended++;
            } else {
                inactive++;
            }
        }
        
        return (total, active, suspended, inactive);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Pause contract (emergency only)
     * @dev Only admin can pause
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract
     * @dev Only admin can unpause
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
     * @dev Only governance can upgrade (with timelock via GovernanceManager)
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(newImplementation != address(0), "OperatorRegistry: Zero implementation");
    }

    /**
     * @dev Storage gap for future upgrades
     */
    uint256[50] private __gap;
}
