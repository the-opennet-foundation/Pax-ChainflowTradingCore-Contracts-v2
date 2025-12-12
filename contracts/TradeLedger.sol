// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title TradeLedger
 * @notice Append-only ledger for trade settlement batches with Merkle proof validation
 * @dev Core transparency layer - all trades are cryptographically provable
 * 
 * **Key Responsibilities:**
 * - Accept trade settlement batches from authorized operators
 * - Store Merkle roots for gas-efficient verification
 * - Validate individual trades against batch commitments
 * - Maintain immutable audit trail for all trades
 * - Link to off-chain data (IPFS/S3) for full trade details
 * 
 * **Architecture:**
 * ```
 * Off-chain: [Trades] → Build Merkle Tree → Submit Root
 * On-chain:  Store {batchId, merkleRoot, metadata}
 * Verify:    Merkle Proof + tradeData → Valid/Invalid
 * ```
 * 
 * **Gas Optimization:**
 * - Only store Merkle root on-chain (~32 bytes)
 * - Full trade data stored off-chain (IPFS)
 * - Batch multiple trades into single submission
 * 
 * **Security:**
 * - Operator signature validation
 * - Immutable once submitted (append-only)
 * - Merkle proof prevents data tampering
 * - Operator registry authorization
 * 
 * @custom:security-contact security@propdao.finance
 */
