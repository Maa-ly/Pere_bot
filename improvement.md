Detailed Explanation of Code Improvements
1. Dynamic Gas Estimation
The Problem
// Current code in executor.sol (line 61)
assumedGasCost = 0;
The assumedGasCost is set to 0 and only changes if the owner manually calls setAssumedGasCost(). This creates problems:

Scenario	Issue
Network congestion	Gas prices spike 10-100x, but your profitable() check still uses old value
Bull market volatility	Liquidations happen during high-gas periods → you lose money
Chains with variable gas	Arbitrum/Optimism L1 data fees fluctuate constantly
How Profitability Gets Miscalculated
function profitable(uint256 reward, uint256 flashLoanFee) public view returns (bool) {
    uint256 cost = assumedGasCost + flashLoanFee + safetyMargin + minProfit;
    return discountedReward > cost;
    // ❌ If assumedGasCost = 0 but actual gas = 500,000 gwei, you lose money
}
The Fix
Query the current gas price on-chain and estimate execution cost:

// Add these state variables
uint256 public gasEstimateForLiquidation; // Estimated gas units for liquidation tx
// Add this function
function estimateGasCost() public view returns (uint256) {
    // Get current gas price from the block
    uint256 gasPrice = tx.gasprice;
    
    // Multiply by estimated gas units needed
    // A typical liquidation + flash loan ≈ 300,000-500,000 gas
    return gasPrice * gasEstimateForLiquidation;
}
// Updated profitable() function
function profitable(uint256 reward, uint256 flashLoanFee) public view returns (bool) {
    uint256 discountedReward = (reward * (ONE_HUNDRED_PERCENT - rewardDiscountPpm)) / ONE_HUNDRED_PERCENT;
    
    // Use dynamic gas cost instead of static
    uint256 dynamicGasCost = estimateGasCost();
    uint256 cost = dynamicGasCost + flashLoanFee + safetyMargin + minProfit;
    
    return discountedReward > cost;
}
// Owner can set the gas units estimate
function setGasEstimateForLiquidation(uint256 gasUnits) external onlyOwner {
    gasEstimateForLiquidation = gasUnits;
}
For L2 Chains (Arbitrum/Optimism)
L2s have separate L1 data fees. You'd need to query the L1 gas oracle:

// Example for Arbitrum
interface IArbGasInfo {
    function getPricesInWei() external view returns (
        uint256 perL2Tx,
        uint256 perL1CalldataUnit,
        uint256 perStorageUnit,
        uint256 perArbGasBase,
        uint256 perArbGasCongestion,
        uint256 perArbGasTotal
    );
}
2. Global Event Deduplication
The Problem
// Current code in executor.sol (lines 247-248)
if (lastAccountEventId[market][account] == eventId) return;
lastAccountEventId[market][account] = eventId;
This deduplicates per account within a market. But consider this scenario:

Oracle Price Update Event:

Event is emitted once (single eventId)
Multiple accounts become liquidatable due to price change
You only process the first account because eventId is stored per-account
Wait, actually looking at your code more carefully - this might be intentional. Let me re-examine...

function trackAndCheckEvent(..., uint256 originTxHash, ...) {
    uint256 eventId = keccak256(...);
    if (lastAccountEventId[market][account] == eventId) return;  // ✓ Per-account is correct here
    lastAccountEventId[market][account] = eventId;
    ...
}
For trackAndCheckEvent, per-account dedup is correct because each call is for a specific account.

The actual issue is in the Sentinel for oracle events:

// sentinal.sol (lines 75-89)
if (log._contract == oracle) {
    // Oracle event triggers batch processing
    bytes memory oraclePayload = abi.encodeWithSignature(
        "processNextBatchEvent(...)",
        ...
    );
    emit Callback(...);  // Only emits ONCE per oracle event
}
When an oracle emits a price update, you only trigger one batch. But if the batch doesn't cover all accounts, you miss some.

The Fix
Option A: Use lastBatchEventId (already exists!)

Your code already has this for batch processing:

// executor.sol (lines 275-279)
function processNextBatchEvent(...) {
    uint256 eventId = keccak256(...);
    if (lastBatchEventId[market] == eventId) return;  // Global per-market
    lastBatchEventId[market] = eventId;
    _processNextBatch(market, maxCount);
}
This is a global dedup per market, which is correct. But the issue is:

