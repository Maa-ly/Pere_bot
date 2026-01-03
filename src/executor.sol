// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "lib/reactive-lib/src/abstract-base/AbstractCallback.sol";
import {IAaveFlashLoanSimpleReceiver, IAavePool} from "./interface/IAave.sol";
import {Fixed6, IMarket, Local, OracleVersion, Position, RiskParameter, UFixed6} from "./interface/events.sol";

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
    uint256 public rewardDiscountPpm;
    uint256 public minProfit;
    uint256 public flashLoanFeeBpsFallback;

    mapping(address => mapping(address => bool)) public isTracked;
    mapping(address => address[]) public trackedAccounts;
    mapping(address => uint256) public nextIndex;
    mapping(address => mapping(address => uint256)) public lastAccountEventId;
    mapping(address => uint256) public lastBatchEventId;

    event LiquidationCheck(
        address indexed market,
        address indexed account,
        bool liquidatable,
        uint256 maintenanceRequirement,
        int256 equity
    );
    event LiquidationExecuted(address indexed market, address indexed account, bool viaFlashLoan, uint256 reward);

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
        rewardDiscountPpm = 0;
        minProfit = 0;
        flashLoanFeeBpsFallback = 5;
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

    function setRewardDiscountPpm(uint256 newRewardDiscountPpm) external onlyOwner {
        rewardDiscountPpm = newRewardDiscountPpm;
    }

    function setMinProfit(uint256 newMinProfit) external onlyOwner {
        minProfit = newMinProfit;
    }

    function setFlashLoanFeeBpsFallback(uint256 newFlashLoanFeeBpsFallback) external onlyOwner {
        flashLoanFeeBpsFallback = newFlashLoanFeeBpsFallback;
    }

    function oraclePrice(IMarket market) public view returns (int256) {
        (OracleVersion memory latest,) = market.oracle().status();
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
        Position memory p = market.positions(account);
        Local memory l = market.locals(account);
        RiskParameter memory r = market.riskParameter();

        int256 price = oraclePrice(market);
        int256 size = Fixed6.unwrap(p.size);
        int256 entryPrice = Fixed6.unwrap(p.entryPrice);

        uint256 notional_ = notional(size, price);
        maintenanceRequirement =
            computeMaintenanceRequirement(notional_, UFixed6.unwrap(r.maintenance), UFixed6.unwrap(r.minMaintenance));
        equityValue = equity(
            Fixed6.unwrap(l.collateral),
            size,
            price,
            entryPrice,
            Fixed6.unwrap(p.accruedFunding),
            Fixed6.unwrap(p.accruedFees)
        );

        if (notional_ == 0) {
            liquidatable = false;
            reward = 0;
        } else {
            liquidatable = isLiquidatable(equityValue, maintenanceRequirement, liquidationBuffer);
            reward = liquidationReward(maintenanceRequirement, UFixed6.unwrap(r.liquidationFee));
        }
    }

    function profitable(uint256 reward, uint256 flashLoanFee) public view returns (bool) {
        uint256 discountedReward = (reward * (ONE_HUNDRED_PERCENT - rewardDiscountPpm)) / ONE_HUNDRED_PERCENT;
        uint256 cost = assumedGasCost + flashLoanFee + safetyMargin + minProfit;
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
        (bool liquidatable, uint256 maintReq, uint256 reward, int256 eq) = assess(IMarket(market), account);
        emit LiquidationCheck(market, account, liquidatable, maintReq, eq);
        if (!liquidatable) return;
        if (!profitable(reward, 0)) return;
        IMarket(market).update(account, 0, 0, 0, 0, true);
        try IMarket(market).claimFee(profitReceiver) {} catch {}
        emit LiquidationExecuted(market, account, false, reward);
    }

    function _hasPosition(address market, address account) internal view returns (bool) {
        Position memory p = IMarket(market).positions(account);
        return Fixed6.unwrap(p.size) != 0;
    }

    function trackAndCheck(address rvmId, address market, address account)
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
    {
        if (account != address(0) && !isTracked[market][account] && _hasPosition(market, account)) {
            isTracked[market][account] = true;
            trackedAccounts[market].push(account);
        }
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

        if (account != address(0) && !isTracked[market][account] && _hasPosition(market, account)) {
            isTracked[market][account] = true;
            trackedAccounts[market].push(account);
        }
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
        if (lastBatchEventId[market] == eventId) return;
        lastBatchEventId[market] = eventId;
        _processNextBatch(market, maxCount);
    }

    function _processNextBatch(address market, uint256 maxCount) internal {
        address[] storage accounts = trackedAccounts[market];
        uint256 i = nextIndex[market];
        uint256 end = i + maxCount;
        if (end > accounts.length) end = accounts.length;
        for (; i < end; i++) {
            _checkAndExecute(market, accounts[i]);
        }
        nextIndex[market] = i;
        if (i == accounts.length) nextIndex[market] = 0;
    }

    function checkAndExecuteWithFlashLoan(address rvmId, address market, address account, address asset, uint256 amount)
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
    {
        (bool liquidatable,, uint256 reward,) = assess(IMarket(market), account);
        if (!liquidatable) return;
        uint256 estimatedFlashFee = (amount * _flashLoanPremiumTotalBps()) / BPS_DIVISOR;
        if (!profitable(reward, estimatedFlashFee)) return;

        aavePool.flashLoanSimple(address(this), asset, amount, abi.encode(market, account, reward), 0);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        if (msg.sender != address(aavePool)) revert NotAavePool();
        if (initiator != address(this)) revert UnexpectedInitiator();

        (address market, address account, uint256 reward) = abi.decode(params, (address, address, uint256));
        IMarket(market).update(account, 0, 0, 0, 0, true);
        try IMarket(market).claimFee(address(this)) {} catch {}

        uint256 repayAmount = amount + premium;
        uint256 balance = _balanceOf(asset, address(this));
        if (balance < repayAmount) revert InsufficientRepayBalance();

        _approve(asset, address(aavePool), repayAmount);

        uint256 surplus = balance - repayAmount;
        if (surplus < minProfit) revert InsufficientProfit();
        if (surplus != 0) _transfer(asset, profitReceiver, surplus);
        emit LiquidationExecuted(market, account, true, reward);
        return true;
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
