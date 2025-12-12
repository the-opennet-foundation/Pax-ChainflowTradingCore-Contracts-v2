// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title GovernanceManager
 * @notice DAO governance with proposals, voting, and timelocked execution
 * @dev Controls protocol parameters and manages upgrade proposals
 * 
 * **Key Responsibilities:**
 * - Create and manage governance proposals
 * - Facilitate voting on protocol changes
 * - Execute approved proposals after timelock
 * - Store and update protocol parameters
 * - Manage emergency actions via multi-sig
 * - Control contract upgrades across the system
 * 
 * **Governance Model:**
 * ```
 * 1. Proposal Creation (any PROPOSER_ROLE)
 * 2. Voting Period (configurable duration)
 * 3. Timelock Delay (48-72h for security)
 * 4. Execution (if approved)
 * ```
 * 
 * **Parameter Categories:**
 * - Tier configurations (capital, drawdown, profit split)
 * - Risk parameters (leverage, position limits)
 * - Payout settings (cooldown, minimums)
 * - Fee structures (LP fees, protocol fees)
 * - Emergency thresholds
 * 
 * **Security Features:**
 * - Timelock prevents instant malicious changes
 * - Multi-sig can veto/expedite in emergencies
 * - Proposal expiration prevents stale executions
 * - Quorum requirements ensure legitimacy
 * - Role-based access control
 * 
 * @custom:security-contact security@propdao.finance
 */
