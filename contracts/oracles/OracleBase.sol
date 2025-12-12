// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title OracleBase
 * @notice Abstract base contract for all price oracles
 * @dev Provides common functionality for price feeds across all asset classes
 * 
 * **Shared Features:**
 * - Price submission by authorized feeders
 * - Staleness detection and validation
 * - Historical price tracking
 * - Multi-source price aggregation
 * - Emergency price override
 * - Heartbeat monitoring
 * - Confidence intervals
 * 
 * **Security:**
 * - Role-based price submission
 * - Price deviation checks
 * - Staleness thresholds
 * - Circuit breakers
 * - Emergency pause
 */
abstract contract OracleBase is 
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FEEDER_ROLE = keccak256("FEEDER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /// @notice Price decimals (e.g., 8 for BTC price in USD with 8 decimals)
    uint8 public constant PRICE_DECIMALS = 8;
    
    /// @notice Confidence decimals (basis points)
    uint8 public constant CONFIDENCE_DECIMALS = 4;

    /**
     * @notice Price data structure
     * @param price Current price
     * @param confidence Confidence interval (basis points)
     * @param timestamp Last update timestamp
     * @param source Data source identifier
     */
    struct PriceData {
        int64 price;
        uint32 confidence;
        uint64 timestamp;
        address source;
    }

    /**
     * @notice Historical price entry
     */
    struct HistoricalPrice {
        int64 price;
        uint64 timestamp;
        uint32 confidence;
    }

    /// @notice Mapping of symbol to current price data
    mapping(bytes32 => PriceData) public prices;
    
    /// @notice Mapping of symbol to price history
    mapping(bytes32 => HistoricalPrice[]) public priceHistory;
    
    /// @notice Mapping of symbol to last heartbeat
    mapping(bytes32 => uint256) public lastHeartbeat;
    
    /// @notice Supported symbols
    bytes32[] public symbols;
    
    /// @notice Symbol support status
    mapping(bytes32 => bool) public isSupported;

    /// @notice Staleness threshold (seconds)
    uint256 public stalenessThreshold;
    
    /// @notice Maximum price deviation allowed (basis points)
    uint256 public maxPriceDeviationBps;
    
    /// @notice Heartbeat interval (seconds)
    uint256 public heartbeatInterval;

    /// @notice Oracle name
    string public oracleName;
    
    /// @notice Oracle version
    string public oracleVersion;

    // ═════════════════════════════════════════════════════════════════════════
    //                                EVENTS
    // ═════════════════════════════════════════════════════════════════════════

    event PriceUpdated(bytes32 indexed symbol, int64 price, uint32 confidence, uint64 timestamp, address indexed source);
    event SymbolAdded(bytes32 indexed symbol, string name);
    event SymbolRemoved(bytes32 indexed symbol);
    event StalenessThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event MaxDeviationUpdated(uint256 oldDeviation, uint256 newDeviation);
    event HeartbeatReceived(bytes32 indexed symbol, uint256 timestamp);
    event EmergencyPriceSet(bytes32 indexed symbol, int64 price, address indexed setter);

    // ═════════════════════════════════════════════════════════════════════════
    //                            INITIALIZATION
    // ═════════════════════════════════════════════════════════════════════════

    function __OracleBase_init(
        string memory _oracleName,
        string memory _version,
        uint256 _stalenessThreshold,
        uint256 _heartbeatInterval,
        address _admin
    ) internal onlyInitializing {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        oracleName = _oracleName;
        oracleVersion = _version;
        stalenessThreshold = _stalenessThreshold;
        heartbeatInterval = _heartbeatInterval;
        maxPriceDeviationBps = 1000; // 10% default

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          PRICE SUBMISSION
    // ═════════════════════════════════════════════════════════════════════════

    function updatePrice(
        bytes32 symbol,
        int64 price,
        uint32 confidence
    ) external onlyRole(FEEDER_ROLE) whenNotPaused {
        _validatePrice(symbol, price, confidence);
        _updatePrice(symbol, price, confidence, msg.sender);
    }

    function updatePriceBatch(
        bytes32[] calldata _symbols,
        int64[] calldata _prices,
        uint32[] calldata _confidences
    ) external onlyRole(FEEDER_ROLE) whenNotPaused {
        require(_symbols.length == _prices.length, "Length mismatch");
        require(_symbols.length == _confidences.length, "Length mismatch");

        for (uint256 i = 0; i < _symbols.length; i++) {
            _validatePrice(_symbols[i], _prices[i], _confidences[i]);
            _updatePrice(_symbols[i], _prices[i], _confidences[i], msg.sender);
        }
    }

    function _updatePrice(
        bytes32 symbol,
        int64 price,
        uint32 confidence,
        address source
    ) internal {
        require(isSupported[symbol], "Symbol not supported");

        PriceData storage priceData = prices[symbol];
        
        // Check price deviation if previous price exists
        if (priceData.timestamp > 0) {
            _checkPriceDeviation(symbol, price, priceData.price);
        }

        // Update current price
        priceData.price = price;
        priceData.confidence = confidence;
        priceData.timestamp = uint64(block.timestamp);
        priceData.source = source;

        // Add to history (keep last 100)
        HistoricalPrice[] storage history = priceHistory[symbol];
        if (history.length >= 100) {
            // Remove oldest
            for (uint256 i = 0; i < history.length - 1; i++) {
                history[i] = history[i + 1];
            }
            history.pop();
        }
        history.push(HistoricalPrice({
            price: price,
            timestamp: uint64(block.timestamp),
            confidence: confidence
        }));

        // Update heartbeat
        lastHeartbeat[symbol] = block.timestamp;

        emit PriceUpdated(symbol, price, confidence, uint64(block.timestamp), source);
        emit HeartbeatReceived(symbol, block.timestamp);
    }

    function _validatePrice(
        bytes32 symbol,
        int64 price,
        uint32 confidence
    ) internal view virtual {
        require(price > 0, "Invalid price");
        require(confidence <= 10000, "Invalid confidence");
        require(isSupported[symbol], "Symbol not supported");
    }

    function _checkPriceDeviation(
        bytes32 symbol,
        int64 newPrice,
        int64 oldPrice
    ) internal view {
        if (oldPrice == 0) return;

        int64 deviation = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
        uint256 deviationBps = (uint256(uint64(deviation)) * 10000) / uint256(uint64(oldPrice));

        require(deviationBps <= maxPriceDeviationBps, "Price deviation too high");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                           PRICE QUERIES
    // ═════════════════════════════════════════════════════════════════════════

    function getPrice(bytes32 symbol) external view returns (int64 price, uint256 timestamp) {
        PriceData memory data = prices[symbol];
        require(data.timestamp > 0, "Price not available");
        require(!_isStale(symbol), "Price is stale");
        
        return (data.price, data.timestamp);
    }

    function getPriceUnsafe(bytes32 symbol) external view returns (int64 price, uint256 timestamp) {
        PriceData memory data = prices[symbol];
        return (data.price, data.timestamp);
    }

    function getPriceWithConfidence(bytes32 symbol) 
        external 
        view 
        returns (int64 price, uint32 confidence, uint256 timestamp) 
    {
        PriceData memory data = prices[symbol];
        require(data.timestamp > 0, "Price not available");
        require(!_isStale(symbol), "Price is stale");
        
        return (data.price, data.confidence, data.timestamp);
    }

    function getPriceBatch(bytes32[] calldata _symbols) 
        external 
        view 
        returns (int64[] memory _prices, uint256[] memory timestamps) 
    {
        _prices = new int64[](_symbols.length);
        timestamps = new uint256[](_symbols.length);

        for (uint256 i = 0; i < _symbols.length; i++) {
            PriceData memory data = prices[_symbols[i]];
            _prices[i] = data.price;
            timestamps[i] = data.timestamp;
        }

        return (_prices, timestamps);
    }

    function getHistoricalPrices(bytes32 symbol, uint256 count) 
        external 
        view 
        returns (HistoricalPrice[] memory) 
    {
        HistoricalPrice[] storage history = priceHistory[symbol];
        uint256 length = count > history.length ? history.length : count;
        
        HistoricalPrice[] memory result = new HistoricalPrice[](length);
        uint256 startIndex = history.length - length;
        
        for (uint256 i = 0; i < length; i++) {
            result[i] = history[startIndex + i];
        }
        
        return result;
    }

    function isStale(bytes32 symbol) external view returns (bool) {
        return _isStale(symbol);
    }

    function _isStale(bytes32 symbol) internal view virtual returns (bool) {
        PriceData memory data = prices[symbol];
        if (data.timestamp == 0) return true;
        return block.timestamp - data.timestamp > stalenessThreshold;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                         SYMBOL MANAGEMENT
    // ═════════════════════════════════════════════════════════════════════════

    function addSymbol(bytes32 symbol, string calldata name) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(!isSupported[symbol], "Symbol already supported");
        
        isSupported[symbol] = true;
        symbols.push(symbol);
        
        emit SymbolAdded(symbol, name);
    }

    function removeSymbol(bytes32 symbol) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(isSupported[symbol], "Symbol not supported");
        
        isSupported[symbol] = false;
        
        emit SymbolRemoved(symbol);
    }

    function getSupportedSymbols() external view returns (bytes32[] memory) {
        return symbols;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                         EMERGENCY FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    function setEmergencyPrice(
        bytes32 symbol,
        int64 price,
        uint32 confidence
    ) external onlyRole(EMERGENCY_ROLE) {
        require(isSupported[symbol], "Symbol not supported");
        
        prices[symbol] = PriceData({
            price: price,
            confidence: confidence,
            timestamp: uint64(block.timestamp),
            source: msg.sender
        });

        emit EmergencyPriceSet(symbol, price, msg.sender);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    function updateStalenessThreshold(uint256 newThreshold) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        uint256 oldThreshold = stalenessThreshold;
        stalenessThreshold = newThreshold;
        emit StalenessThresholdUpdated(oldThreshold, newThreshold);
    }

    function updateMaxDeviation(uint256 newDeviation) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(newDeviation <= 5000, "Deviation too high"); // Max 50%
        uint256 oldDeviation = maxPriceDeviationBps;
        maxPriceDeviationBps = newDeviation;
        emit MaxDeviationUpdated(oldDeviation, newDeviation);
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
        require(newImplementation != address(0), "Zero implementation");
    }

    uint256[50] private __gap;
}