function _processNextBatch(address market, uint256 maxCount) internal {
    // Only processes `maxCount` accounts per call
    // If more accounts need checking, they're missed until next event
}
Option B: Continue processing until complete

Modify the Sentinel to emit multiple callbacks if needed, or use a loop:

// In Executor - ensure full coverage
function processNextBatchEvent(...) external authorizedSenderOnly rvmIdOnly(rvmId) {
    uint256 eventId = keccak256(...);
    if (lastBatchEventId[market] == eventId) return;
    lastBatchEventId[market] = eventId;
    
    // Process ALL accounts, not just maxCount
    _processAllAccounts(market);
}
function _processAllAccounts(address market) internal {
    address[] storage accounts = trackedAccounts[market];
    for (uint256 i = 0; i < accounts.length; i++) {
        _checkAndExecute(market, accounts[i]);
    }
}
WARNING

Processing all accounts in one TX can hit gas limits. A better approach is to track how many times a batch event was processed and continue from where you left off.

Option C: Multi-batch with continuation

mapping(address => uint256) public batchProgress;  // Track progress per market
function processNextBatchEvent(...) external {
    uint256 eventId = keccak256(...);
    
    // If same event but not finished, continue processing
    if (lastBatchEventId[market] == eventId) {
        if (batchProgress[market] == 0) return;  // Already completed
    } else {
        lastBatchEventId[market] = eventId;
        batchProgress[market] = trackedAccounts[market].length;  // Reset
    }
    
    _processNextBatch(market, maxCount);
    batchProgress[market] -= maxCount;
}
3. Unbounded Array Cleanup
The Problem
// executor.sol (lines 228-230)
if (!isTracked[market][account]) {
    isTracked[market][account] = true;
    trackedAccounts[market].push(account);  // ❌ Only grows, never shrinks
}
Over time:

User opens position → account added to array
User closes position → account stays in array
Repeat 1000x → array has 1000 entries, 900 are dead
This wastes gas in _processNextBatch():

function _processNextBatch(...) {
    for (; i < end; i++) {
        _checkAndExecute(market, accounts[i]);  // Checking closed positions = wasted gas
    }
}
The Fix
Option A: Skip + Mark for cleanup

function _processNextBatch(address market, uint256 maxCount) internal {
    address[] storage accounts = trackedAccounts[market];
    uint256 i = nextIndex[market];
    uint256 end = i + maxCount;
    if (end > accounts.length) end = accounts.length;
    
    for (; i < end; i++) {
        address account = accounts[i];
        
        // Skip if no position (position was closed)
        if (!_hasPosition(market, account)) {
            // Optionally untrack
            isTracked[market][account] = false;
            continue;
        }
        
        _checkAndExecute(market, account);
    }
    
    nextIndex[market] = (i == accounts.length) ? 0 : i;
}
Option B: Swap-and-pop removal

Remove closed positions efficiently using swap-and-pop:

mapping(address => mapping(address => uint256)) public accountIndex;  // market => account => index
function _removeAccount(address market, address account) internal {
    uint256 idx = accountIndex[market][account];
    address[] storage accounts = trackedAccounts[market];
    
    // Swap with last element
    address lastAccount = accounts[accounts.length - 1];
    accounts[idx] = lastAccount;
    accountIndex[market][lastAccount] = idx;
    
    // Pop last
    accounts.pop();
    delete accountIndex[market][account];
    isTracked[market][account] = false;
}
function cleanup(address market, uint256 maxCount) external {
    address[] storage accounts = trackedAccounts[market];
    uint256 removed = 0;
    
    for (uint256 i = 0; i < accounts.length && removed < maxCount; ) {
        if (!_hasPosition(market, accounts[i])) {
            _removeAccount(market, accounts[i]);
            removed++;
            // Don't increment i - new element swapped into this index
        } else {
            i++;
        }
    }
}
Option C: Lazy cleanup during processing

Clean up as you go in _processNextBatch:

