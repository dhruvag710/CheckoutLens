# CheckoutLens: Data Directory

## Overview
This directory stores sanitized, aggregated query outputs exported from Google BigQuery. 

> **Important Data Governance Rule:**  
> Never download or commit the entire raw 4.3M-event Google Analytics 4 dataset to GitHub. Only aggregated, analytical summary tables (CSV files typically < 5 MB) are exported and used for downstream Python analysis and Power BI reporting.

---

## Output Tables & Expected Exports

| Export File Name | Source Query | Description | Target Use |
| :--- | :--- | :--- | :--- |
| `01_event_inventory.csv` | `sql/01_data_audit.sql` (Query 1) | Total events and distinct users by event type | Data validation & coverage audit |
| `04_funnel_stage_audit.csv` | `sql/01_data_audit.sql` (Query 8) | Baseline event-presence counts across the 6 stages | Exploratory drop-off validation |
| `02_quality_checks.csv` | `sql/02_funnel_analysis.sql` (Query 1.1 & 1.2) | Orphan purchases, stage skippers & out-of-order sessions | Quality assurance documentation |
| `03_funnel_sequential_summary.csv` | `sql/02_funnel_analysis.sql` (Query 3.1) | Strict 6-stage sequential funnel counts, CR & drop-offs | Core Funnel Visual & Drop-off Waterfall |
| `04_funnel_daily_summary.csv` | `sql/02_funnel_analysis.sql` (Query 5.1) | Daily session-level funnel progression by date & device | Power BI Time-Series & Trends |
| `05_device_segment_funnel.csv` | `sql/03_segment_analysis.sql` (Query 1.1) | Funnel progression across Desktop, Mobile, and Tablet | Device Diagnostics & Friction Analysis |
| `06_traffic_channel_funnel.csv` | `sql/03_segment_analysis.sql` (Query 2.1) | Funnel progression by First-User acquisition channel | Channel Acquisition & Conversion |
| `07_country_segment_funnel.csv` | `sql/03_segment_analysis.sql` (Query 3.1) | Funnel progression across geographic countries | Geographic Drop-off & International Analysis |
| `08_landing_page_funnel.csv` | `sql/03_segment_analysis.sql` (Query 4.1) | Funnel progression by initial page_view landing path | Entry Page UX & Drop-off Analysis |
| `09_hourly_intensity.csv` | `sql/03_segment_analysis.sql` (Query 5.1) | 24-hour UTC traffic, checkout, and purchase volume | Time-of-day purchase behavior |
| `10_product_category_funnel.csv` | `sql/03_segment_analysis.sql` (Query 6.1) | Unnested item-category views, cart adds, purchases & revenue | Merchandising & Category Drop-offs |
| `11_revenue_sensitivity_matrix.csv` | `sql/03_segment_analysis.sql` (Query 7.1) | Baseline revenue, AOV, and +1% to +5% incremental lift | Executive Opportunity Sizing |
| `12_segment_funnel_summary.csv` | `sql/03_segment_analysis.sql` (Query 8.1) | Compact multi-dimensional table (Device x Geography) | Power BI Star Schema Fact Table |

---

## How to Export from BigQuery
1. Open the [Google Cloud BigQuery Console](https://console.cloud.google.com/bigquery).
2. Run the desired query from `sql/02_funnel_analysis.sql` or `sql/03_segment_analysis.sql`.
3. In the **Query results** panel, click **Save results** -> **CSV (local file)** or **CSV (Google Drive)**.
4. Save the file into this `data/` directory using the naming convention above.
5. All `.csv`, `.parquet`, and `.json` data files are excluded by `.gitignore` to prevent repository bloat.
