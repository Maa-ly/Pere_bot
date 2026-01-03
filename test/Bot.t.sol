// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
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

contract MockMarket is IMarket {
    MockOracle public mockOracle;
    MarketParameter internal _parameter;
    RiskParameter internal _riskParameter;
    Position internal _position;
    Local internal _local;
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

    function setPosition(Position memory p) external {
        _position = p;
    }

    function setLocal(Local memory l) external {
        _local = l;
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

    function positions(address) external view returns (Position memory) {
        return _position;
    }

    function locals(address) external view returns (Local memory) {
        return _local;
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
    Position internal _position;
    Local internal _local;

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

    function setPosition(Position memory p) external {
        _position = p;
    }

    function setLocal(Local memory l) external {
        _local = l;
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

    function positions(address) external view returns (Position memory) {
        return _position;
    }

    function locals(address) external view returns (Local memory) {
        return _local;
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
    function test_executor_math_and_liquidation_check() external {
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
        v.timestamp = 1;
        oracle.setStatus(v, 1);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(3_000_000));
        p.accruedFunding = Fixed6.wrap(int256(0));
        p.accruedFees = Fixed6.wrap(int256(0));
        market.setPosition(p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));
        market.setLocal(l);

        (bool liquidatable, uint256 maint, uint256 reward, int256 eq) = executor.assess(market, address(0xA11CE));
        assertTrue(liquidatable);
        assertEq(maint, 20_000);
        assertEq(reward, 1_000);
        assertEq(eq, -1_000_000);
    }

    function test_executor_applies_min_maintenance() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);

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
        market.setPosition(p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));
        market.setLocal(l);

        (bool liquidatable, uint256 maint, uint256 reward,) = executor.assess(market, address(0xA11CE));
        assertTrue(liquidatable);
        assertEq(maint, 30_000);
        assertEq(reward, 1_500);
    }

    function test_executor_does_not_liquidate_without_position() external {
        Executor executor = new Executor(address(this), address(0xBEEF), address(0xCAFE));
        MockOracle oracle = new MockOracle();
        MockMarket market = new MockMarket(oracle);

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
        market.setPosition(p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(-1));
        market.setLocal(l);

        (bool liquidatable, uint256 maint, uint256 reward,) = executor.assess(market, address(0xA11CE));
        assertFalse(liquidatable);
        assertEq(maint, 0);
        assertEq(reward, 0);
    }

    function test_executor_tracks_accounts_and_batches() external {
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
        v.timestamp = 1;
        oracle.setStatus(v, 1);

        Position memory p;
        p.size = Fixed6.wrap(int256(1_000_000));
        p.entryPrice = Fixed6.wrap(int256(3_000_000));
        market.setPosition(p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));
        market.setLocal(l);

        executor.trackAndCheck(address(this), address(market), address(0xA11CE));
        executor.trackAndCheck(address(this), address(market), address(0xB0B));
        assertTrue(executor.isTracked(address(market), address(0xA11CE)));
        assertTrue(executor.isTracked(address(market), address(0xB0B)));

        executor.processNextBatch(address(this), address(market), 1);
        assertTrue(market.lastUpdateProtect());
    }

    function test_sentinal_emits_callback_payload() external {
        uint256 originChainId = 1;
        uint256 destinationChainId = 1;
        address market = address(0x1111);
        address oracle = address(0);
        address callback = address(0x2222);
        uint64 gasLimit = 500_000;
        uint256 cronTopic = 0;

        Sentinal sentinal =
            new Sentinal(originChainId, destinationChainId, market, oracle, callback, gasLimit, cronTopic, 10);

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
        address callback = address(0x2222);
        uint64 gasLimit = 500_000;
        uint256 cronTopic = 0;
        uint256 batchSize = 7;

        Sentinal sentinal =
            new Sentinal(originChainId, destinationChainId, market, oracle, callback, gasLimit, cronTopic, batchSize);

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

    function test_flashloan_repay_and_profit_routing() external {
        MockERC20 token = new MockERC20();
        MockAavePool pool = new MockAavePool(10);
        token.mint(address(pool), 1_000_000);

        Executor executor = new Executor(address(this), address(pool), address(0xCAFE));
        MockOracle oracle = new MockOracle();
        MockMarketWithFee market = new MockMarketWithFee(oracle, token);

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
        market.setPosition(p);

        Local memory l;
        l.collateral = Fixed6.wrap(int256(0));
        market.setLocal(l);

        token.mint(address(market), 1_000);
        market.setFeeAmount(1_000);

        executor.checkAndExecuteWithFlashLoan(address(this), address(market), address(0xA11CE), address(token), 100_000);

        assertEq(token.balanceOf(address(pool)), 1_000_010);
        assertEq(token.balanceOf(address(0xCAFE)), 990);
    }
}