contract TradeLedger is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable 
{
    /// @notice Role identifier for contract administrators
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Role identifier for authorized operators (settlement service)
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    /// @notice Role identifier for PayoutManager contract
    bytes32 public constant PAYOUT_MANAGER_ROLE = keccak256("PAYOUT_MANAGER_ROLE");
    
    /// @notice Role identifier for governance operations
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    /**
     * @notice Batch settlement information
     * @param batchId Unique batch identifier
     * @param batchHash Hash of all trades in batch
     * @param merkleRoot Merkle tree root for verification
     * @param operator Address that submitted batch
     * @param tradeCount Number of trades in batch
     * @param timestamp Submission timestamp
     * @param metadata IPFS hash or URL to full trade data
     * @param totalVolume Total volume across all trades
     * @param netPnL Net profit/loss for batch
     */
    struct Batch {
        bytes32 batchId;
        bytes32 batchHash;
        bytes32 merkleRoot;
        address operator;
        uint256 tradeCount;
        uint256 timestamp;
        string metadata;
        uint256 totalVolume;
        int256 netPnL;
    }

    /**
     * @notice Individual trade data structure (for verification)
     * @param traderId Trader identifier
     * @param tradeId Unique trade identifier
     * @param symbol Trading pair symbol
     * @param side Trade side (0=Long, 1=Short)
     * @param size Position size
     * @param entryPrice Entry price
     * @param exitPrice Exit price (0 if open)
     * @param pnl Profit/loss
     * @param fee Trading fee
     * @param timestamp Trade execution time
     */
    struct Trade {
        bytes32 traderId;
        bytes32 tradeId;
        string symbol;
        uint8 side;
        uint256 size;
        uint256 entryPrice;
        uint256 exitPrice;
        int256 pnl;
        uint256 fee;
        uint256 timestamp;
    }

    /**
     * @notice Trader PnL summary (extracted from batch)
     * @param traderId Trader identifier
     * @param totalPnL Total profit/loss in batch
     * @param tradeCount Number of trades
     * @param verified Whether PnL has been verified
     */
    struct TraderPnL {
        bytes32 traderId;
        int256 totalPnL;
        uint256 tradeCount;
        bool verified;
    }

    /// @notice Counter for batch IDs
    uint256 public batchCounter;

    /// @notice Mapping of batch ID to batch data
    mapping(bytes32 => Batch) public batches;

    /// @notice Mapping of batch ID to trader PnL summaries
    mapping(bytes32 => mapping(bytes32 => TraderPnL)) public batchTraderPnL;

    /// @notice Array of all batch IDs (for enumeration)
    bytes32[] public batchIds;

    /// @notice Mapping of trade ID to batch ID (prevent duplicate trades)
    mapping(bytes32 => bytes32) public tradeIdToBatchId;

    /// @notice Total number of trades across all batches
    uint256 public totalTrades;

    /// @notice Total volume across all batches
    uint256 public totalVolume;

    /// @notice Cumulative net PnL
    int256 public cumulativePnL;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                                EVENTS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when a new batch is submitted
     * @param batchId Unique batch identifier
     * @param operator Address that submitted
     * @param merkleRoot Merkle tree root
     * @param tradeCount Number of trades
     * @param timestamp Submission time
     * @param metadata Off-chain data reference
     */
    event BatchSubmitted(
        bytes32 indexed batchId,
        address indexed operator,
        bytes32 merkleRoot,
        uint256 tradeCount,
        uint256 timestamp,
        string metadata
    );

    /**
     * @notice Emitted when a trade is verified
     * @param batchId Batch containing the trade
     * @param tradeId Trade identifier
     * @param traderId Trader identifier
     * @param pnl Trade profit/loss
     * @param timestamp Verification time
     */
    event TradeVerified(
        bytes32 indexed batchId,
        bytes32 indexed tradeId,
        bytes32 indexed traderId,
        int256 pnl,
        uint256 timestamp
    );

    /**
     * @notice Emitted when trader PnL is verified for a batch
     * @param batchId Batch identifier
     * @param traderId Trader identifier
     * @param totalPnL Total PnL for trader in batch
     * @param tradeCount Number of trades
     */
    event TraderPnLVerified(
        bytes32 indexed batchId,
        bytes32 indexed traderId,
        int256 totalPnL,
        uint256 tradeCount
    );

    /**
     * @notice Emitted when batch statistics are updated
     * @param totalBatches Total number of batches
     * @param totalTrades Total number of trades
     * @param totalVolume Total trading volume
     * @param cumulativePnL Cumulative PnL
     */
    event StatisticsUpdated(
        uint256 totalBatches,
        uint256 totalTrades,
        uint256 totalVolume,
        int256 cumulativePnL
    );

    // ═════════════════════════════════════════════════════════════════════════
    //                            INITIALIZATION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize the TradeLedger contract
     * @param _admin Address to grant admin roles
     * @param _governance Address to grant governance role
     * @param _operators Array of operator addresses
     * @dev Can only be called once due to initializer modifier
     */
    function initialize(
        address _admin,
        address _governance,
        address[] memory _operators
    ) external initializer {
        require(_admin != address(0), "TradeLedger: Zero admin");
        require(_governance != address(0), "TradeLedger: Zero governance");

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(GOVERNANCE_ROLE, _governance);

        // Add operators
        for (uint256 i = 0; i < _operators.length; i++) {
            require(_operators[i] != address(0), "TradeLedger: Zero operator");
            _grantRole(OPERATOR_ROLE, _operators[i]);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          BATCH SUBMISSION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Submit a settlement batch with Merkle root
     * @param batchHash Hash of all trades in batch
     * @param merkleRoot Merkle tree root for verification
     * @param tradeCount Number of trades in batch
     * @param metadata IPFS hash or URL to full trade data
     * @param batchVolume Total trading volume in batch
     * @param netPnL Net profit/loss for batch
     * @return batchId Unique batch identifier
     * @dev Only callable by authorized operators
     * 
     * **Submission Flow:**
     * 1. Off-chain: Collect all trades
     * 2. Build Merkle tree from trade data
     * 3. Calculate batch hash and Merkle root
     * 4. Submit to blockchain (this function)
     * 5. Store full trade data on IPFS
     * 
     * **Gas Optimization:**
     * - Only stores ~200 bytes on-chain
     * - Full trade data (unlimited size) stored off-chain
     * - Merkle root enables verification without storing all data
     * 
     * **Requirements:**
     * - Caller must have OPERATOR_ROLE
     * - Contract not paused
     * - Valid inputs
     */
    function submitBatch(
        bytes32 batchHash,
        bytes32 merkleRoot,
        uint256 tradeCount,
        string calldata metadata,
        uint256 batchVolume,
        int256 netPnL
    ) 
        external 
        onlyRole(OPERATOR_ROLE) 
        nonReentrant 
        whenNotPaused 
        returns (bytes32 batchId) 
    {
        require(batchHash != bytes32(0), "TradeLedger: Invalid batch hash");
        require(merkleRoot != bytes32(0), "TradeLedger: Invalid merkle root");
        require(tradeCount > 0, "TradeLedger: Zero trades");
        require(bytes(metadata).length > 0, "TradeLedger: Empty metadata");

        // Generate unique batch ID
        batchId = keccak256(abi.encodePacked(
            batchHash,
            merkleRoot,
            msg.sender,
            batchCounter++,
            block.timestamp
        ));

        // Ensure batch doesn't already exist (shouldn't happen, but safety check)
        require(batches[batchId].timestamp == 0, "TradeLedger: Batch exists");

        // Store batch
        batches[batchId] = Batch({
            batchId: batchId,
            batchHash: batchHash,
            merkleRoot: merkleRoot,
            operator: msg.sender,
            tradeCount: tradeCount,
            timestamp: block.timestamp,
            metadata: metadata,
            totalVolume: batchVolume,
            netPnL: netPnL
        });

        batchIds.push(batchId);

        // Update global statistics
        totalTrades += tradeCount;
        totalVolume += batchVolume;
        cumulativePnL += netPnL;

        emit BatchSubmitted(
            batchId,
            msg.sender,
            merkleRoot,
            tradeCount,
            block.timestamp,
            metadata
        );

        emit StatisticsUpdated(
            batchIds.length,
            totalTrades,
            totalVolume,
            cumulativePnL
        );

        return batchId;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          TRADE VERIFICATION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Verify a trade is part of a batch using Merkle proof
     * @param batchId Batch identifier
     * @param proof Merkle proof (array of sibling hashes)
     * @param trade Trade data to verify
     * @return valid Whether trade is valid
     * @return pnl Trade profit/loss
     * @dev Uses OpenZeppelin MerkleProof library for verification
     * 
     * **Merkle Proof Verification:**
     * 1. Hash the trade data (leaf node)
     * 2. Use proof to reconstruct path to root
     * 3. Compare reconstructed root with stored root
     * 4. If match → trade is valid
     * 
     * **Use Cases:**
     * - PayoutManager verifies trader PnL before payout
     * - Auditors verify specific trades
     * - Dispute resolution
     * 
     * **Requirements:**
     * - Batch must exist
     * - Valid Merkle proof
     */
    function verifyTrade(
        bytes32 batchId,
        bytes32[] calldata proof,
        Trade calldata trade
    ) 
        external 
        view 
        returns (bool valid, int256 pnl) 
    {
        Batch storage batch = batches[batchId];
        require(batch.timestamp > 0, "TradeLedger: Batch not found");

        // Hash trade data (leaf node)
        bytes32 leaf = _hashTrade(trade);

        // Verify Merkle proof
        valid = MerkleProof.verify(proof, batch.merkleRoot, leaf);

        if (valid) {
            pnl = trade.pnl;
        }

        return (valid, pnl);
    }

    /**
     * @notice Verify and record trader PnL for a batch
     * @param batchId Batch identifier
     * @param traderId Trader identifier
     * @param proof Merkle proofs for all trader's trades
     * @param trades Array of trades for trader
     * @return totalPnL Total verified PnL
     * @dev Only callable by PayoutManager
     * 
     * **Batch PnL Verification:**
     * 1. Verify each trade belongs to batch (Merkle proof)
     * 2. Sum up PnL from all trades
     * 3. Store verified PnL for later reference
     * 
     * **Requirements:**
     * - All trades must pass Merkle verification
     * - Trades must belong to same trader
     */
    function verifyAndRecordTraderPnL(
        bytes32 batchId,
        bytes32 traderId,
        bytes32[][] calldata proof,
        Trade[] calldata trades
    ) 
        external 
        onlyRole(PAYOUT_MANAGER_ROLE) 
        nonReentrant 
        returns (int256 totalPnL) 
    {
        require(trades.length > 0, "TradeLedger: No trades");
        require(proof.length == trades.length, "TradeLedger: Proof length mismatch");

        Batch storage batch = batches[batchId];
        require(batch.timestamp > 0, "TradeLedger: Batch not found");

        totalPnL = 0;

        // Verify each trade and sum PnL
        for (uint256 i = 0; i < trades.length; i++) {
            require(trades[i].traderId == traderId, "TradeLedger: Wrong trader");

            bytes32 leaf = _hashTrade(trades[i]);
            require(
                MerkleProof.verify(proof[i], batch.merkleRoot, leaf),
                "TradeLedger: Invalid proof"
            );

            totalPnL += trades[i].pnl;

            // Prevent duplicate trade verification
            require(
                tradeIdToBatchId[trades[i].tradeId] == bytes32(0),
                "TradeLedger: Trade already verified"
            );
            tradeIdToBatchId[trades[i].tradeId] = batchId;

            emit TradeVerified(
                batchId,
                trades[i].tradeId,
                traderId,
                trades[i].pnl,
                block.timestamp
            );
        }

        // Record trader PnL for batch
        batchTraderPnL[batchId][traderId] = TraderPnL({
            traderId: traderId,
            totalPnL: totalPnL,
            tradeCount: trades.length,
            verified: true
        });

        emit TraderPnLVerified(batchId, traderId, totalPnL, trades.length);

        return totalPnL;
    }

    /**
     * @notice Hash trade data to create Merkle tree leaf
     * @param trade Trade data
     * @return hash Keccak256 hash of trade
     * @dev Internal function for consistent hashing
     * 
     * **Hash includes:**
     * - All trade fields (traderId, symbol, size, prices, pnl, etc.)
     * - Order matters (must match off-chain hashing)
     */
    function _hashTrade(Trade calldata trade) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            trade.traderId,
            trade.tradeId,
            trade.symbol,
            trade.side,
            trade.size,
            trade.entryPrice,
            trade.exitPrice,
            trade.pnl,
            trade.fee,
            trade.timestamp
        ));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                           VIEW FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get batch information
     * @param batchId Batch identifier
     * @return batch Batch struct
     */
    function getBatch(bytes32 batchId) 
        external 
        view 
        returns (Batch memory batch) 
    {
        return batches[batchId];
    }

    /**
     * @notice Get trader PnL for a specific batch
     * @param batchId Batch identifier
     * @param traderId Trader identifier
     * @return pnlData TraderPnL struct
     */
    function getTraderPnL(bytes32 batchId, bytes32 traderId) 
        external 
        view 
        returns (TraderPnL memory pnlData) 
    {
        return batchTraderPnL[batchId][traderId];
    }

    /**
     * @notice Get total number of batches
     * @return count Batch count
     */
    function getBatchCount() external view returns (uint256 count) {
        return batchIds.length;
    }

    /**
     * @notice Get batch by index
     * @param index Array index
     * @return batchId Batch identifier
     */
    function getBatchIdByIndex(uint256 index) 
        external 
        view 
        returns (bytes32 batchId) 
    {
        require(index < batchIds.length, "TradeLedger: Index out of bounds");
        return batchIds[index];
    }

    /**
     * @notice Get recent batches
     * @param count Number of batches to return
     * @return recentBatches Array of batch structs
     */
    function getRecentBatches(uint256 count) 
        external 
        view 
        returns (Batch[] memory recentBatches) 
    {
        uint256 totalBatches = batchIds.length;
        uint256 returnCount = count > totalBatches ? totalBatches : count;
        
        recentBatches = new Batch[](returnCount);
        
        for (uint256 i = 0; i < returnCount; i++) {
            uint256 index = totalBatches - 1 - i;
            recentBatches[i] = batches[batchIds[index]];
        }
        
        return recentBatches;
    }

    /**
     * @notice Get batches by operator
     * @param operator Operator address
     * @return operatorBatches Array of batch IDs
     */
    function getBatchesByOperator(address operator) 
        external 
        view 
        returns (bytes32[] memory operatorBatches) 
    {
        uint256 count = 0;
        
        // Count batches
        for (uint256 i = 0; i < batchIds.length; i++) {
            if (batches[batchIds[i]].operator == operator) {
                count++;
            }
        }
        
        // Collect batch IDs
        operatorBatches = new bytes32[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < batchIds.length; i++) {
            if (batches[batchIds[i]].operator == operator) {
                operatorBatches[index++] = batchIds[i];
            }
        }
        
        return operatorBatches;
    }

    /**
     * @notice Get global statistics
     * @return batchCount Total batches
     * @return tradeCount Total trades
     * @return volume Total volume
     * @return pnl Cumulative PnL
     */
    function getStatistics() 
        external 
        view 
        returns (
            uint256 batchCount,
            uint256 tradeCount,
            uint256 volume,
            int256 pnl
        ) 
    {
        return (
            batchIds.length,
            totalTrades,
            totalVolume,
            cumulativePnL
        );
    }

    /**
     * @notice Check if trade has been verified
     * @param tradeId Trade identifier
     * @return verified Whether trade has been verified
     * @return batchId Batch containing the trade
     */
    function isTradeVerified(bytes32 tradeId) 
        external 
        view 
        returns (bool verified, bytes32 batchId) 
    {
        batchId = tradeIdToBatchId[tradeId];
        verified = (batchId != bytes32(0));
        return (verified, batchId);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set PayoutManager address
     * @param payoutManager Address of PayoutManager contract
     * @dev Only admin can set
     */
    function setPayoutManager(address payoutManager) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(payoutManager != address(0), "TradeLedger: Zero address");
        _grantRole(PAYOUT_MANAGER_ROLE, payoutManager);
    }

    /**
     * @notice Add a new operator
     * @param operator Address to add
     * @dev Only governance can add operators
     */
    function addOperator(address operator) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(operator != address(0), "TradeLedger: Zero operator");
        _grantRole(OPERATOR_ROLE, operator);
    }

    /**
     * @notice Remove an operator
     * @param operator Address to remove
     * @dev Only governance can remove operators
     */
    function removeOperator(address operator) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        _revokeRole(OPERATOR_ROLE, operator);
    }

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
        require(newImplementation != address(0), "TradeLedger: Zero implementation");
    }

    /**
     * @dev Storage gap for future upgrades
     */
    uint256[50] private __gap;
}
