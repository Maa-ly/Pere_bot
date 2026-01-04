// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Executor} from "../src/executor.sol";
import {Sentinal} from "../src/reactive/sentinal.sol";
import {IReactive} from "lib/reactive-lib/src/interfaces/IReactive.sol";
import {IAaveFlashLoanSimpleReceiver} from "../src/interface/IAave.sol";
import {
    Fixed6,
    Global,
    IMarket,
    IOracleProvider,
    Local,
    MarketParameter,
    Order,
    OracleVersion,
    Position,
    RiskParameter,
    UFixed6
} from "../src/interface/events.sol";

contract MockOracle is IOracleProvider {
    OracleVersion internal _latest;
    uint256 internal _currentTimestamp;

    function setStatus(OracleVersion memory latest, uint256 currentTimestamp_) external {
        _latest = latest;
        _currentTimestamp = currentTimestamp_;
    }

    function status() external view returns (OracleVersion memory, uint256) {
        return (_latest, _currentTimestamp);
    }

    function at(uint256) external view returns (OracleVersion memory) {
        return _latest;
    }
}

contract MockOpGasPriceOracle {
    uint256 public l1Fee;

    constructor(uint256 l1Fee_) {
        l1Fee = l1Fee_;
    }

    function getL1Fee(bytes calldata) external view returns (uint256) {
        return l1Fee;
    }
}

contract MockMarket is IMarket {
    MockOracle public mockOracle;
    MarketParameter internal _parameter;
    RiskParameter internal _riskParameter;
    mapping(address => Position) internal _positions;
    mapping(address => Local) internal _locals;
    mapping(address => Order) internal _orders;
    Global internal _global;

    address public lastUpdateAccount;
    bool public lastUpdateProtect;

    constructor(MockOracle oracle_) {
        mockOracle = oracle_;
    }

    function setMarketParameter(MarketParameter memory p) external {
        _parameter = p;
    }

    function setRiskParameter(RiskParameter memory r) external {
        _riskParameter = r;
    }

    function setPosition(address account, Position memory p) external {
        _positions[account] = p;
    }

    function setLocal(address account, Local memory l) external {
        _locals[account] = l;
    }

    function setOrder(address account, Order memory o) external {
        _orders[account] = o;
    }

    function oracle() external view returns (IOracleProvider) {
        return mockOracle;
    }

    function global() external view returns (Global memory) {
        return _global;
    }

    function parameter() external view returns (MarketParameter memory) {
        return _parameter;
    }

    function riskParameter() external view returns (RiskParameter memory) {
        return _riskParameter;
    }

    function positions(address account) external view returns (Position memory) {
        return _positions[account];
    }

    function locals(address account) external view returns (Local memory) {
        return _locals[account];
    }

    function orders(address account) external view returns (Order memory) {
        return _orders[account];
    }

    function update(address account, uint256, uint256, uint256, int256, bool protect) external {
        lastUpdateAccount = account;
        lastUpdateProtect = protect;
    }

    function claimFee() external {}
    function claimFee(address) external {}
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockAavePool {
    uint256 public premium;
    uint128 public premiumTotal;
    uint128 public premiumToProtocol;

    constructor(uint256 premium_) {
        premium = premium_;
        premiumTotal = 5;
        premiumToProtocol = 0;
    }

    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16)
        external
    {
        require(MockERC20(asset).transfer(receiverAddress, amount));
        IAaveFlashLoanSimpleReceiver(receiverAddress).executeOperation(asset, amount, premium, msg.sender, params);
        require(MockERC20(asset).transferFrom(receiverAddress, address(this), amount + premium));
    }

    function getReserveNormalizedIncome(address) external pure returns (uint256) {
        return 0;
    }

    function getReserveNormalizedVariableDebt(address) external pure returns (uint256) {
        return 0;
    }

    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128) {
        return premiumTotal;
    }

    function FLASHLOAN_PREMIUM_TO_PROTOCOL() external view returns (uint128) {
        return premiumToProtocol;
    }
}

