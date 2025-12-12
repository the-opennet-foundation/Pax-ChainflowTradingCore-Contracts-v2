// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./OracleBase.sol";

/**
 * @title IndexPriceOracle
 * @notice Oracle E - Indices and Index Futures price feeds
 * @dev Price feeds for major stock indices and futures
 * 
 * **Asset Class:** Stock Indices & Index Futures
 * **Trading Hours:** Varies by index (futures trade nearly 24/5)
 * **Update Frequency:** Real-time during trading hours
 * **Staleness Threshold:** 300 seconds (5 minutes) during hours, 24h outside
 * 
 * **Supported Indices:**
 * - US: S&P 500, Nasdaq 100, Dow Jones, Russell 2000
 * - Europe: FTSE 100, DAX, CAC 40, EURO STOXX 50
 * - Asia: Nikkei 225, Hang Seng, Shanghai Composite
 * - Futures: ES, NQ, YM, RTY
 * 
 * **Key Features:**
 * - Cash index vs futures tracking
 * - Constituent weighting
 * - Circuit breaker monitoring
 * - After-hours futures pricing
 * - Index rebalancing tracking
 * 
 * **Data Sources:**
 * - Exchange feeds (CME, ICE, Eurex)
 * - Index providers (S&P, MSCI, FTSE)
 * - Futures settlement data
 */
