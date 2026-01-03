// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "lib/reactive-lib/src/abstract-base/AbstractCallback.sol";
import {IAaveFlashLoanSimpleReceiver, IAavePool} from "./interface/IAave.sol";
import {Fixed6, IMarket, Local, OracleVersion, Order, Position, RiskParameter, UFixed6} from "./interface/events.sol";

contract Executor is AbstractCallback, IAaveFlashLoanSimpleReceiver {
    uint256 internal constant SCALE = 1e6;
    uint256 internal constant ONE_HUNDRED_PERCENT = 1e6;
    int256 internal constant SCALE_INT = 1e6;
    uint256 internal constant BPS_DIVISOR = 10_000;

    address public owner;
    address public profitReceiver;
    IAavePool public aavePool;

    uint256 public liquidationBuffer;
    uint256 public safetyMargin;
    uint256 public assumedGasCost;
    uint256 public gasEstimateForLiquidation;
    uint256 public gasWeiPerAssetUnit;
    address public arbGasInfo;
    address public opGasPriceOracle;
    bool public useDynamicGasCost;
    uint256 public rewardDiscountPpm;
    uint256 public minProfit;
    uint256 public flashLoanFeeBpsFallback;
    uint256 public makerLiquidationBuffer;
    uint256 public minMakerSize;
    uint256 public makerRewardDiscountPpm;
    uint256 public insolvencyThresholdMultiplier;

    mapping(address => mapping(address => bool)) public isTracked;
    mapping(address => address[]) public trackedAccounts;
    mapping(address => mapping(address => uint256)) public accountIndex;
    mapping(address => uint256) public nextIndex;
    mapping(address => mapping(address => uint256)) public lastAccountEventId;
    mapping(address => uint256) public lastBatchEventId;
    mapping(address => bool) public batchInProgress;

    function trackedAccountsLength(address market) external view returns (uint256) {
        return trackedAccounts[market].length;
    }

    struct Factors {
        bool liquidatable;
        bool oracleValid;
        bool oracleStale;
        uint256 oracleTimestamp;
        int256 price;
        int256 size;
        int256 entryPrice;
        uint256 notional;
        int256 pnlValue;
        int256 collateral;
        int256 fundingAccrued;
        int256 feesAccrued;
        int256 equityValue;
        uint256 maintenanceRatio;
        uint256 minMaintenance;
        uint256 maintenanceRequirement;
        uint256 liquidationBufferPpm;
        uint256 bufferedMaintenance;
        int256 cushion;
        uint256 liquidationFeeRatio;
        uint256 reward;
        bool isInsolvent;
    }

    event RealizedPayout(address indexed market, address indexed account, address indexed asset, uint256 amount);

    event LiquidationCheck(
        address indexed market,
        address indexed account,
        bool liquidatable,
        uint256 maintenanceRequirement,
        int256 equity
    );
    event LiquidationExecuted(address indexed market, address indexed account, bool viaFlashLoan, uint256 reward);
    event LowProfitExecution(address indexed market, address indexed account, uint256 gained, uint256 cost);
    event PositionFactors(address indexed market, address indexed account, bytes data);

    error NotOwner();
    error InvalidAddress();
    error UnsupportedCallbackSender();
    error NotAavePool();
    error UnexpectedInitiator();
    error ApproveFailed();
    error TransferFailed();
    error BalanceQueryFailed();
    error InsufficientRepayBalance();
    error InsufficientProfit();

    constructor(address callbackSender, address aavePool_, address profitReceiver_) AbstractCallback(callbackSender) {
        if (callbackSender == address(0) || aavePool_ == address(0) || profitReceiver_ == address(0)) {
            revert InvalidAddress();
        }
        rvm_id = address(0);
        owner = msg.sender;
        profitReceiver = profitReceiver_;
        aavePool = IAavePool(aavePool_);
        liquidationBuffer = 1_020_000;
        safetyMargin = 0;
        assumedGasCost = 0;
        gasEstimateForLiquidation = 0;
        gasWeiPerAssetUnit = 0;
        arbGasInfo = address(0);
        opGasPriceOracle = address(0);
        useDynamicGasCost = true;
        rewardDiscountPpm = 0;
        minProfit = 0;
        flashLoanFeeBpsFallback = 5;
        makerLiquidationBuffer = 1_150_000;
        minMakerSize = 0;
        makerRewardDiscountPpm = 200_000;
        insolvencyThresholdMultiplier = 2_000_000;
    }

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    function setProfitReceiver(address newProfitReceiver) external onlyOwner {
        if (newProfitReceiver == address(0)) revert InvalidAddress();
        profitReceiver = newProfitReceiver;
    }

    function setLiquidationBuffer(uint256 newBuffer) external onlyOwner {
        liquidationBuffer = newBuffer;
    }

    function setSafetyMargin(uint256 newSafetyMargin) external onlyOwner {
        safetyMargin = newSafetyMargin;
    }

    function setAssumedGasCost(uint256 newAssumedGasCost) external onlyOwner {
        assumedGasCost = newAssumedGasCost;
    }

    function setGasEstimateForLiquidation(uint256 newGasEstimateForLiquidation) external onlyOwner {
        gasEstimateForLiquidation = newGasEstimateForLiquidation;
    }

    function setGasWeiPerAssetUnit(uint256 newGasWeiPerAssetUnit) external onlyOwner {
        gasWeiPerAssetUnit = newGasWeiPerAssetUnit;
    }

    function setArbGasInfo(address newArbGasInfo) external onlyOwner {
        arbGasInfo = newArbGasInfo;
    }

    function setOpGasPriceOracle(address newOpGasPriceOracle) external onlyOwner {
        opGasPriceOracle = newOpGasPriceOracle;
    }

    function setUseDynamicGasCost(bool newUseDynamicGasCost) external onlyOwner {
        useDynamicGasCost = newUseDynamicGasCost;
    }

    function setRewardDiscountPpm(uint256 newRewardDiscountPpm) external onlyOwner {
        rewardDiscountPpm = newRewardDiscountPpm;
    }

    function setMinProfit(uint256 newMinProfit) external onlyOwner {
        minProfit = newMinProfit;
    }

    function setFlashLoanFeeBpsFallback(uint256 newFlashLoanFeeBpsFallback) external onlyOwner {
        flashLoanFeeBpsFallback = newFlashLoanFeeBpsFallback;
    }

    function setMakerLiquidationBuffer(uint256 newMakerLiquidationBuffer) external onlyOwner {
        makerLiquidationBuffer = newMakerLiquidationBuffer;
    }

    function setMinMakerSize(uint256 newMinMakerSize) external onlyOwner {
        minMakerSize = newMinMakerSize;
    }

    function setMakerRewardDiscountPpm(uint256 newMakerRewardDiscountPpm) external onlyOwner {
        makerRewardDiscountPpm = newMakerRewardDiscountPpm;
    }

    function setInsolvencyThresholdMultiplier(uint256 newInsolvencyThresholdMultiplier) external onlyOwner {
        insolvencyThresholdMultiplier = newInsolvencyThresholdMultiplier;
    }

    function oraclePrice(IMarket market) public view returns (int256) {
        (OracleVersion memory latest,) = market.oracle().status();
        require(latest.valid, "Invalid oracle price");
        require(latest.timestamp <= block.timestamp, "Oracle future");
        RiskParameter memory r = market.riskParameter();
        if (r.staleAfter != 0) require(block.timestamp - latest.timestamp <= r.staleAfter, "Stale oracle");
        return Fixed6.unwrap(latest.price);
    }

    function notional(int256 positionSize, int256 price) public pure returns (uint256) {
        uint256 absSize = _abs(positionSize);
        uint256 absPrice = _abs(price);
        return (absSize * absPrice) / SCALE;
    }

    function pnl(int256 positionSize, int256 price, int256 entryPrice) public pure returns (int256) {
        return (positionSize * (price - entryPrice)) / SCALE_INT;
    }

    function equity(
        int256 collateral,
        int256 positionSize,
        int256 price,
        int256 entryPrice,
        int256 fundingAccrued,
        int256 feesAccrued
    ) public pure returns (int256) {
        return collateral + pnl(positionSize, price, entryPrice) - fundingAccrued - feesAccrued;
    }

    function maintenance(uint256 notional_, uint256 maintenanceRatio) public pure returns (uint256) {
        return (notional_ * maintenanceRatio) / ONE_HUNDRED_PERCENT;
    }

    function computeMaintenanceRequirement(uint256 notional_, uint256 maintenanceRatio, uint256 minMaintenance)
        public
        pure
        returns (uint256)
    {
        if (notional_ == 0) return 0;
        uint256 req = (notional_ * maintenanceRatio) / ONE_HUNDRED_PERCENT;
        return req < minMaintenance ? minMaintenance : req;
    }

    function liquidationReward(uint256 maintenance_, uint256 liquidationFeeRatio) public pure returns (uint256) {
        return (maintenance_ * liquidationFeeRatio) / ONE_HUNDRED_PERCENT;
    }

    function factors(IMarket market, address account) external view returns (bytes memory) {
        Factors memory f = _factorsStruct(market, account);
        return abi.encode(f);
    }

    function _factorsStruct(IMarket market, address account) internal view returns (Factors memory f) {
        Position memory p = market.positions(account);
        Local memory l = market.locals(account);
        RiskParameter memory r = market.riskParameter();
        uint256 makerSize = _makerSize(market, account);
        bool isMaker = makerSize != 0 && makerSize >= minMakerSize;

        (OracleVersion memory latest,) = market.oracle().status();
        f.oracleValid = latest.valid;
        f.oracleTimestamp = latest.timestamp;
        if (latest.timestamp > block.timestamp) {
            f.oracleStale = true;
        } else if (r.staleAfter != 0 && block.timestamp - latest.timestamp > r.staleAfter) {
            f.oracleStale = true;
        }
        f.price = Fixed6.unwrap(latest.price);
        f.size = Fixed6.unwrap(p.size);
        f.entryPrice = Fixed6.unwrap(p.entryPrice);
        f.collateral = Fixed6.unwrap(l.collateral);
        f.fundingAccrued = Fixed6.unwrap(p.accruedFunding);
        f.feesAccrued = Fixed6.unwrap(p.accruedFees);

        f.notional = notional(f.size, f.price);
        f.pnlValue = pnl(f.size, f.price, f.entryPrice);
        f.equityValue = f.collateral + f.pnlValue - f.fundingAccrued - f.feesAccrued;

        f.maintenanceRatio = UFixed6.unwrap(r.maintenance);
        f.minMaintenance = UFixed6.unwrap(r.minMaintenance);
        f.maintenanceRequirement = computeMaintenanceRequirement(f.notional, f.maintenanceRatio, f.minMaintenance);

        f.liquidationBufferPpm = isMaker ? makerLiquidationBuffer : liquidationBuffer;
        f.bufferedMaintenance = (f.maintenanceRequirement * f.liquidationBufferPpm) / ONE_HUNDRED_PERCENT;
        if (f.bufferedMaintenance > uint256(type(int256).max)) {
            f.cushion = type(int256).min;
        } else {
            f.cushion = f.equityValue - int256(f.bufferedMaintenance);
        }

        f.liquidationFeeRatio = UFixed6.unwrap(r.liquidationFee);

        if (!f.oracleValid || f.oracleStale) {
            f.liquidatable = false;
            f.reward = 0;
            f.bufferedMaintenance = 0;
            f.cushion = type(int256).max;
            return f;
        }

        if (f.notional == 0) {
            f.liquidatable = false;
            f.reward = 0;
            f.bufferedMaintenance = 0;
            f.cushion = f.equityValue;
        } else {
            f.liquidatable = isLiquidatable(f.equityValue, f.maintenanceRequirement, f.liquidationBufferPpm);
            f.reward = liquidationReward(f.maintenanceRequirement, f.liquidationFeeRatio);
            if (isMaker && makerRewardDiscountPpm != 0) {
                f.reward = (f.reward * (ONE_HUNDRED_PERCENT - makerRewardDiscountPpm)) / ONE_HUNDRED_PERCENT;
            }
        }

        if (f.notional != 0 && insolvencyThresholdMultiplier != 0) {
            uint256 threshold = (f.maintenanceRequirement * insolvencyThresholdMultiplier) / ONE_HUNDRED_PERCENT;
            if (threshold > uint256(type(int256).max)) {
                f.isInsolvent = true;
            } else {
                if (f.equityValue == type(int256).min) {
                    f.isInsolvent = true;
                } else if (f.equityValue < 0) {
                    f.isInsolvent = uint256(-f.equityValue) > threshold;
                } else {
                    f.isInsolvent = false;
                }
            }
            if (f.isInsolvent) {
                f.liquidatable = false;
                f.reward = 0;
            }
        }
    }

    function isLiquidatable(int256 equity_, uint256 maintenance_, uint256 buffer) public pure returns (bool) {
        uint256 bufferedMaintenance = (maintenance_ * buffer) / ONE_HUNDRED_PERCENT;
        if (bufferedMaintenance > uint256(type(int256).max)) return true;
        int256 bufferedMaintenanceInt;
        assembly {
            bufferedMaintenanceInt := bufferedMaintenance
        }
        return equity_ < bufferedMaintenanceInt;
    }

    function assess(IMarket market, address account)
        public
        view
        returns (bool liquidatable, uint256 maintenanceRequirement, uint256 reward, int256 equityValue)
    {
        Factors memory f = _factorsStruct(market, account);
        maintenanceRequirement = f.notional == 0 ? 0 : f.maintenanceRequirement;
        return (f.liquidatable, maintenanceRequirement, f.reward, f.equityValue);
    }

    function estimateGasCost() public view returns (uint256) {
        if (gasEstimateForLiquidation == 0) return 0;
        if (gasWeiPerAssetUnit == 0) return 0;
        uint256 totalWei = tx.gasprice * gasEstimateForLiquidation;
        if (arbGasInfo != address(0)) {
            (bool ok, bytes memory ret) = arbGasInfo.staticcall(abi.encodeWithSignature("getPricesInWei()"));
            if (ok && ret.length >= 32 * 6) {
                (uint256 perL2Tx,,,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256));
                totalWei += perL2Tx;
            }
        }
        if (opGasPriceOracle != address(0)) {
            bytes memory estimatedCalldata = new bytes(500);
            (bool ok, bytes memory ret) =
                opGasPriceOracle.staticcall(abi.encodeWithSignature("getL1Fee(bytes)", estimatedCalldata));
            if (ok && ret.length >= 32) {
                totalWei += abi.decode(ret, (uint256));
            }
        }
        return totalWei / gasWeiPerAssetUnit;
    }

    function gasCost() public view returns (uint256) {
        if (useDynamicGasCost) {
            uint256 dynamicGasCost = estimateGasCost();
            if (dynamicGasCost != 0) return dynamicGasCost;
        }
        return assumedGasCost;
    }

    function profitable(uint256 reward, uint256 flashLoanFee) public view returns (bool) {
        uint256 discountedReward = (reward * (ONE_HUNDRED_PERCENT - rewardDiscountPpm)) / ONE_HUNDRED_PERCENT;
        uint256 cost = gasCost() + flashLoanFee + safetyMargin + minProfit;
        return discountedReward > cost;
    }

    function checkAndExecute(address rvmId, address market, address account)
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
    {
        _checkAndExecute(market, account);
    }

    function _checkAndExecute(address market, address account) internal {
        Factors memory f = _factorsStruct(IMarket(market), account);
        emit LiquidationCheck(market, account, f.liquidatable, f.maintenanceRequirement, f.equityValue);
        emit PositionFactors(market, account, abi.encode(f));
        if (!f.liquidatable) return;
        if (!profitable(f.reward, 0)) return;
        address asset = _marketToken(market);
        uint256 balanceBefore = asset == address(0) ? 0 : _balanceOf(asset, address(this));
        IMarket(market).update(account, 0, 0, 0, 0, true);
        try IMarket(market).claimFee(address(this)) {} catch {}
        if (asset != address(0)) {
            uint256 balanceAfter = _balanceOf(asset, address(this));
            uint256 gained = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
            uint256 cost = gasCost() + safetyMargin + minProfit;
            if (gained < cost) {
                emit LowProfitExecution(market, account, gained, cost);
            }
            if (gained != 0) {
                _transfer(asset, profitReceiver, gained);
                emit RealizedPayout(market, account, asset, gained);
            }
        }
        emit LiquidationExecuted(market, account, false, f.reward);
    }

    function _hasPosition(address market, address account) internal view returns (bool) {
        Position memory p = IMarket(market).positions(account);
        return Fixed6.unwrap(p.size) != 0;
    }

    function _trackAccount(address market, address account) internal {
        if (account == address(0)) return;
        if (isTracked[market][account]) return;
        if (!_hasPosition(market, account)) return;
        isTracked[market][account] = true;
        accountIndex[market][account] = trackedAccounts[market].length + 1;
        trackedAccounts[market].push(account);
    }

    function _untrackAtIndex(address market, uint256 index) internal {
        address[] storage accounts = trackedAccounts[market];
        address removed = accounts[index];
        uint256 lastIndex = accounts.length - 1;
        if (index != lastIndex) {
            address last = accounts[lastIndex];
            accounts[index] = last;
            accountIndex[market][last] = index + 1;
        }
        accounts.pop();
        delete accountIndex[market][removed];
        isTracked[market][removed] = false;
    }

    function trackAndCheck(address rvmId, address market, address account)
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
    {
        _trackAccount(market, account);
        _checkAndExecute(market, account);
    }

    function trackAndCheckEvent(
        address rvmId,
        address market,
        address account,
        uint256 originChainId,
        uint256 originBlockNumber,
        uint256 originTxHash,
        uint256 originLogIndex,
        uint256 originTopic0
    ) external authorizedSenderOnly rvmIdOnly(rvmId) {
        uint256 eventId = uint256(
            keccak256(abi.encode(originChainId, originBlockNumber, originTxHash, originLogIndex, originTopic0))
        );
        if (lastAccountEventId[market][account] == eventId) return;
        lastAccountEventId[market][account] = eventId;

        _trackAccount(market, account);
        _checkAndExecute(market, account);
    }

    function processNextBatch(address rvmId, address market, uint256 maxCount)
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
    {
        _processNextBatch(market, maxCount);
    }

    function processNextBatchEvent(
        address rvmId,
        address market,
        uint256 maxCount,
        uint256 originChainId,
        uint256 originBlockNumber,
        uint256 originTxHash,
        uint256 originLogIndex,
        uint256 originTopic0
    ) external authorizedSenderOnly rvmIdOnly(rvmId) {
        uint256 eventId = uint256(
            keccak256(abi.encode(originChainId, originBlockNumber, originTxHash, originLogIndex, originTopic0))
        );
        if (lastBatchEventId[market] != eventId) {
            lastBatchEventId[market] = eventId;
            batchInProgress[market] = true;
            nextIndex[market] = 0;
        } else {
            if (!batchInProgress[market]) return;
        }
        _processNextBatch(market, maxCount);
        if (nextIndex[market] == 0) batchInProgress[market] = false;
    }

    function _processNextBatch(address market, uint256 maxCount) internal {
        address[] storage accounts = trackedAccounts[market];
        uint256 i = nextIndex[market];
        uint256 processed = 0;
        while (processed < maxCount && i < accounts.length) {
            address account = accounts[i];
            if (!_hasPosition(market, account)) {
                _untrackAtIndex(market, i);
                continue;
            }
            _checkAndExecute(market, account);
            processed++;
            i++;
        }

        if (accounts.length == 0) {
            nextIndex[market] = 0;
        } else {
            nextIndex[market] = i >= accounts.length ? 0 : i;
        }
    }

    function cleanup(address market, uint256 maxRemovals) external onlyOwner {
        address[] storage accounts = trackedAccounts[market];
        uint256 i = 0;
        uint256 removed = 0;
        while (i < accounts.length && removed < maxRemovals) {
            if (!_hasPosition(market, accounts[i])) {
                _untrackAtIndex(market, i);
                removed++;
                continue;
            }
            i++;
        }
        nextIndex[market] = 0;
    }

    function checkAndExecuteWithFlashLoan(address rvmId, address market, address account, address asset, uint256 amount)
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
    {
        Factors memory f = _factorsStruct(IMarket(market), account);
        emit LiquidationCheck(market, account, f.liquidatable, f.maintenanceRequirement, f.equityValue);
        emit PositionFactors(market, account, abi.encode(f));
        if (!f.liquidatable) return;
        uint256 estimatedFlashFee = (amount * _flashLoanPremiumTotalBps()) / BPS_DIVISOR;
        if (!profitable(f.reward, estimatedFlashFee)) return;

        aavePool.flashLoanSimple(address(this), asset, amount, abi.encode(market, account, f.reward), 0);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        if (msg.sender != address(aavePool)) revert NotAavePool();
        if (initiator != address(this)) revert UnexpectedInitiator();

        (address market, address account,) = abi.decode(params, (address, address, uint256));
        uint256 profit = _executeFlashLiquidation(market, account, asset, amount, premium);
        emit LiquidationExecuted(market, account, true, profit);
        return true;
    }

    function _executeFlashLiquidation(address market, address account, address asset, uint256 amount, uint256 premium)
        internal
        returns (uint256 profit)
    {
        uint256 balanceBefore = _balanceOf(asset, address(this));
        IMarket(market).update(account, 0, 0, 0, 0, true);
        try IMarket(market).claimFee(address(this)) {} catch {}
        uint256 balanceAfter = _balanceOf(asset, address(this));

        uint256 repayAmount = amount + premium;
        if (balanceAfter < repayAmount) revert InsufficientRepayBalance();
        _approve(asset, address(aavePool), repayAmount);

        if (balanceAfter > balanceBefore && balanceAfter - balanceBefore > premium) {
            profit = (balanceAfter - balanceBefore) - premium;
        }

        uint256 cost = gasCost() + safetyMargin + minProfit;
        if (profit < cost) revert InsufficientProfit();
        if (profit != 0) _transfer(asset, profitReceiver, profit);
    }

    function _makerSize(IMarket market, address account) internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(market).staticcall(abi.encodeWithSignature("orders(address)", account));
        if (!ok) return 0;
        if (ret.length < 32 * 13) return 0;
        Order memory o = abi.decode(ret, (Order));
        return UFixed6.unwrap(o.makerPos) + UFixed6.unwrap(o.makerNeg);
    }

    function _marketToken(address market) internal view returns (address) {
        (bool ok, bytes memory ret) = market.staticcall(abi.encodeWithSignature("token()"));
        if (ok && ret.length >= 32) return abi.decode(ret, (address));

        (ok, ret) = market.staticcall(abi.encodeWithSignature("definition()"));
        if (ok && ret.length >= 64) {
            (address token,) = abi.decode(ret, (address, address));
            return token;
        }

        return address(0);
    }

    function claimToProfitReceiver(address market) external onlyOwner {
        IMarket(market).claimFee(profitReceiver);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        uint256 y;
        assembly {
            y := x
            if slt(x, 0) { y := sub(0, x) }
        }
        return y;
    }

    function _approve(address asset, address spender, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            asset.call(abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), spender, amount));
        if (!ok) revert ApproveFailed();
        if (ret.length != 0 && !abi.decode(ret, (bool))) revert ApproveFailed();
    }

    function _transfer(address asset, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            asset.call(abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to, amount));
        if (!ok) revert TransferFailed();
        if (ret.length != 0 && !abi.decode(ret, (bool))) revert TransferFailed();
    }

    function _balanceOf(address asset, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            asset.staticcall(abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), who));
        if (!ok) revert BalanceQueryFailed();
        if (ret.length == 0) return 0;
        if (ret.length < 32) revert BalanceQueryFailed();
        return abi.decode(ret, (uint256));
    }

    function _flashLoanPremiumTotalBps() internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(aavePool).staticcall(abi.encodeWithSignature("FLASHLOAN_PREMIUM_TOTAL()"));
        if (!ok || ret.length < 32) return flashLoanFeeBpsFallback;
        return uint256(abi.decode(ret, (uint128)));
    }
}