function _processNextBatch(address market, uint256 maxCount) internal {
    address[] storage accounts = trackedAccounts[market];
    uint256 i = nextIndex[market];
    uint256 processed = 0;
    
    while (processed < maxCount && accounts.length > 0 && i < accounts.length) {
        address account = accounts[i];
        
        if (!_hasPosition(market, account)) {
            // Swap and pop
            accounts[i] = accounts[accounts.length - 1];
            accounts.pop();
            isTracked[market][account] = false;
            // Don't increment i, check new element at same index
            continue;
        }
        
        _checkAndExecute(market, account);
        processed++;
        i++;
    }
    
    nextIndex[market] = (i >= accounts.length) ? 0 : i;
}
The Maker Problem Explained
Your current equity calculation:

function equity(...) public pure returns (int256) {
    return collateral + pnl(positionSize, price, entryPrice) - fundingAccrued - feesAccrued;
}
This works for takers (longs/shorts) because their PnL is straightforward: size × (currentPrice - entryPrice).

But makers in Perennial V2 are different:

Factor	Taker	Maker
PnL source	Price movement	Counterparty to takers
Exposure	Direct (size × Δprice)	Inverse of net taker skew
Funding	Pays or receives	Always receives (market maker fee)
Liquidation trigger	Clear equity threshold	Can be complex with low notional
Makers essentially absorb the opposite of the net long/short imbalance. If there are more longs than shorts, makers are effectively short the difference.

My Recommendation: Hybrid Approach
Given the complexity, I'd suggest combining your options:

1. Add Maker Detection + Higher Buffer
// Add state variable
uint256 public makerLiquidationBuffer;  // e.g., 1_100_000 (110% instead of 102%)
// Modify assess() to detect maker positions
function assess(IMarket market, address account) public view returns (...) {
    Position memory p = market.positions(account);
    
    // Detect if this is a maker position
    // In Perennial V2, makers have maker > 0 in their order/position
    bool isMaker = _isMakerPosition(market, account);
    
    // Use higher buffer for makers
    uint256 buffer = isMaker ? makerLiquidationBuffer : liquidationBuffer;
    
    liquidatable = isLiquidatable(equityValue, maintenanceRequirement, buffer);
    
    // Discount maker rewards due to uncertainty
    if (isMaker) {
        reward = (reward * 80) / 100;  // 20% haircut
    }
}
2. Skip Low-Value Maker Positions
uint256 public minMakerNotional;  // e.g., $1000
function _checkAndExecute(address market, address account) internal {
    (bool liquidatable, uint256 maintReq, uint256 reward, int256 eq) = assess(IMarket(market), account);
    
    // Skip if maker with tiny position (exposure-driven liquidation)
    if (_isMakerPosition(IMarket(market), account)) {
        Position memory p = IMarket(market).positions(account);
        uint256 notional_ = notional(Fixed6.unwrap(p.size), oraclePrice(IMarket(market)));
        if (notional_ < minMakerNotional) return;  // Too risky, skip
    }
    
    if (!liquidatable) return;
    if (!profitable(reward, 0)) return;
    // ... execute
}
3. Query Actual Maintenance from Protocol (Best but harder)
Perennial V2 likely has a function to check if an account is actually liquidatable from the protocol's perspective. If so, use it:

function _isActuallyLiquidatable(IMarket market, address account) internal view returns (bool) {
    // If Perennial exposes a canLiquidate() or similar, use it
    // This would be the source of truth
    try market.canLiquidate(account) returns (bool result) {
        return result;
    } catch {
        // Fallback to our calculation
        (bool liquidatable,,,) = assess(market, account);
        return liquidatable;
    }
}
My Take on the Three Options You Listed
Option	Pros	Cons	My Vote
Skip makers entirely	Safe, no false positives	Miss ~30-50% of liquidation rewards	❌ Too conservative
Higher buffer for makers	Simple, catches obvious cases	Still might miss edge cases	✅ Good middle ground
Require abs(size) > threshold	Filters exposure-driven liquidations	Might miss legitimate liquidations	✅ Good safety net
My recommendation: Combine Option 2 + Option 3.

// Configuration
uint256 public makerLiquidationBuffer = 1_150_000;  // 115% (vs 102% for takers)
uint256 public minMakerSize = 100e6;  // Minimum position size in Fixed6
function _shouldSkipMaker(IMarket market, address account) internal view returns (bool) {
    if (!_isMakerPosition(market, account)) return false;
    
    Position memory p = market.positions(account);
    int256 size = Fixed6.unwrap(p.size);
    
    // Skip if maker position is too small (exposure-driven, hard to model)
    return _abs(size) < minMakerSize;
}
or use something bteer