// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.29;

type UFixed6 is uint256;
type Fixed6 is int256;
type Token18 is address;

struct LinearAdiabatic6 {
    UFixed6 linearFee;
    UFixed6 proportionalFee;
    UFixed6 adiabaticFee;
    UFixed6 scale;
}

struct NoopAdiabatic6 {
    UFixed6 linearFee;
    UFixed6 proportionalFee;
    UFixed6 scale;
}

struct UJumpRateUtilizationCurve6 {
    UFixed6 minRate;
    UFixed6 maxRate;
    UFixed6 targetRate;
    UFixed6 targetUtilization;
}

struct PController6 {
    UFixed6 k;
    Fixed6 min;
    Fixed6 max;
}

struct OracleVersion {
    uint256 timestamp;
    Fixed6 price;
    bool valid;
}

struct ProtocolParameter {
    UFixed6 maxFee;
    UFixed6 maxLiquidationFee;
    UFixed6 maxCut;
    UFixed6 maxRate;
    UFixed6 minMaintenance;
    UFixed6 minEfficiency;
    UFixed6 referralFee;
    UFixed6 minScale;
    uint256 maxStaleAfter;
}

struct MarketParameter {
    UFixed6 fundingFee;
    UFixed6 interestFee;
    UFixed6 makerFee;
    UFixed6 takerFee;
    UFixed6 riskFee;
    uint256 maxPendingGlobal;
    uint256 maxPendingLocal;
    UFixed6 maxPriceDeviation;
    bool closed;
    bool settle;
}

struct RiskParameter {
    UFixed6 margin;
    UFixed6 maintenance;
    LinearAdiabatic6 takerFee;
    NoopAdiabatic6 makerFee;
    UFixed6 makerLimit;
    UFixed6 efficiencyLimit;
    UFixed6 liquidationFee;
    UJumpRateUtilizationCurve6 utilizationCurve;
    PController6 pController;
    UFixed6 minMargin;
    UFixed6 minMaintenance;
    uint256 staleAfter;
    bool makerReceiveOnly;
}

struct Order {
    uint256 timestamp;
    uint256 orders;
    Fixed6 collateral;
    UFixed6 makerPos;
    UFixed6 makerNeg;
    UFixed6 longPos;
    UFixed6 longNeg;
    UFixed6 shortPos;
    UFixed6 shortNeg;
    uint256 protection;
    uint256 invalidation;
    UFixed6 makerReferral;
    UFixed6 takerReferral;
}

struct Guarantee {
    uint256 orders;
    Fixed6 notional;
    UFixed6 longPos;
    UFixed6 longNeg;
    UFixed6 shortPos;
    UFixed6 shortNeg;
    UFixed6 takerFee;
    UFixed6 orderReferral;
    UFixed6 solverReferral;
}

struct VersionAccumulationResult {
    UFixed6 tradeFee;
    UFixed6 subtractiveFee;
    Fixed6 tradeOffset;
    Fixed6 tradeOffsetMaker;
    UFixed6 tradeOffsetMarket;
    Fixed6 adiabaticExposure;
    Fixed6 adiabaticExposureMaker;
    Fixed6 adiabaticExposureMarket;
    Fixed6 fundingMaker;
    Fixed6 fundingLong;
    Fixed6 fundingShort;
    UFixed6 fundingFee;
    Fixed6 interestMaker;
    Fixed6 interestLong;
    Fixed6 interestShort;
    UFixed6 interestFee;
    Fixed6 pnlMaker;
    Fixed6 pnlLong;
    Fixed6 pnlShort;
    UFixed6 settlementFee;
    UFixed6 liquidationFee;
}

struct CheckpointAccumulationResult {
    Fixed6 collateral;
    Fixed6 priceOverride;
    UFixed6 tradeFee;
    Fixed6 offset;
    UFixed6 settlementFee;
    UFixed6 liquidationFee;
    UFixed6 subtractiveFee;
    UFixed6 solverFee;
}

struct Position {
    Fixed6 size;
    Fixed6 entryPrice;
    Fixed6 accruedFunding;
    Fixed6 accruedFees;
}

