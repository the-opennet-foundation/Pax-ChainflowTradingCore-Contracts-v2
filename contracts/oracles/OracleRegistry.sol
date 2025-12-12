// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./CryptoPriceOracle.sol";
import "./StockPriceOracle.sol";
import "./ForexPriceOracle.sol";
import "./CommodityPriceOracle.sol";
import "./IndexPriceOracle.sol";

/**
 * @title OracleRegistry
 * @notice Central coordinator for all price oracles
 * @dev Unified interface for querying prices across all asset classes
 * 
 * **Purpose:**
 * - Route price queries to appropriate oracle
 * - Aggregate multi-asset quotes
 * - Manage oracle contract addresses
 * - Provide unified JSON-RPC interface
 * - Health monitoring across all oracles
 * 
 * **Architecture:**
 * ```
 * OracleRegistry (coordinator)
 *     ├── CryptoPriceOracle (24/7)
 *     ├── StockPriceOracle (market hours)
 *     ├── ForexPriceOracle (24/5)
 *     ├── CommodityPriceOracle (varies)
 *     └── IndexPriceOracle (market hours)
 * ```
 * 
 * **Query Patterns:**
 * - Single price: getPrice(symbol)
 * - Batch prices: getPriceBatch(symbols[])
 * - Cross-asset: Get BTC, AAPL, EUR/USD in one call
 * - Health check: Check all oracles status
 * 
 * **JSON-RPC Compatibility:**
 * All functions designed for easy RPC access:
 * - eth_call compatible
 * - Standard return formats
 * - Gas-optimized view functions
 */
