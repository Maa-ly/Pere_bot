
## References

* [Perennial V2 Docs](https://docs.perennial.finance/)
* [Reactive Network Docs](https://dev.reactive.network/education/introduction)
* [Aave Flash Loan Docs](https://docs.aave.com/developers/guides/flash-loans)


## Todo
-- event scraping -- done
-- storage handling -- done
-- competition handling -- progress
-- spoting speeed




## liquidation math
Margin & Liquidations
Margin


┌─────────────────────────────────────────────────────────────────┐
│                         SENTINEL                                 │
│  • Watches: Market events, Oracle updates, Executor events       │
│  • Multi-batch: batchesPerTrigger for coverage                  │
│  • Chain-aware: Separate origin/destination chains              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ Callback
┌─────────────────────────────────────────────────────────────────┐
│                         EXECUTOR                                 │
│                                                                  │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │  ASSESS     │───▶│  VALIDATE   │───▶│  EXECUTE            │  │
│  │  Position   │    │  • Oracle   │    │  • Direct or Flash  │  │
│  │  Factors    │    │  • Solvency │    │  • Profit check     │  │
│  │             │    │  • Profit   │    │  • Transfer reward  │  │
│  └─────────────┘    └─────────────┘    └─────────────────────┘  │
│                                                                  │
│  Safety Features:                                                │
│  ✓ Oracle staleness check       ✓ Insolvency skip               │
│  ✓ Maker higher buffer          ✓ Dynamic gas estimation        │
│  ✓ Realized profit verification ✓ L2 gas oracle support         │
└─────────────────────────────────────────────────────────────────┘