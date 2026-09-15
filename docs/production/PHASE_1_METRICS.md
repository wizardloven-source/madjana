# PHASE 1 — Metrics Definitions

## 1. Production Rate
- **Metric:** Production Rate %
- **Definition:** `(Total Eggs Produced / Active Birds) × 100`
- **Source Tables:** egg_production, flocks
- **Filters:** farm_id, flock_id, date range
- **Edge Cases:** 0 birds → 0%, 0 eggs → 0%
- **Owner:** FarmAnalytics.productionRate() + ProductionKpi

## 2. Average Production Rate
- **Metric:** Average Production Rate %
- **Definition:** `Total Eggs / (Bird Count × Days) × 100`
- **Source Tables:** egg_production, flocks
- **Filters:** farm_id, date range
- **Edge Cases:** 0 days → 0%, 0 birds → 0%
- **Owner:** FarmAnalytics.avgProductionRate()

## 3. Mortality Rate (Daily)
- **Metric:** Daily Mortality Rate %
- **Definition:** `Total Deaths / (Bird Count × Days) × 100`
- **Source Tables:** mortality, flocks
- **Filters:** farm_id, flock_id, date range
- **Thresholds:** ok < 0.10%, warning >= 0.10%, danger >= 0.20%
- **Owner:** FarmAnalytics.dailyMortalityRate()

## 4. Feed Days Left
- **Metric:** Feed Days Remaining
- **Definition:** `Current Stock (kg) / Average Daily Consumption (kg)`
- **Source Tables:** feed_received, feed_consumption
- **Filters:** farm_id
- **Thresholds:** ok > 7 days, warning <= 7 days, danger <= 3 days
- **Edge Cases:** 0 consumption → null (unknown)
- **Owner:** FarmAnalytics.feedDaysLeft()

## 5. Feed Per Bird
- **Metric:** Feed Consumed Per Bird (kg)
- **Definition:** `Total Feed Consumed / Active Birds`
- **Source Tables:** feed_consumption, flocks
- **Filters:** farm_id, flock_id, date range

## 6. Eggs Per Bird
- **Metric:** Eggs Produced Per Bird
- **Definition:** `Total Eggs / Current Birds`
- **Source Tables:** egg_production, flocks

## 7. Cost Per Egg
- **Metric:** Cost Per Egg ($)
- **Definition:** `(Feed Cost + Shared Expenses) / Total Eggs`
- **Source Tables:** feed_received, expenses, egg_production
- **Note:** Medications cost excluded (no price field in schema)
- **Label:** Always shown as "Estimated" since shared costs are proportional

## 8. Margin Per Egg
- **Metric:** Estimated Margin Per Egg ($)
- **Definition:** `(Revenue - Total Cost) / Total Eggs`
- **Source Tables:** payments, feed_received, expenses, egg_production
- **Label:** Always shown as "Estimated"

## 9. Customer Outstanding
- **Metric:** Customer Balance Due
- **Definition:** `Total Sales - Total Paid` (also stored as customers.total_debt)
- **Source Tables:** payments, customers

## 10. Production Anomaly
- **Metric:** Production Drop Detection
- **Definition:** Compare today's rate vs 7-day moving average
- **Thresholds:** warning >= 15% drop, critical >= 25% drop
- **Source Tables:** egg_production, flocks
- **Owner:** detectProductionAnomalies()

## 11. Waste Rate
- **Metric:** Egg Waste Rate %
- **Definition:** `(Broken + Dirty Eggs) / Total Eggs × 100`
- **Source Tables:** egg_production

## 12. Percentage Change
- **Metric:** Period-over-Period Change %
- **Definition:** `(Current - Previous) / |Previous| × 100`
- **Used for:** All KPI comparisons