contract IndexPriceOracle is OracleBase {
    enum IndexType {
        CashIndex,          // Spot index value
        IndexFutures,       // Futures contract
        MiniContract,       // E-mini futures
        MicroContract       // Micro futures
    }

    struct IndexData {
        IndexType indexType;
        int64 cashValue;           // Cash index value
        int64 futuresValue;        // Futures price
        uint256 futuresExpiry;     // Futures contract expiry
        uint32 constituents;       // Number of stocks in index
        int64 dayOpen;
        int64 dayHigh;
        int64 dayLow;
        uint256 volume;
        bool circuitBreakerActive;
        uint256 lastRebalance;
    }

    /// @notice Mapping of symbol to index-specific data
    mapping(bytes32 => IndexData) public indexData;
    
    /// @notice Trading hours per index
    mapping(bytes32 => uint256) public indexTradingHours;
    
    /// @notice Market close times per index
    mapping(bytes32 => uint256) public indexCloseTimes;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    event CircuitBreakerTriggered(bytes32 indexed symbol, int64 price, uint256 timestamp);
    event CircuitBreakerCleared(bytes32 indexed symbol, uint256 timestamp);
    event IndexRebalanced(bytes32 indexed symbol, uint32 newConstituents, uint256 timestamp);
    event FuturesRollover(bytes32 indexed symbol, uint256 oldExpiry, uint256 newExpiry);

    function initialize(
        address _admin,
        address[] memory _feeders
    ) external initializer {
        __OracleBase_init(
            "IndexPriceOracle",
            "1.0.0",
            300 seconds,     // Staleness: 5min
            60 seconds,      // Heartbeat: 1min
            _admin
        );

        for (uint256 i = 0; i < _feeders.length; i++) {
            _grantRole(FEEDER_ROLE, _feeders[i]);
        }

        _addDefaultSymbols();
    }

    function _addDefaultSymbols() internal {
        // US Indices
        bytes32 spx = keccak256("SPX/USD");
        bytes32 ndx = keccak256("NDX/USD");
        bytes32 djia = keccak256("DJI/USD");
        bytes32 rut = keccak256("RUT/USD");
        
        // US Index Futures
        bytes32 es = keccak256("ES/USD");
        bytes32 nq = keccak256("NQ/USD");
        
        // European Indices
        bytes32 ftse = keccak256("FTSE/USD");
        bytes32 dax = keccak256("DAX/USD");
        
        // Asian Indices
        bytes32 nikkei = keccak256("NI225/USD");
        bytes32 hsi = keccak256("HSI/USD");

        bytes32[] memory defaultSymbols = new bytes32[](10);
        defaultSymbols[0] = spx;
        defaultSymbols[1] = ndx;
        defaultSymbols[2] = djia;
        defaultSymbols[3] = rut;
        defaultSymbols[4] = es;
        defaultSymbols[5] = nq;
        defaultSymbols[6] = ftse;
        defaultSymbols[7] = dax;
        defaultSymbols[8] = nikkei;
        defaultSymbols[9] = hsi;

        for (uint256 i = 0; i < defaultSymbols.length; i++) {
            isSupported[defaultSymbols[i]] = true;
            symbols.push(defaultSymbols[i]);
        }

        // Set index types
        _setIndexType(spx, IndexType.CashIndex, 505);
        _setIndexType(ndx, IndexType.CashIndex, 100);
        _setIndexType(djia, IndexType.CashIndex, 30);
        _setIndexType(rut, IndexType.CashIndex, 2000);
        _setIndexType(es, IndexType.IndexFutures, 505);
        _setIndexType(nq, IndexType.IndexFutures, 100);
        _setIndexType(ftse, IndexType.CashIndex, 100);
        _setIndexType(dax, IndexType.CashIndex, 40);
        _setIndexType(nikkei, IndexType.CashIndex, 225);
        _setIndexType(hsi, IndexType.CashIndex, 50);
    }

    function _setIndexType(bytes32 symbol, IndexType _type, uint32 constituents) internal {
        indexData[symbol].indexType = _type;
        indexData[symbol].constituents = constituents;
    }

    /**
     * @notice Update index price with comprehensive data
     */
    function updateIndexPrice(
        bytes32 symbol,
        int64 price,
        uint32 confidence,
        uint256 volume,
        bool isCashIndex
    ) external onlyRole(FEEDER_ROLE) whenNotPaused {
        _validatePrice(symbol, price, confidence);
        _updatePrice(symbol, price, confidence, msg.sender);
        
        IndexData storage data = indexData[symbol];
        
        if (isCashIndex) {
            data.cashValue = price;
        } else {
            data.futuresValue = price;
        }
        
        // Update daily stats
        if (data.dayOpen == 0) {
            data.dayOpen = price;
        }
        if (data.dayHigh == 0 || price > data.dayHigh) {
            data.dayHigh = price;
        }
        if (data.dayLow == 0 || price < data.dayLow) {
            data.dayLow = price;
        }
        
        data.volume = volume;
    }

    /**
     * @notice Update futures-specific data
     */
    function updateFuturesData(
        bytes32 symbol,
        int64 futuresPrice,
        uint32 confidence,
        uint256 contractExpiry
    ) external onlyRole(FEEDER_ROLE) whenNotPaused {
        _validatePrice(symbol, futuresPrice, confidence);
        
        IndexData storage data = indexData[symbol];
        
        uint256 oldExpiry = data.futuresExpiry;
        data.futuresValue = futuresPrice;
        data.futuresExpiry = contractExpiry;
        
        if (oldExpiry > 0 && contractExpiry != oldExpiry) {
            emit FuturesRollover(symbol, oldExpiry, contractExpiry);
        }
    }

    /**
     * @notice Trigger circuit breaker
     */
    function triggerCircuitBreaker(bytes32 symbol) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        indexData[symbol].circuitBreakerActive = true;
        emit CircuitBreakerTriggered(symbol, prices[symbol].price, block.timestamp);
    }

    /**
     * @notice Clear circuit breaker
     */
    function clearCircuitBreaker(bytes32 symbol) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        indexData[symbol].circuitBreakerActive = false;
        emit CircuitBreakerCleared(symbol, block.timestamp);
    }

    /**
     * @notice Record index rebalance
     */
    function recordRebalance(bytes32 symbol, uint32 newConstituents) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        IndexData storage data = indexData[symbol];
        data.constituents = newConstituents;
        data.lastRebalance = block.timestamp;
        
        emit IndexRebalanced(symbol, newConstituents, block.timestamp);
    }

    /**
     * @notice Get comprehensive index data
     */
    function getIndexPrice(bytes32 symbol) 
        external 
        view 
        returns (
            int64 currentPrice,
            int64 cashValue,
            int64 futuresValue,
            IndexType indexType,
            int64 dayOpen,
            int64 dayHigh,
            int64 dayLow,
            uint256 volume,
            bool circuitBreakerActive,
            uint256 timestamp
        ) 
    {
        PriceData memory priceData = prices[symbol];
        IndexData memory data = indexData[symbol];
        
        require(priceData.timestamp > 0, "Price not available");
        
        return (
            priceData.price,
            data.cashValue,
            data.futuresValue,
            data.indexType,
            data.dayOpen,
            data.dayHigh,
            data.dayLow,
            data.volume,
            data.circuitBreakerActive,
            priceData.timestamp
        );
    }

    /**
     * @notice Calculate basis (futures - cash)
     */
    function getBasis(bytes32 symbol) external view returns (int64 basis) {
        IndexData memory data = indexData[symbol];
        require(data.cashValue > 0 && data.futuresValue > 0, "Data not available");
        
        return data.futuresValue - data.cashValue;
    }

    /**
     * @notice Check if futures contract is near expiry
     */
    function isNearExpiry(bytes32 symbol) external view returns (bool) {
        IndexData memory data = indexData[symbol];
        if (data.futuresExpiry == 0) return false;
        
        // Near expiry if less than 3 days remaining
        return block.timestamp + 3 days >= data.futuresExpiry;
    }

    /**
     * @notice Reset daily stats
     */
    function resetDailyStats(bytes32 symbol) external onlyRole(ADMIN_ROLE) {
        IndexData storage data = indexData[symbol];
        data.dayOpen = 0;
        data.dayHigh = 0;
        data.dayLow = 0;
    }

    /**
     * @notice Set trading hours for index
     */
    function setTradingHours(bytes32 symbol, uint256 open, uint256 close) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        indexTradingHours[symbol] = open;
        indexCloseTimes[symbol] = close;
    }

    /**
     * @notice Check if index is currently trading
     */
    function isTrading(bytes32 symbol) public view returns (bool) {
        uint256 open = indexTradingHours[symbol];
        uint256 close = indexCloseTimes[symbol];
        
        if (open == 0 || close == 0) {
            // Futures trade nearly 24/5
            uint256 dayOfWeek = (block.timestamp / 1 days + 4) % 7;
            return dayOfWeek < 5;
        }
        
        uint256 timeOfDay = block.timestamp % 1 days;
        return timeOfDay >= open && timeOfDay <= close;
    }
}