contract MockMarketWithFee is IMarket {
    MockOracle public mockOracle;
    MockERC20 public token;
    RiskParameter internal _riskParameter;
    mapping(address => Position) internal _positions;
    mapping(address => Local) internal _locals;
    mapping(address => Order) internal _orders;

    uint256 public feeAmount;

    address public lastUpdateAccount;
    bool public lastUpdateProtect;

    constructor(MockOracle oracle_, MockERC20 token_) {
        mockOracle = oracle_;
        token = token_;
    }

    function setRiskParameter(RiskParameter memory r) external {
        _riskParameter = r;
    }

    function setPosition(address account, Position memory p) external {
        _positions[account] = p;
    }

    function setLocal(address account, Local memory l) external {
        _locals[account] = l;
    }

    function setOrder(address account, Order memory o) external {
        _orders[account] = o;
    }

    function setFeeAmount(uint256 feeAmount_) external {
        feeAmount = feeAmount_;
    }

    function oracle() external view returns (IOracleProvider) {
        return mockOracle;
    }

    function global() external pure returns (Global memory) {
        return Global(Fixed6.wrap(0));
    }

    function parameter() external pure returns (MarketParameter memory) {
        return MarketParameter(
            UFixed6.wrap(0),
            UFixed6.wrap(0),
            UFixed6.wrap(0),
            UFixed6.wrap(0),
            UFixed6.wrap(0),
            0,
            0,
            UFixed6.wrap(0),
            false,
            false
        );
    }

    function riskParameter() external view returns (RiskParameter memory) {
        return _riskParameter;
    }

    function positions(address account) external view returns (Position memory) {
        return _positions[account];
    }

    function locals(address account) external view returns (Local memory) {
        return _locals[account];
    }

    function orders(address account) external view returns (Order memory) {
        return _orders[account];
    }

    function update(address account, uint256, uint256, uint256, int256, bool protect) external {
        lastUpdateAccount = account;
        lastUpdateProtect = protect;
    }

    function claimFee() external {
        claimFee(msg.sender);
    }

    function claimFee(address receiver) public {
        uint256 amount = feeAmount;
        feeAmount = 0;
        require(token.transfer(receiver, amount));
    }
}

