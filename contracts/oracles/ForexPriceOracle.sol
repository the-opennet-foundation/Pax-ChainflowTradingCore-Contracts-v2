// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./OracleBase.sol";

/**
 * @title ForexPriceOracle
 * @notice Oracle C - Forex price feeds (24/5 trading)
 * @dev Currency pair price feeds with session awareness
 * 
 * **Asset Class:** Foreign Exchange (Forex)
 * **Trading Hours:** 24/5 (Sun 5pm - Fri 5pm EST)
 * **Update Frequency:** 1 minute (major pairs), 5 minutes (exotics)
 * **Staleness Threshold:** 300 seconds (5 minutes)
 * 
 * **Supported Pairs:**
 * - Major pairs (EUR/USD, GBP/USD, USD/JPY, USD/CHF)
 * - Minor pairs (EUR/GBP, EUR/JPY, GBP/JPY)
 * - Exotic pairs (USD/TRY, USD/ZAR, etc.)
 * 
 * **Key Features:**
 * - Trading session awareness (Sydney, Tokyo, London, NY)
 * - Weekend gap tracking
 * - Pip precision
 * - Liquidity indicators
 * - Central bank event flagging
 * 
 * **Data Sources:**
 * - FX aggregators
 * - Institutional feeds
 * - Decentralized price submitters (future)
 */
contract ForexPriceOracle is OracleBase {
    /// @notice Trading sessions
    enum TradingSession {
        Sydney,     // 22:00 - 07:00 UTC
        Tokyo,      // 00:00 - 09:00 UTC
        London,     // 08:00 - 17:00 UTC
        NewYork     // 13:00 - 22:00 UTC
    }

    struct ForexData {
        int64 bidPrice;
        int64 askPrice;
        uint32 spread;        // in pips
        uint256 liquidity;    // relative liquidity score
        TradingSession activeSession;
        bool isWeekend;
        uint256 lastSessionClose;
    }

    /// @notice Mapping of symbol to forex-specific data
    mapping(bytes32 => ForexData) public forexData;
    
    /// @notice Major pairs (higher update frequency)
    mapping(bytes32 => bool) public isMajorPair;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    event SpreadUpdated(bytes32 indexed symbol, uint32 spread);
    event SessionChanged(TradingSession newSession);
    event WeekendStarted();
    event WeekendEnded();

    function initialize(
        address _admin,
        address[] memory _feeders
    ) external initializer {
        __OracleBase_init(
            "ForexPriceOracle",
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
        bytes32[] memory defaultSymbols = new bytes32[](10);
        defaultSymbols[0] = keccak256("EUR/USD");
        defaultSymbols[1] = keccak256("GBP/USD");
        defaultSymbols[2] = keccak256("USD/JPY");
        defaultSymbols[3] = keccak256("USD/CHF");
        defaultSymbols[4] = keccak256("AUD/USD");
        defaultSymbols[5] = keccak256("USD/CAD");
        defaultSymbols[6] = keccak256("NZD/USD");
        defaultSymbols[7] = keccak256("EUR/GBP");
        defaultSymbols[8] = keccak256("EUR/JPY");
        defaultSymbols[9] = keccak256("GBP/JPY");

        for (uint256 i = 0; i < defaultSymbols.length; i++) {
            isSupported[defaultSymbols[i]] = true;
            symbols.push(defaultSymbols[i]);
            
            // Mark first 7 as major pairs
            if (i < 7) {
                isMajorPair[defaultSymbols[i]] = true;
            }
        }
    }

    /**
     * @notice Update forex price with bid/ask spread
     */
    function updateForexPrice(
        bytes32 symbol,
        int64 bidPrice,
        int64 askPrice,
        uint32 confidence,
        uint256 liquidity
    ) external onlyRole(FEEDER_ROLE) whenNotPaused {
        require(bidPrice > 0 && askPrice > 0, "Invalid prices");
        require(askPrice >= bidPrice, "Ask < Bid");
        
        int64 midPrice = (bidPrice + askPrice) / 2;
        _validatePrice(symbol, midPrice, confidence);
        _updatePrice(symbol, midPrice, confidence, msg.sender);
        
        ForexData storage data = forexData[symbol];
        data.bidPrice = bidPrice;
        data.askPrice = askPrice;
        data.spread = uint32((uint256(uint64(askPrice - bidPrice)) * 10000) / uint256(uint64(midPrice))); // Spread in bps
        data.liquidity = liquidity;
        data.activeSession = _getCurrentSession();
        
        emit SpreadUpdated(symbol, data.spread);
    }

    /**
     * @notice Get current trading session
     */
    function _getCurrentSession() internal view returns (TradingSession) {
        uint256 hourUTC = (block.timestamp / 1 hours) % 24;
        
        if (hourUTC >= 22 || hourUTC < 7) {
            return TradingSession.Sydney;
        } else if (hourUTC >= 0 && hourUTC < 9) {
            return TradingSession.Tokyo;
        } else if (hourUTC >= 8 && hourUTC < 17) {
            return TradingSession.London;
        } else {
            return TradingSession.NewYork;
        }
    }

    /**
     * @notice Get comprehensive forex data
     */
    function getForexPrice(bytes32 symbol) 
        external 
        view 
        returns (
            int64 bidPrice,
            int64 askPrice,
            int64 midPrice,
            uint32 spread,
            uint256 liquidity,
            TradingSession session,
            uint256 timestamp
        ) 
    {
        PriceData memory priceData = prices[symbol];
        ForexData memory data = forexData[symbol];
        
        require(priceData.timestamp > 0, "Price not available");
        
        return (
            data.bidPrice,
            data.askPrice,
            priceData.price,
            data.spread,
            data.liquidity,
            data.activeSession,
            priceData.timestamp
        );
    }

    /**
     * @notice Set weekend status
     */
    function setWeekendStatus(bool _isWeekend) external onlyRole(ADMIN_ROLE) {
        if (_isWeekend) {
            emit WeekendStarted();
        } else {
            emit WeekendEnded();
        }
        
        // Update all forex data
        for (uint256 i = 0; i < symbols.length; i++) {
            forexData[symbols[i]].isWeekend = _isWeekend;
            if (_isWeekend) {
                forexData[symbols[i]].lastSessionClose = block.timestamp;
            }
        }
    }

    /**
     * @notice Check if forex market is open
     */
    function isForexMarketOpen() public view returns (bool) {
        // Forex trades 24/5, closed on weekends
        uint256 dayOfWeek = (block.timestamp / 1 days + 4) % 7; // 0 = Monday
        return dayOfWeek < 5; // Monday to Friday
    }

    /**
     * @notice Mark symbol as major pair
     */
    function setMajorPair(bytes32 symbol, bool major) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        isMajorPair[symbol] = major;
    }

    /**
     * @notice Get current active session
     */
    function getCurrentSession() external view returns (TradingSession) {
        return _getCurrentSession();
    }

    /**
     * @notice Override staleness check (major pairs vs exotic)
     */
    function _isStale(bytes32 symbol) internal view override returns (bool) {
        PriceData memory data = prices[symbol];
        if (data.timestamp == 0) return true;
        
        // Weekend: 48 hour staleness allowed
        if (!isForexMarketOpen()) {
            return block.timestamp - data.timestamp > 48 hours;
        }
        
        // Major pairs: 1 minute staleness
        if (isMajorPair[symbol]) {
            return block.timestamp - data.timestamp > 60 seconds;
        }
        
        // Exotic pairs: 5 minute staleness
        return block.timestamp - data.timestamp > 300 seconds;
    }
}
