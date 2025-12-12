// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./OracleBase.sol";

/**
 * @title CommodityPriceOracle
 * @notice Oracle D - Commodities and Metals synthetic price feeds
 * @dev Price feeds for commodity futures and precious metals
 * 
 * **Asset Class:** Commodities & Precious Metals
 * **Trading Hours:** Varies by commodity
 * **Update Frequency:** 1-5 minutes (depends on commodity)
 * **Staleness Threshold:** 3600 seconds (1 hour)
 * 
 * **Supported Commodities:**
 * - Energy: WTI Crude, Brent Crude, Natural Gas
 * - Metals: Gold, Silver, Copper, Platinum, Palladium
 * - Agriculture: Wheat, Corn, Soybeans, Coffee, Sugar
 * 
 * **Key Features:**
 * - Futures contract awareness
 * - Expiration tracking
 * - Storage cost factors
 * - Seasonality indicators
 * - Supply/demand metrics
 * 
 * **Data Sources:**
 * - CME, NYMEX, COMEX feeds
 * - Spot price aggregators
 * - Futures settlement data
 */
contract CommodityPriceOracle is OracleBase {
    enum CommodityType {
        Energy,
        PreciousMetal,
        IndustrialMetal,
        Agriculture,
        Livestock
    }

    struct CommodityData {
        CommodityType commodityType;
        int64 spotPrice;
        int64 futuresPrice;
        uint256 contractExpiry;
        uint32 storageCost;      // Annualized storage cost (bps)
        uint256 openInterest;
        bool isPhysicalDelivery;
        uint256 lastSettlement;
    }

    /// @notice Mapping of symbol to commodity-specific data
    mapping(bytes32 => CommodityData) public commodityData;
    
    /// @notice Mapping of commodity type to update frequency
    mapping(CommodityType => uint256) public updateFrequency;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    event FuturesExpiryUpdated(bytes32 indexed symbol, uint256 newExpiry);
    event SettlementRecorded(bytes32 indexed symbol, int64 settlementPrice, uint256 timestamp);
    event StorageCostUpdated(bytes32 indexed symbol, uint32 storageCost);

    function initialize(
        address _admin,
        address[] memory _feeders
    ) external initializer {
        __OracleBase_init(
            "CommodityPriceOracle",
            "1.0.0",
            3600 seconds,    // Staleness: 1 hour
            300 seconds,     // Heartbeat: 5min
            _admin
        );

        for (uint256 i = 0; i < _feeders.length; i++) {
            _grantRole(FEEDER_ROLE, _feeders[i]);
        }

        // Set update frequencies per type
        updateFrequency[CommodityType.Energy] = 60 seconds;
        updateFrequency[CommodityType.PreciousMetal] = 60 seconds;
        updateFrequency[CommodityType.IndustrialMetal] = 300 seconds;
        updateFrequency[CommodityType.Agriculture] = 300 seconds;
        updateFrequency[CommodityType.Livestock] = 600 seconds;

        _addDefaultSymbols();
    }

    function _addDefaultSymbols() internal {
        // Energy
        bytes32 wti = keccak256("WTI/USD");
        bytes32 brent = keccak256("BRENT/USD");
        bytes32 natgas = keccak256("NG/USD");
        
        // Precious Metals
        bytes32 gold = keccak256("XAU/USD");
        bytes32 silver = keccak256("XAG/USD");
        bytes32 platinum = keccak256("XPT/USD");
        
        // Industrial Metals
        bytes32 copper = keccak256("HG/USD");
        
        // Agriculture
        bytes32 wheat = keccak256("ZW/USD");
        bytes32 corn = keccak256("ZC/USD");
        bytes32 soybeans = keccak256("ZS/USD");

        bytes32[] memory defaultSymbols = new bytes32[](10);
        defaultSymbols[0] = wti;
        defaultSymbols[1] = brent;
        defaultSymbols[2] = natgas;
        defaultSymbols[3] = gold;
        defaultSymbols[4] = silver;
        defaultSymbols[5] = platinum;
        defaultSymbols[6] = copper;
        defaultSymbols[7] = wheat;
        defaultSymbols[8] = corn;
        defaultSymbols[9] = soybeans;

        for (uint256 i = 0; i < defaultSymbols.length; i++) {
            isSupported[defaultSymbols[i]] = true;
            symbols.push(defaultSymbols[i]);
        }

        // Set commodity types
        _setCommodityType(wti, CommodityType.Energy);
        _setCommodityType(brent, CommodityType.Energy);
        _setCommodityType(natgas, CommodityType.Energy);
        _setCommodityType(gold, CommodityType.PreciousMetal);
        _setCommodityType(silver, CommodityType.PreciousMetal);
        _setCommodityType(platinum, CommodityType.PreciousMetal);
        _setCommodityType(copper, CommodityType.IndustrialMetal);
        _setCommodityType(wheat, CommodityType.Agriculture);
        _setCommodityType(corn, CommodityType.Agriculture);
        _setCommodityType(soybeans, CommodityType.Agriculture);
    }

    function _setCommodityType(bytes32 symbol, CommodityType _type) internal {
        commodityData[symbol].commodityType = _type;
    }

    /**
     * @notice Update commodity price with futures data
     */
    function updateCommodityPrice(
        bytes32 symbol,
        int64 spotPrice,
        int64 futuresPrice,
        uint32 confidence,
        uint256 openInterest,
        uint256 contractExpiry
    ) external onlyRole(FEEDER_ROLE) whenNotPaused {
        _validatePrice(symbol, spotPrice, confidence);
        _updatePrice(symbol, spotPrice, confidence, msg.sender);
        
        CommodityData storage data = commodityData[symbol];
        data.spotPrice = spotPrice;
        data.futuresPrice = futuresPrice;
        data.openInterest = openInterest;
        
        if (contractExpiry > 0 && contractExpiry != data.contractExpiry) {
            data.contractExpiry = contractExpiry;
            emit FuturesExpiryUpdated(symbol, contractExpiry);
        }
    }

    /**
     * @notice Record daily settlement price
     */
    function recordSettlement(
        bytes32 symbol,
        int64 settlementPrice
    ) external onlyRole(FEEDER_ROLE) {
        CommodityData storage data = commodityData[symbol];
        data.lastSettlement = block.timestamp;
        
        emit SettlementRecorded(symbol, settlementPrice, block.timestamp);
    }

    /**
     * @notice Update storage cost for commodity
     */
    function updateStorageCost(
        bytes32 symbol,
        uint32 storageCostBps
    ) external onlyRole(ADMIN_ROLE) {
        commodityData[symbol].storageCost = storageCostBps;
        emit StorageCostUpdated(symbol, storageCostBps);
    }

    /**
     * @notice Get comprehensive commodity data
     */
    function getCommodityPrice(bytes32 symbol) 
        external 
        view 
        returns (
            int64 spotPrice,
            int64 futuresPrice,
            uint32 confidence,
            CommodityType commodityType,
            uint256 contractExpiry,
            uint256 openInterest,
            uint32 storageCost,
            uint256 timestamp
        ) 
    {
        PriceData memory priceData = prices[symbol];
        CommodityData memory data = commodityData[symbol];
        
        require(priceData.timestamp > 0, "Price not available");
        
        return (
            data.spotPrice,
            data.futuresPrice,
            priceData.confidence,
            data.commodityType,
            data.contractExpiry,
            data.openInterest,
            data.storageCost,
            priceData.timestamp
        );
    }

    /**
     * @notice Check if futures contract is near expiry
     */
    function isNearExpiry(bytes32 symbol) external view returns (bool) {
        CommodityData memory data = commodityData[symbol];
        if (data.contractExpiry == 0) return false;
        
        // Near expiry if less than 7 days remaining
        return block.timestamp + 7 days >= data.contractExpiry;
    }

    /**
     * @notice Calculate contango/backwardation
     * @return percentage Positive = contango, Negative = backwardation (bps)
     */
    function getContango(bytes32 symbol) external view returns (int256 percentage) {
        CommodityData memory data = commodityData[symbol];
        if (data.spotPrice == 0) return 0;
        
        int256 diff = int256(data.futuresPrice) - int256(data.spotPrice);
        percentage = (diff * 10000) / int256(data.spotPrice);
        
        return percentage;
    }

    /**
     * @notice Set commodity type
     */
    function setCommodityType(bytes32 symbol, CommodityType _type) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        commodityData[symbol].commodityType = _type;
    }

    /**
     * @notice Override staleness check (commodity type specific)
     */
    function _isStale(bytes32 symbol) internal view override returns (bool) {
        PriceData memory data = prices[symbol];
        if (data.timestamp == 0) return true;
        
        CommodityData memory commodityInfo = commodityData[symbol];
        uint256 maxAge = updateFrequency[commodityInfo.commodityType];
        
        if (maxAge == 0) maxAge = 3600; // Default 1 hour
        
        return block.timestamp - data.timestamp > maxAge;
    }
}