contract OracleRegistry is 
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    enum AssetClass {
        Crypto,
        Stock,
        Forex,
        Commodity,
        Index
    }

    struct OracleAddresses {
        address cryptoOracle;
        address stockOracle;
        address forexOracle;
        address commodityOracle;
        address indexOracle;
    }

    struct PriceQuote {
        bytes32 symbol;
        int64 price;
        uint256 timestamp;
        uint32 confidence;
        AssetClass assetClass;
        bool isValid;
    }

    struct OracleHealth {
        AssetClass assetClass;
        address oracleAddress;
        bool isActive;
        uint256 lastUpdate;
        uint256 symbolCount;
    }

    /// @notice Oracle contract addresses
    OracleAddresses public oracles;
    
    /// @notice Mapping of symbol to asset class
    mapping(bytes32 => AssetClass) public symbolToAssetClass;
    
    /// @notice Registered symbols
    bytes32[] public allSymbols;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    event OracleUpdated(AssetClass indexed assetClass, address oldOracle, address newOracle);
    event SymbolMapped(bytes32 indexed symbol, AssetClass assetClass);
    event HealthCheckPerformed(uint256 timestamp, uint256 healthyOracles, uint256 totalOracles);

    // ═════════════════════════════════════════════════════════════════════════
    //                            INITIALIZATION
    // ═════════════════════════════════════════════════════════════════════════

    function initialize(
        address _admin,
        address _cryptoOracle,
        address _stockOracle,
        address _forexOracle,
        address _commodityOracle,
        address _indexOracle
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);

        oracles.cryptoOracle = _cryptoOracle;
        oracles.stockOracle = _stockOracle;
        oracles.forexOracle = _forexOracle;
        oracles.commodityOracle = _commodityOracle;
        oracles.indexOracle = _indexOracle;

        _mapDefaultSymbols();
    }

    function _mapDefaultSymbols() internal {
        // Crypto
        _mapSymbol(keccak256("BTC/USD"), AssetClass.Crypto);
        _mapSymbol(keccak256("ETH/USD"), AssetClass.Crypto);
        _mapSymbol(keccak256("SOL/USD"), AssetClass.Crypto);
        
        // Stocks
        _mapSymbol(keccak256("AAPL/USD"), AssetClass.Stock);
        _mapSymbol(keccak256("TSLA/USD"), AssetClass.Stock);
        
        // Forex
        _mapSymbol(keccak256("EUR/USD"), AssetClass.Forex);
        _mapSymbol(keccak256("GBP/USD"), AssetClass.Forex);
        
        // Commodities
        _mapSymbol(keccak256("XAU/USD"), AssetClass.Commodity);
        _mapSymbol(keccak256("WTI/USD"), AssetClass.Commodity);
        
        // Indices
        _mapSymbol(keccak256("SPX/USD"), AssetClass.Index);
        _mapSymbol(keccak256("NDX/USD"), AssetClass.Index);
    }

    function _mapSymbol(bytes32 symbol, AssetClass assetClass) internal {
        symbolToAssetClass[symbol] = assetClass;
        allSymbols.push(symbol);
        emit SymbolMapped(symbol, assetClass);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          UNIFIED PRICE QUERIES
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get price for any symbol (auto-routes to correct oracle)
     * @param symbol Symbol to query
     * @return price Current price
     * @return timestamp Last update time
     */
    function getPrice(bytes32 symbol) 
        external 
        view 
        returns (int64 price, uint256 timestamp) 
    {
        AssetClass assetClass = symbolToAssetClass[symbol];
        address oracle = _getOracleAddress(assetClass);
        
        return OracleBase(oracle).getPrice(symbol);
    }

    /**
     * @notice Get price with confidence interval
     */
    function getPriceWithConfidence(bytes32 symbol) 
        external 
        view 
        returns (int64 price, uint32 confidence, uint256 timestamp) 
    {
        AssetClass assetClass = symbolToAssetClass[symbol];
        address oracle = _getOracleAddress(assetClass);
        
        return OracleBase(oracle).getPriceWithConfidence(symbol);
    }

    /**
     * @notice Get comprehensive price quote
     */
    function getPriceQuote(bytes32 symbol) 
        external 
        view 
        returns (PriceQuote memory quote) 
    {
        AssetClass assetClass = symbolToAssetClass[symbol];
        address oracle = _getOracleAddress(assetClass);
        
        try OracleBase(oracle).getPriceWithConfidence(symbol) returns (
            int64 price,
            uint32 confidence,
            uint256 timestamp
        ) {
            quote = PriceQuote({
                symbol: symbol,
                price: price,
                timestamp: timestamp,
                confidence: confidence,
                assetClass: assetClass,
                isValid: true
            });
        } catch {
            quote = PriceQuote({
                symbol: symbol,
                price: 0,
                timestamp: 0,
                confidence: 0,
                assetClass: assetClass,
                isValid: false
            });
        }
        
        return quote;
    }

    /**
     * @notice Get batch prices (cross-asset support)
     * @param symbols Array of symbols to query
     * @return quotes Array of price quotes
     */
    function getPriceBatch(bytes32[] calldata symbols) 
        external 
        view 
        returns (PriceQuote[] memory quotes) 
    {
        quotes = new PriceQuote[](symbols.length);
        
        for (uint256 i = 0; i < symbols.length; i++) {
            quotes[i] = this.getPriceQuote(symbols[i]);
        }
        
        return quotes;
    }

    /**
     * @notice Get all prices for an asset class
     */
    function getPricesByAssetClass(AssetClass assetClass) 
        external 
        view 
        returns (PriceQuote[] memory quotes) 
    {
        // Count symbols in this asset class
        uint256 count = 0;
        for (uint256 i = 0; i < allSymbols.length; i++) {
            if (symbolToAssetClass[allSymbols[i]] == assetClass) {
                count++;
            }
        }
        
        // Collect prices
        quotes = new PriceQuote[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allSymbols.length; i++) {
            if (symbolToAssetClass[allSymbols[i]] == assetClass) {
                quotes[index++] = this.getPriceQuote(allSymbols[i]);
            }
        }
        
        return quotes;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                        ASSET-SPECIFIC QUERIES
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get crypto price with volume data
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
        require(symbolToAssetClass[symbol] == AssetClass.Crypto, "Not crypto symbol");
        return CryptoPriceOracle(oracles.cryptoOracle).getCryptoPrice(symbol);
    }

    /**
     * @notice Get stock price with OHLC data
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
        require(symbolToAssetClass[symbol] == AssetClass.Stock, "Not stock symbol");
        return StockPriceOracle(oracles.stockOracle).getStockPrice(symbol);
    }

    /**
     * @notice Get forex price with bid/ask spread
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
            ForexPriceOracle.TradingSession session,
            uint256 timestamp
        ) 
    {
        require(symbolToAssetClass[symbol] == AssetClass.Forex, "Not forex symbol");
        return ForexPriceOracle(oracles.forexOracle).getForexPrice(symbol);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          HEALTH MONITORING
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get health status of all oracles
     */
    function getOracleHealth() 
        external 
        view 
        returns (OracleHealth[] memory healthReports) 
    {
        healthReports = new OracleHealth[](5);
        
        healthReports[0] = _getHealthForOracle(AssetClass.Crypto);
        healthReports[1] = _getHealthForOracle(AssetClass.Stock);
        healthReports[2] = _getHealthForOracle(AssetClass.Forex);
        healthReports[3] = _getHealthForOracle(AssetClass.Commodity);
        healthReports[4] = _getHealthForOracle(AssetClass.Index);
        
        return healthReports;
    }

    function _getHealthForOracle(AssetClass assetClass) 
        internal 
        view 
        returns (OracleHealth memory health) 
    {
        address oracle = _getOracleAddress(assetClass);
        
        // Count symbols for this oracle
        uint256 symbolCount = 0;
        uint256 lastUpdate = 0;
        
        for (uint256 i = 0; i < allSymbols.length; i++) {
            if (symbolToAssetClass[allSymbols[i]] == assetClass) {
                symbolCount++;
                
                // Get last update time
                try OracleBase(oracle).getPrice(allSymbols[i]) returns (int64, uint256 timestamp) {
                    if (timestamp > lastUpdate) {
                        lastUpdate = timestamp;
                    }
                } catch {}
            }
        }
        
        health = OracleHealth({
            assetClass: assetClass,
            oracleAddress: oracle,
            isActive: oracle != address(0),
            lastUpdate: lastUpdate,
            symbolCount: symbolCount
        });
        
        return health;
    }

    /**
     * @notice Check if symbol has stale price
     */
    function isStale(bytes32 symbol) external view returns (bool) {
        AssetClass assetClass = symbolToAssetClass[symbol];
        address oracle = _getOracleAddress(assetClass);
        
        return OracleBase(oracle).isStale(symbol);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                         ADMIN FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Update oracle address
     */
    function updateOracle(AssetClass assetClass, address newOracle) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(newOracle != address(0), "Zero address");
        
        address oldOracle = _getOracleAddress(assetClass);
        
        if (assetClass == AssetClass.Crypto) {
            oracles.cryptoOracle = newOracle;
        } else if (assetClass == AssetClass.Stock) {
            oracles.stockOracle = newOracle;
        } else if (assetClass == AssetClass.Forex) {
            oracles.forexOracle = newOracle;
        } else if (assetClass == AssetClass.Commodity) {
            oracles.commodityOracle = newOracle;
        } else if (assetClass == AssetClass.Index) {
            oracles.indexOracle = newOracle;
        }
        
        emit OracleUpdated(assetClass, oldOracle, newOracle);
    }

    /**
     * @notice Map symbol to asset class
     */
    function mapSymbol(bytes32 symbol, AssetClass assetClass) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        _mapSymbol(symbol, assetClass);
    }

    /**
     * @notice Get oracle address for asset class
     */
    function _getOracleAddress(AssetClass assetClass) 
        internal 
        view 
        returns (address) 
    {
        if (assetClass == AssetClass.Crypto) return oracles.cryptoOracle;
        if (assetClass == AssetClass.Stock) return oracles.stockOracle;
        if (assetClass == AssetClass.Forex) return oracles.forexOracle;
        if (assetClass == AssetClass.Commodity) return oracles.commodityOracle;
        if (assetClass == AssetClass.Index) return oracles.indexOracle;
        revert("Invalid asset class");
    }

    /**
     * @notice Get all supported symbols
     */
    function getAllSymbols() external view returns (bytes32[] memory) {
        return allSymbols;
    }

    /**
     * @notice Get oracle addresses
     */
    function getOracleAddresses() external view returns (OracleAddresses memory) {
        return oracles;
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
