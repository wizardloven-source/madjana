# PHASE 1 — Feature Inventory

| # | Feature | Status | Backend | Local DB | Repository | Use Case | UI | Missing | Reuse |
|---|---------|--------|---------|----------|------------|----------|-----|---------|-------|
| 1 | Dashboard KPIs | Partial | ✅ | ✅ | ✅ Partial | ❌ | ✅ Partial | Comparison/Trends provider, enhanced cards | Desktop DashboardScreen, Mobile HomeScreen |
| 2 | Flock Performance | Partial | ✅ | ✅ | ✅ | ❌ | ✅ Partial | Performance ranking provider, enhanced UI | FlockAccountingScreen, FlockRepository |
| 3 | Production Analytics | Partial | ✅ | ✅ | ✅ | ❌ | ✅ Basic | Analytics provider, daily/weekly/monthly views, charts | ReportsScreen, EggProductionRepository |
| 4 | Mortality Analytics | Partial | ✅ | ✅ | ✅ | ❌ | ✅ Basic | Analytics provider, cause breakdown, alerts | ReportsScreen, MortalityRepository |
| 5 | Feed Analytics | Partial | ✅ | ✅ | ✅ Partial | ❌ | ✅ Basic | Analytics provider, feed ledger, forecast | ReportsScreen, FeedRepository.getCurrentFeedStock() |
| 6 | Low Stock Alerts | Partial | ✅ | ✅ | ✅ | ❌ | ❌ | Alert provider, threshold config, deduplication | InventoryRepository, InventoryItemModel |
| 7 | Customer 360 | Partial | ✅ | ✅ | ✅ | ❌ | ✅ Basic | Analytics provider, aggregated view, statement | CustomersScreen, DispatchRepository, PaymentRepository |
| 8 | Supplier Intelligence | Partial | ✅ | ✅ | ✅ | ❌ | ❌ | Analytics provider, aggregation from feed_received | FeedReceivedModel.supplier field |
| 9 | Cost per Egg | Missing | ✅ | ✅ | ✅ | ❌ | ❌ | Analytics calculation, UI | FeedReceived.pricePerExpenses, EggProduction |
| 10 | Flock Profitability | Missing | ✅ | ✅ | ✅ | ❌ | ❌ | Analytics calculation, ranking UI | All repos |