struct Local {
    Fixed6 collateral;
}

struct Global {
    Fixed6 exposure;
}

interface IOracleProvider {
    function status() external view returns (OracleVersion memory, uint256);
    function at(uint256 timestamp) external view returns (OracleVersion memory);
}

interface IMarket {
    struct MarketDefinition {
        Token18 token;
        IOracleProvider oracle;
    }

    function oracle() external view returns (IOracleProvider);
    function global() external view returns (Global memory);
    function parameter() external view returns (MarketParameter memory);
    function riskParameter() external view returns (RiskParameter memory);
    function positions(address account) external view returns (Position memory);
    function locals(address account) external view returns (Local memory);

    function update(address account, uint256 maker, uint256 long, uint256 short, int256 collateral, bool protect)
        external;

    function claimFee() external;
    function claimFee(address receiver) external;
}

interface IPerennialV2MarketEvents {
    /// @notice Emitted when an account creates a new market order (and optional guarantee)
    /// @dev Includes liquidator (for protected updates) and any configured referrers
    event OrderCreated(
        address indexed account,
        Order order,
        Guarantee guarantee,
        address liquidator,
        address orderReferrer,
        address guaranteeReferrer
    );

    /// @notice Emitted when a global order is processed into a new oracle version
    /// @dev Includes the full global accumulation breakdown for the processed version
    event PositionProcessed(uint256 orderId, Order order, VersionAccumulationResult accumulationResult);

    /// @notice Emitted when an account's local position is processed for an order
    /// @dev Includes the per-account checkpoint collateral change and fee breakdown
    event AccountPositionProcessed(
        address indexed account, uint256 orderId, Order order, CheckpointAccumulationResult accumulationResult
    );

    /// @notice Emitted when the market owner updates the risk coordinator address
    event CoordinatorUpdated(address newCoordinator);

    /// @notice Emitted when accrued fees for an account are paid out to a receiver
    event FeeClaimed(address indexed account, address indexed receiver, UFixed6 amount);

    /// @notice Emitted when the market owner settles and resets the market exposure balance
    /// @dev Positive exposure is paid out from the market; negative exposure is paid into the market
    event ExposureClaimed(address indexed account, Fixed6 amount);

    /// @notice Emitted when the market owner updates the market parameter set
    event ParameterUpdated(MarketParameter newParameter);

    /// @notice Emitted when the risk coordinator updates the market risk parameter set
    event RiskParameterUpdated(RiskParameter newRiskParameter);
}

interface IPerennialV2MarketFactoryEvents {
    /// @notice Emitted when the factory owner updates protocol-wide parameters
    event ParameterUpdated(ProtocolParameter newParameter);

    /// @notice Emitted when an extension is enabled or disabled
    event ExtensionUpdated(address indexed operator, bool newEnabled);

    /// @notice Emitted when an account enables or disables an operator
    event OperatorUpdated(address indexed account, address indexed operator, bool newEnabled);

    /// @notice Emitted when an account enables or disables a signer for signature-based authorization
    event SignerUpdated(address indexed account, address indexed signer, bool newEnabled);

    /// @notice Emitted when the referral fee for a referrer is updated
    event ReferralFeeUpdated(address indexed referrer, UFixed6 newFee);

    /// @notice Emitted when a new market is created by the factory
    event MarketCreated(IMarket indexed market, IMarket.MarketDefinition definition);
}

interface IPerennialV2OracleProviderEvents {
    /// @notice Emitted when a market requests an oracle version
    /// @dev newPrice indicates whether a fresh price needs to be produced for the requested version
    event OracleProviderVersionRequested(uint256 indexed version, bool newPrice);

    /// @notice Emitted when an oracle version is fulfilled and becomes available for settlement
    event OracleProviderVersionFulfilled(OracleVersion version);
}

interface IPerennialV2OracleProviderFactoryEvents {
    /// @notice Emitted when a new oracle provider is created and registered under an id
    event OracleCreated(IOracleProvider indexed oracle, bytes32 indexed id);
}