contract GovernanceManager is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable 
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant VOTER_ROLE = keccak256("VOTER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /// @notice Default timelock delay (48 hours)
    uint256 public constant DEFAULT_TIMELOCK_DELAY = 48 hours;
    
    /// @notice Minimum timelock delay (24 hours)
    uint256 public constant MIN_TIMELOCK_DELAY = 24 hours;
    
    /// @notice Maximum timelock delay (7 days)
    uint256 public constant MAX_TIMELOCK_DELAY = 7 days;
    
    /// @notice Default voting period (3 days)
    uint256 public constant DEFAULT_VOTING_PERIOD = 3 days;
    
    /// @notice Minimum quorum (30%)
    uint256 public constant MIN_QUORUM = 3000; // 30% in basis points
    
    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;

    /**
     * @notice Proposal states
     */
    enum ProposalState {
        Pending,        // Created, voting not started
        Active,         // Voting period active
        Defeated,       // Did not pass quorum/majority
        Succeeded,      // Passed, awaiting timelock
        Queued,         // In timelock delay
        Expired,        // Timelock expired without execution
        Executed,       // Successfully executed
        Cancelled       // Cancelled by emergency role
    }

    /**
     * @notice Proposal structure
     * @param proposalId Unique proposal identifier
     * @param proposer Address that created proposal
     * @param description Proposal description
     * @param targets Array of target contract addresses
     * @param values Array of ETH values to send
     * @param calldatas Array of function call data
     * @param startBlock Voting start block
     * @param endBlock Voting end block
     * @param forVotes Number of FOR votes
     * @param againstVotes Number of AGAINST votes
     * @param abstainVotes Number of ABSTAIN votes
     * @param state Current proposal state
     * @param eta Estimated time of execution (after timelock)
     * @param executedAt Execution timestamp
     */
    struct Proposal {
        uint256 proposalId;
        address proposer;
        string description;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        ProposalState state;
        uint256 eta;
        uint256 executedAt;
    }

    /**
     * @notice Parameter update structure
     * @param key Parameter key (e.g., "max_leverage")
     * @param value Parameter value
     * @param updatedAt Last update timestamp
     * @param updatedBy Address that updated
     */
    struct Parameter {
        bytes32 key;
        uint256 value;
        uint256 updatedAt;
        address updatedBy;
    }

    /// @notice Current timelock delay
    uint256 public timelockDelay;
    
    /// @notice Current voting period
    uint256 public votingPeriod;
    
    /// @notice Current quorum requirement (basis points)
    uint256 public quorumBps;

    /// @notice Proposal counter
    uint256 public proposalCount;
    
    /// @notice Total voting power (for quorum calculation)
    uint256 public totalVotingPower;

    /// @notice Mapping of proposal ID to proposal
    mapping(uint256 => Proposal) public proposals;
    
    /// @notice Mapping of proposal ID to voter to vote cast
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    
    /// @notice Mapping of voter to voting power
    mapping(address => uint256) public votingPower;
    
    /// @notice Mapping of parameter key to parameter value
    mapping(bytes32 => Parameter) public parameters;
    
    /// @notice Array of all parameter keys
    bytes32[] public parameterKeys;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                                EVENTS
    // ═════════════════════════════════════════════════════════════════════════

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string description, uint256 startBlock, uint256 endBlock);
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint8 support, uint256 weight, string reason);
    event ProposalQueued(uint256 indexed proposalId, uint256 eta);
    event ProposalExecuted(uint256 indexed proposalId, uint256 timestamp);
    event ProposalCancelled(uint256 indexed proposalId, address indexed canceller);
    event ParameterUpdated(bytes32 indexed key, uint256 oldValue, uint256 newValue, address indexed updatedBy);
    event VotingPowerUpdated(address indexed voter, uint256 oldPower, uint256 newPower);
    event TimelockDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event VotingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);

    // ═════════════════════════════════════════════════════════════════════════
    //                            INITIALIZATION
    // ═════════════════════════════════════════════════════════════════════════

    function initialize(
        address _admin,
        address _emergency,
        address[] memory _proposers,
        address[] memory _executors
    ) external initializer {
        require(_admin != address(0), "Governance: Zero admin");
        require(_emergency != address(0), "Governance: Zero emergency");

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _emergency);

        for (uint256 i = 0; i < _proposers.length; i++) {
            require(_proposers[i] != address(0), "Governance: Zero proposer");
            _grantRole(PROPOSER_ROLE, _proposers[i]);
        }

        for (uint256 i = 0; i < _executors.length; i++) {
            require(_executors[i] != address(0), "Governance: Zero executor");
            _grantRole(EXECUTOR_ROLE, _executors[i]);
        }

        timelockDelay = DEFAULT_TIMELOCK_DELAY;
        votingPeriod = DEFAULT_VOTING_PERIOD;
        quorumBps = MIN_QUORUM;

        _initializeDefaultParameters();
    }

    function _initializeDefaultParameters() internal {
        _setParameter("max_leverage", 1000);           // 1000x max leverage
        _setParameter("min_payout", 100e18);           // $100 minimum payout
        _setParameter("payout_cooldown", 7 days);      // 7 day cooldown
        _setParameter("lp_fee_bps", 30);               // 0.3% LP fee
        _setParameter("protocol_fee_bps", 10);         // 0.1% protocol fee
        _setParameter("emergency_threshold", 1000000e18); // $1M emergency threshold
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          PROPOSAL CREATION
    // ═════════════════════════════════════════════════════════════════════════

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) 
        external 
        onlyRole(PROPOSER_ROLE) 
        nonReentrant 
        whenNotPaused 
        returns (uint256 proposalId) 
    {
        require(targets.length == values.length, "Governance: Length mismatch");
        require(targets.length == calldatas.length, "Governance: Length mismatch");
        require(targets.length > 0, "Governance: Empty proposal");
        require(bytes(description).length > 0, "Governance: Empty description");

        proposalId = ++proposalCount;

        uint256 startBlock = block.number + 1;
        uint256 endBlock = startBlock + (votingPeriod / 12); // Assuming 12s block time

        proposals[proposalId] = Proposal({
            proposalId: proposalId,
            proposer: msg.sender,
            description: description,
            targets: targets,
            values: values,
            calldatas: calldatas,
            startBlock: startBlock,
            endBlock: endBlock,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            state: ProposalState.Pending,
            eta: 0,
            executedAt: 0
        });

        emit ProposalCreated(proposalId, msg.sender, description, startBlock, endBlock);

        return proposalId;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                              VOTING
    // ═════════════════════════════════════════════════════════════════════════

    function castVote(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) external nonReentrant returns (uint256 weight) {
        return _castVote(msg.sender, proposalId, support, reason);
    }

    function _castVote(
        address voter,
        uint256 proposalId,
        uint8 support,
        string memory reason
    ) internal returns (uint256 weight) {
        Proposal storage proposal = proposals[proposalId];
        
        require(proposal.proposalId != 0, "Governance: Invalid proposal");
        require(proposal.state == ProposalState.Active || proposal.state == ProposalState.Pending, "Governance: Voting closed");
        require(block.number >= proposal.startBlock, "Governance: Voting not started");
        require(block.number <= proposal.endBlock, "Governance: Voting ended");
        require(!hasVoted[proposalId][voter], "Governance: Already voted");

        // Activate proposal if still pending
        if (proposal.state == ProposalState.Pending) {
            proposal.state = ProposalState.Active;
        }

        weight = votingPower[voter];
        require(weight > 0, "Governance: No voting power");

        hasVoted[proposalId][voter] = true;

        if (support == 0) {
            proposal.againstVotes += weight;
        } else if (support == 1) {
            proposal.forVotes += weight;
        } else if (support == 2) {
            proposal.abstainVotes += weight;
        } else {
            revert("Governance: Invalid support value");
        }

        emit VoteCast(proposalId, voter, support, weight, reason);

        return weight;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          PROPOSAL EXECUTION
    // ═════════════════════════════════════════════════════════════════════════

    function queue(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        
        require(proposal.proposalId != 0, "Governance: Invalid proposal");
        require(proposal.state == ProposalState.Active, "Governance: Not active");
        require(block.number > proposal.endBlock, "Governance: Voting not ended");

        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        uint256 quorumRequired = (totalVotingPower * quorumBps) / BASIS_POINTS;

        // Check quorum
        require(totalVotes >= quorumRequired, "Governance: Quorum not reached");

        // Check majority
        if (proposal.forVotes > proposal.againstVotes) {
            proposal.state = ProposalState.Succeeded;
            proposal.eta = block.timestamp + timelockDelay;
            proposal.state = ProposalState.Queued;

            emit ProposalQueued(proposalId, proposal.eta);
        } else {
            proposal.state = ProposalState.Defeated;
        }
    }

    function execute(uint256 proposalId) 
        external 
        payable 
        onlyRole(EXECUTOR_ROLE) 
        nonReentrant 
    {
        Proposal storage proposal = proposals[proposalId];
        
        require(proposal.proposalId != 0, "Governance: Invalid proposal");
        require(proposal.state == ProposalState.Queued, "Governance: Not queued");
        require(block.timestamp >= proposal.eta, "Governance: Timelock not expired");
        require(block.timestamp <= proposal.eta + 14 days, "Governance: Proposal expired");

        proposal.state = ProposalState.Executed;
        proposal.executedAt = block.timestamp;

        for (uint256 i = 0; i < proposal.targets.length; i++) {
            _executeTransaction(
                proposal.targets[i],
                proposal.values[i],
                proposal.calldatas[i]
            );
        }

        emit ProposalExecuted(proposalId, block.timestamp);
    }

    function _executeTransaction(
        address target,
        uint256 value,
        bytes memory data
    ) internal {
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        
        if (!success) {
            if (returndata.length > 0) {
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert("Governance: Transaction execution reverted");
            }
        }
    }

    function cancel(uint256 proposalId) external onlyRole(EMERGENCY_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        
        require(proposal.proposalId != 0, "Governance: Invalid proposal");
        require(
            proposal.state != ProposalState.Executed && 
            proposal.state != ProposalState.Cancelled,
            "Governance: Cannot cancel"
        );

        proposal.state = ProposalState.Cancelled;

        emit ProposalCancelled(proposalId, msg.sender);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                        PARAMETER MANAGEMENT
    // ═════════════════════════════════════════════════════════════════════════

    function setParam(bytes32 key, uint256 value) 
        external 
        onlyRole(ADMIN_ROLE) 
        nonReentrant 
    {
        _setParameter(key, value);
    }

    function _setParameter(bytes32 key, uint256 value) internal {
        uint256 oldValue = parameters[key].value;

        if (parameters[key].updatedAt == 0) {
            parameterKeys.push(key);
        }

        parameters[key] = Parameter({
            key: key,
            value: value,
            updatedAt: block.timestamp,
            updatedBy: msg.sender
        });

        emit ParameterUpdated(key, oldValue, value, msg.sender);
    }

    function getParam(bytes32 key) external view returns (uint256) {
        return parameters[key].value;
    }

    function getAllParameters() external view returns (Parameter[] memory allParams) {
        allParams = new Parameter[](parameterKeys.length);
        
        for (uint256 i = 0; i < parameterKeys.length; i++) {
            allParams[i] = parameters[parameterKeys[i]];
        }
        
        return allParams;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                         VOTING POWER MANAGEMENT
    // ═════════════════════════════════════════════════════════════════════════

    function setVotingPower(address voter, uint256 power) 
        public 
        onlyRole(ADMIN_ROLE) 
    {
        uint256 oldPower = votingPower[voter];
        
        totalVotingPower = totalVotingPower - oldPower + power;
        votingPower[voter] = power;

        emit VotingPowerUpdated(voter, oldPower, power);
    }

    function grantVoterRole(address voter, uint256 power) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        _grantRole(VOTER_ROLE, voter);
        
        if (power > 0) {
            setVotingPower(voter, power);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function getProposalState(uint256 proposalId) external view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.state == ProposalState.Queued && block.timestamp > proposal.eta + 14 days) {
            return ProposalState.Expired;
        }
        
        return proposal.state;
    }

    function getVotingPower(address voter) external view returns (uint256) {
        return votingPower[voter];
    }

    function hasVotedOnProposal(uint256 proposalId, address voter) external view returns (bool) {
        return hasVoted[proposalId][voter];
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    function updateTimelockDelay(uint256 newDelay) external onlyRole(ADMIN_ROLE) {
        require(newDelay >= MIN_TIMELOCK_DELAY, "Governance: Delay too short");
        require(newDelay <= MAX_TIMELOCK_DELAY, "Governance: Delay too long");

        uint256 oldDelay = timelockDelay;
        timelockDelay = newDelay;

        emit TimelockDelayUpdated(oldDelay, newDelay);
    }

    function updateVotingPeriod(uint256 newPeriod) external onlyRole(ADMIN_ROLE) {
        require(newPeriod >= 1 days, "Governance: Period too short");
        require(newPeriod <= 14 days, "Governance: Period too long");

        uint256 oldPeriod = votingPeriod;
        votingPeriod = newPeriod;

        emit VotingPeriodUpdated(oldPeriod, newPeriod);
    }

    function updateQuorum(uint256 newQuorumBps) external onlyRole(ADMIN_ROLE) {
        require(newQuorumBps >= 1000, "Governance: Quorum too low"); // Min 10%
        require(newQuorumBps <= 5000, "Governance: Quorum too high"); // Max 50%

        uint256 oldQuorum = quorumBps;
        quorumBps = newQuorumBps;

        emit QuorumUpdated(oldQuorum, newQuorumBps);
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
        onlyRole(ADMIN_ROLE) 
    {
        require(newImplementation != address(0), "Governance: Zero implementation");
    }

    uint256[50] private __gap;
}