contract BotTest is Test {
    event RealizedPayout(address indexed market, address indexed account, address indexed asset, uint256 amount);
    event LowProfitExecution(address indexed market, address indexed account, uint256 gained, uint256 cost);

    function _emitStorkUpdate(Executor executor, bytes32 assetId, int192 quantizedValue) internal {
        executor.storkValueUpdateEvent(
            address(this),
            assetId,
            uint64(123),
            quantizedValue,
            10,
            1,
            7,
            9,
            11,
            uint256(keccak256("ValueUpdate(bytes32,uint64,int192)"))
        );
    }

    function _storkCallbackPayload(bytes32 assetId, uint256 batchSize, IReactive.LogRecord memory log)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "storkValueUpdateEvent(address,bytes32,uint64,int192,uint256,uint256,uint256,uint256,uint256,uint256)",
            address(0),
            assetId,
            uint64(123),
            int192(2_000_000),
            batchSize,
            log.chain_id,
            log.block_number,
            log.tx_hash,
            log.log_index,
            log.topic_0
        );
    }

    function test_dynamic_gas_cost_calculation() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        executor.setGasEstimateForLiquidation(300_000);
        executor.setGasWeiPerAssetUnit(1);
        vm.txGasPrice(10 gwei);
        assertEq(executor.estimateGasCost(), 300_000 * 10 gwei);
    }

    function test_op_stack_l1_fee_is_included_in_gas_cost() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        MockOpGasPriceOracle oracle = new MockOpGasPriceOracle(1000);
        executor.setOpGasPriceOracle(address(oracle));
        executor.setGasEstimateForLiquidation(10);
        executor.setGasWeiPerAssetUnit(1);
        vm.txGasPrice(2);
        assertEq(executor.estimateGasCost(), 2 * 10 + 1000);
    }

    function test_insolvent_positions_are_skipped() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        executor.setInsolvencyThresholdMultiplier(2_000_000);

        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);
        address account = address(0xA11CE);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(100_000);
        r.minMaintenance = UFixed6.wrap(0);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = block.timestamp;
        oracle.setStatus(v, block.timestamp);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(2_000_000));
        market.setPosition(account, p);

        Local memory l;
        l.collateral = Fixed6.wrap(-int256(500_000));
        market.setLocal(account, l);

        (bool liquidatable,, uint256 reward,) = executor.assess(IMarket(address(market)), account);
        assertEq(liquidatable, false);
        assertEq(reward, 0);
    }

    function test_maker_buffer_and_reward_discount_applied() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        executor.setLiquidationBuffer(1_020_000);
        executor.setMakerLiquidationBuffer(1_150_000);
        executor.setMinMakerSize(0);
        executor.setMakerRewardDiscountPpm(200_000);

        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);
        address account = address(0xA11CE);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(100_000);
        r.minMaintenance = UFixed6.wrap(0);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = block.timestamp;
        oracle.setStatus(v, block.timestamp);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(2_000_000));
        market.setPosition(account, p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(220_000));
        market.setLocal(account, l);

        (bool takerLiquidatable,, uint256 takerReward,) = executor.assess(IMarket(address(market)), account);
        assertEq(takerLiquidatable, false);
        assertEq(takerReward, 10_000);

        Order memory o;
        o.makerPos = UFixed6.wrap(1);
        market.setOrder(account, o);

        (bool makerLiquidatable,, uint256 makerReward,) = executor.assess(IMarket(address(market)), account);
        assertEq(makerLiquidatable, true);
        assertEq(makerReward, 8_000);
    }

    function test_batch_continuation_completes_for_single_event() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(10_000);
        r.minMaintenance = UFixed6.wrap(0);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = block.timestamp;
        oracle.setStatus(v, block.timestamp);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(2_000_000));

        Local memory l;
        l.collateral = Fixed6.wrap(int256(10_000_000));

        address a1 = address(0xA11CE);
        address a2 = address(0xB0B);
        address a3 = address(0xCAFECAFE);

        market.setPosition(a1, p);
        market.setLocal(a1, l);
        executor.trackAndCheck(address(0), address(market), a1);

        market.setPosition(a2, p);
        market.setLocal(a2, l);
        executor.trackAndCheck(address(0), address(market), a2);

        market.setPosition(a3, p);
        market.setLocal(a3, l);
        executor.trackAndCheck(address(0), address(market), a3);

        executor.processNextBatchEvent(address(0), address(market), 2, 1, 7, 9, 11, 123);
        assertEq(executor.batchInProgress(address(market)), true);
        assertEq(executor.nextIndex(address(market)), 2);

        executor.processNextBatchEvent(address(0), address(market), 2, 1, 7, 9, 11, 123);
        assertEq(executor.batchInProgress(address(market)), false);
        assertEq(executor.nextIndex(address(market)), 0);
    }

    function test_batch_processing_removes_closed_positions() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);
        address account = address(0xA11CE);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(10_000);
        r.minMaintenance = UFixed6.wrap(0);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = block.timestamp;
        oracle.setStatus(v, block.timestamp);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(2_000_000));
        market.setPosition(account, p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(10_000_000));
        market.setLocal(account, l);

        executor.trackAndCheck(address(0), address(market), account);
        assertEq(executor.isTracked(address(market), account), true);

        p.size = Fixed6.wrap(int256(0));
        market.setPosition(account, p);

        executor.processNextBatchEvent(address(0), address(market), 10, 1, 7, 9, 11, 123);
        assertEq(executor.isTracked(address(market), account), false);
        assertEq(executor.trackedAccountsLength(address(market)), 0);
    }

    function test_executor_math_and_liquidation_check() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        executor.setInsolvencyThresholdMultiplier(0);
        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);
        address account = address(0xA11CE);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(10_000);
        r.minMaintenance = UFixed6.wrap(0);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = 1;
        oracle.setStatus(v, 1);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(3_000_000));
        p.accruedFunding = Fixed6.wrap(int256(0));
        p.accruedFees = Fixed6.wrap(int256(0));
        market.setPosition(account, p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));
        market.setLocal(account, l);

        (bool liquidatable, uint256 maint, uint256 reward, int256 eq) = executor.assess(market, account);
        assertTrue(liquidatable);
        assertEq(maint, 20_000);
        assertEq(reward, 1_000);
        assertEq(eq, -1_000_000);
    }

    function test_oracle_invalid_disables_liquidation() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);
        address account = address(0xA11CE);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(10_000);
        r.minMaintenance = UFixed6.wrap(0);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = false;
        v.timestamp = block.timestamp;
        oracle.setStatus(v, block.timestamp);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(3_000_000));
        market.setPosition(account, p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));
        market.setLocal(account, l);

        (bool liquidatable,, uint256 reward,) = executor.assess(market, account);
        assertFalse(liquidatable);
        assertEq(reward, 0);

        vm.expectRevert(bytes("Invalid oracle price"));
        executor.oraclePrice(market);
    }

    function test_oracle_stale_disables_liquidation() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);
        address account = address(0xA11CE);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(10_000);
        r.minMaintenance = UFixed6.wrap(0);
        r.liquidationFee = UFixed6.wrap(50_000);
        r.staleAfter = 10;
        market.setRiskParameter(r);

        vm.warp(100);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = 1;
        oracle.setStatus(v, 1);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(3_000_000));
        market.setPosition(account, p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));
        market.setLocal(account, l);

        (bool liquidatable,, uint256 reward,) = executor.assess(market, account);
        assertFalse(liquidatable);
        assertEq(reward, 0);

        vm.expectRevert(bytes("Stale oracle"));
        executor.oraclePrice(market);
    }

    function test_executor_applies_min_maintenance() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        executor.setInsolvencyThresholdMultiplier(0);
        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);
        address account = address(0xA11CE);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(10_000);
        r.minMaintenance = UFixed6.wrap(30_000);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = 1;
        oracle.setStatus(v, 1);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(3_000_000));
        market.setPosition(account, p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));
        market.setLocal(account, l);

        (bool liquidatable, uint256 maint, uint256 reward,) = executor.assess(market, account);
        assertTrue(liquidatable);
        assertEq(maint, 30_000);
        assertEq(reward, 1_500);
    }

    function test_executor_does_not_liquidate_without_position() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);
        address account = address(0xA11CE);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(10_000);
        r.minMaintenance = UFixed6.wrap(30_000);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = 1;
        oracle.setStatus(v, 1);

        Position memory p;
        p.size = Fixed6.wrap(int256(0));
        p.entryPrice = Fixed6.wrap(int256(3_000_000));
        market.setPosition(account, p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(-1));
        market.setLocal(account, l);

        (bool liquidatable, uint256 maint, uint256 reward,) = executor.assess(market, account);
        assertFalse(liquidatable);
        assertEq(maint, 0);
        assertEq(reward, 0);
    }

    function test_executor_tracks_accounts_and_batches() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        executor.setInsolvencyThresholdMultiplier(0);
        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);
        address a = address(0xA11CE);
        address b = address(0xB0B);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(10_000);
        r.minMaintenance = UFixed6.wrap(0);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = 1;
        oracle.setStatus(v, 1);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(3_000_000));
        market.setPosition(a, p);
        market.setPosition(b, p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));
        market.setLocal(a, l);
        market.setLocal(b, l);

        executor.trackAndCheck(address(this), address(market), a);
        executor.trackAndCheck(address(this), address(market), b);
        assertTrue(executor.isTracked(address(market), a));
        assertTrue(executor.isTracked(address(market), b));

        executor.processNextBatch(address(this), address(market), 1);
        assertTrue(market.lastUpdateProtect());
    }

    function test_sentinal_emits_callback_payload() external {
        uint256 originChainId = 1;
        uint256 destinationChainId = 1;
        address market = address(0x1111);
        address oracle = address(0);
        address executor = address(0);
        address callback = address(0x2222);
        uint64 gasLimit = 500_000;
        uint256 cronTopic = 0;

        Sentinal sentinal = new Sentinal(
            originChainId,
            destinationChainId,
            market,
            oracle,
            address(0),
            bytes32(0),
            executor,
            callback,
            gasLimit,
            cronTopic,
            10,
            1
        );

        IReactive.LogRecord memory log;
        log.chain_id = originChainId;
        log._contract = market;
        log.topic_0 = 123;
        log.topic_1 = uint256(uint160(address(0xA11CE)));
        log.block_number = 7;
        log.tx_hash = 9;
        log.log_index = 11;

        bytes memory payload = abi.encodeWithSignature(
            "trackAndCheckEvent(address,address,address,uint256,uint256,uint256,uint256,uint256)",
            address(0),
            market,
            address(0xA11CE),
            originChainId,
            log.block_number,
            log.tx_hash,
            log.log_index,
            log.topic_0
        );

        vm.expectEmit(true, true, true, true);
        emit IReactive.Callback(destinationChainId, callback, gasLimit, payload);
        sentinal.react(log);
    }

    function test_sentinal_oracle_event_triggers_batch() external {
        uint256 originChainId = 1;
        uint256 destinationChainId = 1;
        address market = address(0x1111);
        address oracle = address(0x3333);
        address executor = address(0);
        address callback = address(0x2222);
        uint64 gasLimit = 500_000;
        uint256 cronTopic = 0;
        uint256 batchSize = 7;

        Sentinal sentinal = new Sentinal(
            originChainId,
            destinationChainId,
            market,
            oracle,
            address(0),
            bytes32(0),
            executor,
            callback,
            gasLimit,
            cronTopic,
            batchSize,
            1
        );

        IReactive.LogRecord memory log;
        log.chain_id = originChainId;
        log._contract = oracle;
        log.topic_0 = 123;
        log.block_number = 7;
        log.tx_hash = 9;
        log.log_index = 11;

        bytes memory payload = abi.encodeWithSignature(
            "processNextBatchEvent(address,address,uint256,uint256,uint256,uint256,uint256,uint256)",
            address(0),
            market,
            batchSize,
            originChainId,
            log.block_number,
            log.tx_hash,
            log.log_index,
            log.topic_0
        );

        vm.expectEmit(true, true, true, true);
        emit IReactive.Callback(destinationChainId, callback, gasLimit, payload);
        sentinal.react(log);
    }

    function test_sentinal_market_event_without_account_triggers_batch() external {
        uint256 originChainId = 1;
        uint256 destinationChainId = 1;
        address market = address(0x1111);
        address oracle = address(0);
        address executor = address(0);
        address callback = address(0x2222);
        uint64 gasLimit = 500_000;
        uint256 cronTopic = 0;
        uint256 batchSize = 7;

        Sentinal sentinal = new Sentinal(
            originChainId,
            destinationChainId,
            market,
            oracle,
            address(0),
            bytes32(0),
            executor,
            callback,
            gasLimit,
            cronTopic,
            batchSize,
            1
        );

        IReactive.LogRecord memory log;
        log.chain_id = originChainId;
        log._contract = market;
        log.topic_0 = 123;
        log.topic_1 = 0;
        log.topic_2 = 0;
        log.topic_3 = 0;
        log.block_number = 7;
        log.tx_hash = 9;
        log.log_index = 11;

        bytes memory payload = abi.encodeWithSignature(
            "processNextBatchEvent(address,address,uint256,uint256,uint256,uint256,uint256,uint256)",
            address(0),
            market,
            batchSize,
            originChainId,
            log.block_number,
            log.tx_hash,
            log.log_index,
            log.topic_0
        );

        vm.expectEmit(true, true, true, true);
        emit IReactive.Callback(destinationChainId, callback, gasLimit, payload);
        sentinal.react(log);
    }

    function test_sentinal_executor_liquidation_event_triggers_batch() external {
        uint256 originChainId = 1;
        uint256 destinationChainId = 1;
        address market = address(0x1111);
        address oracle = address(0);
        address executor = address(0x4444);
        address callback = address(0x2222);
        uint64 gasLimit = 500_000;
        uint256 cronTopic = 0;
        uint256 batchSize = 7;

        Sentinal sentinal = new Sentinal(
            originChainId,
            destinationChainId,
            market,
            oracle,
            address(0),
            bytes32(0),
            executor,
            callback,
            gasLimit,
            cronTopic,
            batchSize,
            1
        );

        IReactive.LogRecord memory log;
        log.chain_id = destinationChainId;
        log._contract = executor;
        log.topic_0 = uint256(keccak256("LiquidationExecuted(address,address,bool,uint256)"));
        log.topic_1 = uint256(uint160(market));
        log.block_number = 7;
        log.tx_hash = 9;
        log.log_index = 11;

        bytes memory payload = abi.encodeWithSignature(
            "processNextBatchEvent(address,address,uint256,uint256,uint256,uint256,uint256,uint256)",
            address(0),
            market,
            batchSize,
            log.chain_id,
            log.block_number,
            log.tx_hash,
            log.log_index,
            log.topic_0
        );

        vm.expectEmit(true, true, true, true);
        emit IReactive.Callback(destinationChainId, callback, gasLimit, payload);
        sentinal.react(log);
    }

    function test_sentinal_stork_value_update_triggers_callback() external {
        uint256 originChainId = 1;
        uint256 destinationChainId = 1;
        address market = address(0x1111);
        address oracle = address(0);
        address stork = address(0x5555);
        bytes32 assetId = keccak256("ETH");
        address executor = address(0);
        address callback = address(0x2222);
        uint64 gasLimit = 500_000;
        uint256 cronTopic = 0;
        uint256 batchSize = 7;

        Sentinal sentinal = new Sentinal(
            originChainId,
            destinationChainId,
            market,
            oracle,
            stork,
            assetId,
            executor,
            callback,
            gasLimit,
            cronTopic,
            batchSize,
            1
        );

        IReactive.LogRecord memory log;
        log.chain_id = originChainId;
        log._contract = stork;
        log.topic_0 = uint256(keccak256("ValueUpdate(bytes32,uint64,int192)"));
        log.topic_1 = uint256(assetId);
        log.data = abi.encode(uint64(123), int192(2_000_000));
        log.block_number = 7;
        log.tx_hash = 9;
        log.log_index = 11;

        bytes memory payload = _storkCallbackPayload(assetId, batchSize, log);

        vm.expectEmit(true, true, true, true);
        emit IReactive.Callback(destinationChainId, callback, gasLimit, payload);
        sentinal.react(log);
    }

    function test_stork_price_update_triggers_liquidation_check_for_mapped_market() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        executor.setInsolvencyThresholdMultiplier(0);

        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);
        address account = address(0xA11CE);
        bytes32 assetId = keccak256("ETH");

        executor.setStorkAssetConfig(assetId, 1, 1);
        executor.setMarketStorkAssetId(address(market), assetId);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(100_000);
        r.minMaintenance = UFixed6.wrap(0);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = block.timestamp;
        oracle.setStatus(v, block.timestamp);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(2_000_000));
        market.setPosition(account, p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(300_000));
        market.setLocal(account, l);

        executor.trackAndCheck(address(this), address(market), account);
        assertEq(market.lastUpdateAccount(), address(0));

        v.price = Fixed6.wrap(int256(1_000_000));
        v.valid = true;
        v.timestamp = block.timestamp;
        oracle.setStatus(v, block.timestamp);

        _emitStorkUpdate(executor, assetId, int192(1_000_000));

        assertEq(market.lastUpdateAccount(), account);
        assertEq(market.lastUpdateProtect(), true);
    }

    function test_stork_price_update_does_not_bypass_perennial_oracle_staleness() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        executor.setInsolvencyThresholdMultiplier(0);

        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);
        address account = address(0xA11CE);
        bytes32 assetId = keccak256("ETH");

        executor.setStorkAssetConfig(assetId, 1, 1);
        executor.setMarketStorkAssetId(address(market), assetId);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(100_000);
        r.minMaintenance = UFixed6.wrap(0);
        r.liquidationFee = UFixed6.wrap(50_000);
        r.staleAfter = 0;
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = block.timestamp;
        oracle.setStatus(v, block.timestamp);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(2_000_000));
        market.setPosition(account, p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(300_000));
        market.setLocal(account, l);

        executor.trackAndCheck(address(this), address(market), account);
        assertEq(market.lastUpdateAccount(), address(0));

        r.staleAfter = 1;
        market.setRiskParameter(r);

        vm.warp(10);
        v.price = Fixed6.wrap(int256(1_000_000));
        v.valid = true;
        v.timestamp = 1;
        oracle.setStatus(v, 1);

        _emitStorkUpdate(executor, assetId, int192(1_000_000));

        assertEq(market.lastUpdateAccount(), address(0));
    }

    function test_direct_liquidation_routes_realized_payout() external {
        MockERC20 token = new MockERC20();
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        executor.setInsolvencyThresholdMultiplier(0);
        MockOracle oracle = new MockOracle();
        MockMarketWithFee market = new MockMarketWithFee(oracle, token);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(10_000);
        r.minMaintenance = UFixed6.wrap(0);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = block.timestamp;
        oracle.setStatus(v, block.timestamp);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(3_000_000));

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));

        uint256 feeAmount = 123;
        token.mint(address(market), feeAmount);
        market.setFeeAmount(feeAmount);

        address account = address(0xA11CE);

        market.setPosition(account, p);
        market.setLocal(account, l);

        vm.expectEmit(true, true, true, true);
        emit RealizedPayout(address(market), account, address(token), feeAmount);
        executor.checkAndExecute(address(this), address(market), account);

        assertEq(token.balanceOf(address(0xCAFE)), feeAmount);
        assertEq(token.balanceOf(address(executor)), 0);
    }

    function test_non_flash_path_emits_low_profit_execution_when_realized_is_low() external {
        MockERC20 token = new MockERC20();
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        executor.setInsolvencyThresholdMultiplier(0);
        executor.setGasEstimateForLiquidation(1);
        executor.setGasWeiPerAssetUnit(1);
        vm.txGasPrice(1);

        MockOracle oracle = new MockOracle();
        MockMarketWithFee market = new MockMarketWithFee(oracle, token);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(10_000);
        r.minMaintenance = UFixed6.wrap(0);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = block.timestamp;
        oracle.setStatus(v, block.timestamp);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(3_000_000));

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));

        market.setFeeAmount(0);

        address account = address(0xA11CE);
        market.setPosition(account, p);
        market.setLocal(account, l);

        vm.recordLogs();
        executor.checkAndExecute(address(this), address(market), account);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 want = keccak256("LowProfitExecution(address,address,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length != 0 && entries[i].topics[0] == want) {
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function test_flashloan_repay_and_profit_routing() external {
        MockERC20 token = new MockERC20();
        MockAavePool pool = new MockAavePool(10);
        token.mint(address(pool), 1_000_000);

        Executor executor = new Executor(address(this), address(pool), address(0xCAFE));
        executor.setInsolvencyThresholdMultiplier(0);
        MockOracle oracle = new MockOracle();
        MockMarketWithFee market = new MockMarketWithFee(oracle, token);
        address account = address(0xA11CE);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(10_000);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = 1;
        oracle.setStatus(v, 1);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(3_000_000));
        market.setPosition(account, p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));
        market.setLocal(account, l);

        token.mint(address(market), 1_000);
        market.setFeeAmount(1_000);

        executor.checkAndExecuteWithFlashLoan(address(this), address(market), account, address(token), 100_000);

        assertEq(token.balanceOf(address(pool)), 1_000_010);
        assertEq(token.balanceOf(address(0xCAFE)), 990);
    }

    function test_flashloan_does_not_send_preexisting_balance() external {
        MockERC20 token = new MockERC20();
        MockAavePool pool = new MockAavePool(10);
        token.mint(address(pool), 1_000_000);

        Executor executor = new Executor(address(this), address(pool), address(0xCAFE));
        executor.setInsolvencyThresholdMultiplier(0);
        MockOracle oracle = new MockOracle();
        MockMarketWithFee market = new MockMarketWithFee(oracle, token);
        address account = address(0xA11CE);

        RiskParameter memory r;
        r.maintenance = UFixed6.wrap(10_000);
        r.liquidationFee = UFixed6.wrap(50_000);
        market.setRiskParameter(r);

        OracleVersion memory v;
        v.price = Fixed6.wrap(int256(2_000_000));
        v.valid = true;
        v.timestamp = 1;
        oracle.setStatus(v, 1);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(3_000_000));
        market.setPosition(account, p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));
        market.setLocal(account, l);

        token.mint(address(executor), 777);

        token.mint(address(market), 1_000);
        market.setFeeAmount(1_000);

        executor.checkAndExecuteWithFlashLoan(address(this), address(market), account, address(token), 100_000);

        assertEq(token.balanceOf(address(pool)), 1_000_010);
        assertEq(token.balanceOf(address(0xCAFE)), 990);
        assertEq(token.balanceOf(address(executor)), 777);
    }
}
