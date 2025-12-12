// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./OracleBase.sol";

/**
 * @title CryptoPriceOracle
 * @notice Oracle A - Cryptocurrency price feeds (24/7 trading)
 * @dev High-frequency updates for crypto pairs (BTC, ETH, SOL, etc.)
 * 
 * **Asset Class:** Cryptocurrencies
 * **Trading Hours:** 24/7/365
 * **Update Frequency:** 1 second (sub-second capable)
 * **Staleness Threshold:** 60 seconds
 * 
 * **Supported Pairs:**
 * - BTC/USD, ETH/USD, SOL/USD, BNB/USD
 * - Major altcoins and stablecoins
 * - Crypto/Crypto pairs (BTC/ETH, etc.)
 * 
 * **Key Features:**
 * - Real-time price updates
 * - 24/7 availability
 * - High-frequency submission
 * - Millisecond precision timestamps
 * - Volatility tracking
 * 
 * **Data Sources:**
 * - Off-chain aggregators
 * - Exchange APIs (Binance, Coinbase, Kraken)
 * - Decentralized price submitters (future)
 * - PAX-backed oracle network (future)
 */
contract CryptoPriceOracle is OracleBase {
    /// @notice Volatility tracking window (1 hour)
    uint256 public constant VOLATILITY_WINDOW = 1 hours;
    
    /// @notice Minimum update interval (1 second)
    uint256 public constant MIN_UPDATE_INTERVAL = 1 seconds;

    /// @notice Mapping of symbol to volatility data
    mapping(bytes32 => uint256) public volatility24h;
    
    /// @notice Mapping of symbol to 24h high
    mapping(bytes32 => int64) public high24h;
    
    /// @notice Mapping of symbol to 24h low
    mapping(bytes32 => int64) public low24h;
    
    /// @notice Mapping of symbol to 24h volume
    mapping(bytes32 => uint256) public volume24h;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    event VolatilityUpdated(bytes32 indexed symbol, uint256 volatility);
    event High24hUpdated(bytes32 indexed symbol, int64 high);
    event Low24hUpdated(bytes32 indexed symbol, int64 low);

    function initialize(
        address _admin,
        address[] memory _feeders
    ) external initializer {
        __OracleBase_init(
            "CryptoPriceOracle",
            "1.0.0",
            60 seconds,      // Staleness: 60s
            10 seconds,      // Heartbeat: 10s
            _admin
        );

        for (uint256 i = 0; i < _feeders.length; i++) {
            _grantRole(FEEDER_ROLE, _feeders[i]);
        }

        // Add default crypto pairs
        _addDefaultSymbols();
    }

    function _addDefaultSymbols() internal {
        bytes32[] memory defaultSymbols = new bytes32[](10);
        defaultSymbols[0] = keccak256("BTC/USD");
        defaultSymbols[1] = keccak256("ETH/USD");
        defaultSymbols[2] = keccak256("SOL/USD");
        defaultSymbols[3] = keccak256("BNB/USD");
        defaultSymbols[4] = keccak256("XRP/USD");
        defaultSymbols[5] = keccak256("ADA/USD");
        defaultSymbols[6] = keccak256("DOGE/USD");
        defaultSymbols[7] = keccak256("MATIC/USD");
        defaultSymbols[8] = keccak256("DOT/USD");
        defaultSymbols[9] = keccak256("AVAX/USD");

        for (uint256 i = 0; i < defaultSymbols.length; i++) {
            isSupported[defaultSymbols[i]] = true;
            symbols.push(defaultSymbols[i]);
        }
    }

    /**
     * @notice Update price with additional crypto-specific data
     * @param symbol Trading pair symbol
     * @param price Current price
     * @param confidence Confidence interval
     * @param dailyVolume 24-hour trading volume
     */
    function updatePriceWithVolume(
        bytes32 symbol,
        int64 price,
        uint32 confidence,
        uint256 dailyVolume
    ) external onlyRole(FEEDER_ROLE) whenNotPaused {
        _validatePrice(symbol, price, confidence);
        _updatePrice(symbol, price, confidence, msg.sender);
        
        // Update 24h stats
        _update24hStats(symbol, price, dailyVolume);
    }

    function _update24hStats(bytes32 symbol, int64 price, uint256 volume) internal {
        // Update high/low
        if (high24h[symbol] == 0 || price > high24h[symbol]) {
            high24h[symbol] = price;
            emit High24hUpdated(symbol, price);
        }
        
        if (low24h[symbol] == 0 || price < low24h[symbol]) {
            low24h[symbol] = price;
            emit Low24hUpdated(symbol, price);
        }
        
        // Update volume
        volume24h[symbol] = volume;
        
        // Calculate volatility
        if (high24h[symbol] > 0 && low24h[symbol] > 0) {
            uint256 range = uint256(uint64(high24h[symbol] - low24h[symbol]));
            uint256 avg = uint256(uint64((high24h[symbol] + low24h[symbol]) / 2));
            if (avg > 0) {
                volatility24h[symbol] = (range * 10000) / avg; // Basis points
                emit VolatilityUpdated(symbol, volatility24h[symbol]);
            }
        }
    }

    /**
     * @notice Get comprehensive crypto price data
     */
    function getCryptoPrice(bytes32 symbol) 
        external 
        view 
        returns (
            int64 price,
            uint32 confidence,
            uint256 timestamp,
            uint256 volatility,
            int64 high,
            int64 low,
            uint256 volume
        ) 
    {
        PriceData memory data = prices[symbol];
        require(data.timestamp > 0, "Price not available");
        
        return (
            data.price,
            data.confidence,
            data.timestamp,
            volatility24h[symbol],
            high24h[symbol],
            low24h[symbol],
            volume24h[symbol]
        );
    }

    /**
     * @notice Reset 24h stats (called daily)
     */
    function reset24hStats(bytes32 symbol) external onlyRole(ADMIN_ROLE) {
        high24h[symbol] = 0;
        low24h[symbol] = 0;
        volume24h[symbol] = 0;
        volatility24h[symbol] = 0;
    }
}
