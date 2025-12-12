// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./OracleBase.sol";

/**
 * @title StockPriceOracle
 * @notice Oracle B - Stock synthetic price feeds (market hours only)
 * @dev Price feeds for synthetic stock pairs during trading hours
 * 
 * **Asset Class:** Stocks & Equities
 * **Trading Hours:** Mon-Fri 9:30 AM - 4:00 PM EST (market dependent)
 * **Update Frequency:** Daily close + intraday (during hours)
 * **Staleness Threshold:** 24 hours (outside hours), 5 minutes (during hours)
 * 
 * **Supported Stocks:**
 * - US Equities (AAPL, MSFT, GOOGL, TSLA, etc.)
 * - International ADRs
 * - Synthetic stock perpetuals
 * 
 * **Key Features:**
 * - Market hours awareness
 * - Pre-market/After-hours pricing
 * - Daily open/close tracking
 * - Trading halt detection
 * - Earnings announcement flags
 * 
 * **Data Sources:**
 * - Market data providers
 * - Exchange feeds
 * - Synthetic price calculators
 */
contract StockPriceOracle is OracleBase {
    /// @notice Market hours start (seconds since midnight UTC)
    uint256 public marketOpen;
    
    /// @notice Market hours end (seconds since midnight UTC)
    uint256 public marketClose;
    
    /// @notice Weekend flag tracking
    bool public isWeekend;

    struct StockData {
        int64 openPrice;
        int64 closePrice;
        int64 dayHigh;
        int64 dayLow;
        uint256 volume;
        bool isHalted;
        uint256 lastTradeDay;
    }

    /// @notice Mapping of symbol to stock-specific data
    mapping(bytes32 => StockData) public stockData;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    event MarketHoursUpdated(uint256 open, uint256 close);
    event TradingHalted(bytes32 indexed symbol);
    event TradingResumed(bytes32 indexed symbol);
    event DailyCloseRecorded(bytes32 indexed symbol, int64 closePrice, uint256 volume);

    function initialize(
        address _admin,
        address[] memory _feeders
    ) external initializer {
        __OracleBase_init(
            "StockPriceOracle",
            "1.0.0",
            86400 seconds,   // Staleness: 24h (outside market hours)
            300 seconds,     // Heartbeat: 5min (during market hours)
            _admin
        );

        for (uint256 i = 0; i < _feeders.length; i++) {
            _grantRole(FEEDER_ROLE, _feeders[i]);
        }

        // Set default NYSE hours (9:30 AM - 4:00 PM EST = 14:30 - 21:00 UTC)
        marketOpen = 14 hours + 30 minutes;
        marketClose = 21 hours;

        _addDefaultSymbols();
    }

    function _addDefaultSymbols() internal {
        bytes32[] memory defaultSymbols = new bytes32[](15);
        defaultSymbols[0] = keccak256("AAPL/USD");
        defaultSymbols[1] = keccak256("MSFT/USD");
        defaultSymbols[2] = keccak256("GOOGL/USD");
        defaultSymbols[3] = keccak256("AMZN/USD");
        defaultSymbols[4] = keccak256("TSLA/USD");
        defaultSymbols[5] = keccak256("NVDA/USD");
        defaultSymbols[6] = keccak256("META/USD");
        defaultSymbols[7] = keccak256("NFLX/USD");
        defaultSymbols[8] = keccak256("AMD/USD");
        defaultSymbols[9] = keccak256("BABA/USD");
        defaultSymbols[10] = keccak256("JPM/USD");
        defaultSymbols[11] = keccak256("V/USD");
        defaultSymbols[12] = keccak256("WMT/USD");
        defaultSymbols[13] = keccak256("DIS/USD");
        defaultSymbols[14] = keccak256("BA/USD");

        for (uint256 i = 0; i < defaultSymbols.length; i++) {
            isSupported[defaultSymbols[i]] = true;
            symbols.push(defaultSymbols[i]);
        }
    }

    /**
     * @notice Update stock price with market data
     */
    function updateStockPrice(
        bytes32 symbol,
        int64 price,
        uint32 confidence,
        uint256 volume,
        bool isOpen
    ) external onlyRole(FEEDER_ROLE) whenNotPaused {
        _validatePrice(symbol, price, confidence);
        _updatePrice(symbol, price, confidence, msg.sender);
        
        StockData storage data = stockData[symbol];
        
        // If market opening, set open price
        if (isOpen && data.openPrice == 0) {
            data.openPrice = price;
        }
        
        // Update high/low
        if (data.dayHigh == 0 || price > data.dayHigh) {
            data.dayHigh = price;
        }
        if (data.dayLow == 0 || price < data.dayLow) {
            data.dayLow = price;
        }
        
        data.volume = volume;
        data.lastTradeDay = block.timestamp / 1 days;
    }

    /**
     * @notice Record daily close price
     */
    function recordDailyClose(
        bytes32 symbol,
        int64 closePrice,
        uint256 finalVolume
    ) external onlyRole(FEEDER_ROLE) {
        StockData storage data = stockData[symbol];
        data.closePrice = closePrice;
        data.volume = finalVolume;
        
        emit DailyCloseRecorded(symbol, closePrice, finalVolume);
    }

    /**
     * @notice Halt trading for a symbol
     */
    function haltTrading(bytes32 symbol) external onlyRole(ADMIN_ROLE) {
        stockData[symbol].isHalted = true;
        emit TradingHalted(symbol);
    }

    /**
     * @notice Resume trading for a symbol
     */
    function resumeTrading(bytes32 symbol) external onlyRole(ADMIN_ROLE) {
        stockData[symbol].isHalted = false;
        emit TradingResumed(symbol);
    }

    /**
     * @notice Check if market is currently open
     */
    function isMarketOpen() public view returns (bool) {
        if (isWeekend) return false;
        
        uint256 timeOfDay = block.timestamp % 1 days;
        return timeOfDay >= marketOpen && timeOfDay <= marketClose;
    }

    /**
     * @notice Get comprehensive stock data
     */
    function getStockPrice(bytes32 symbol) 
        external 
        view 
        returns (
            int64 currentPrice,
            int64 openPrice,
            int64 closePrice,
            int64 dayHigh,
            int64 dayLow,
            uint256 volume,
            bool isHalted,
            uint256 timestamp
        ) 
    {
        PriceData memory priceData = prices[symbol];
        StockData memory data = stockData[symbol];
        
        return (
            priceData.price,
            data.openPrice,
            data.closePrice,
            data.dayHigh,
            data.dayLow,
            data.volume,
            data.isHalted,
            priceData.timestamp
        );
    }

    /**
     * @notice Reset daily stats (called at market close)
     */
    function resetDailyStats(bytes32 symbol) external onlyRole(ADMIN_ROLE) {
        StockData storage data = stockData[symbol];
        data.openPrice = 0;
        data.dayHigh = 0;
        data.dayLow = 0;
        // Keep closePrice and volume for historical reference
    }

    /**
     * @notice Update market hours
     */
    function updateMarketHours(uint256 _open, uint256 _close) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(_open < _close, "Invalid hours");
        require(_close <= 24 hours, "Invalid close time");
        
        marketOpen = _open;
        marketClose = _close;
        
        emit MarketHoursUpdated(_open, _close);
    }

    /**
     * @notice Set weekend flag
     */
    function setWeekend(bool _isWeekend) external onlyRole(ADMIN_ROLE) {
        isWeekend = _isWeekend;
    }

    /**
     * @notice Override staleness check for stocks (market hours aware)
     */
    function _isStale(bytes32 symbol) internal view override returns (bool) {
        PriceData memory data = prices[symbol];
        if (data.timestamp == 0) return true;
        
        // During market hours: 5 minute staleness
        if (isMarketOpen()) {
            return block.timestamp - data.timestamp > 300;
        }
        
        // Outside market hours: 24 hour staleness
        return block.timestamp - data.timestamp > 86400;
    }
}
