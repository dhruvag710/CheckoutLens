# CheckoutLens: Power BI Dashboard & Project Specification

## Overview
This directory contains the production-grade **Power BI Project (`CheckoutLens.pbip`)** deliverable for the CheckoutLens e-commerce funnel analytics portfolio project.

The report is built using modern **Power BI Project (`.pbip`)**, **Tabular Model Definition Language (TMDL)**, and **Power BI Enhanced Report (`.pbir`)** formats, ensuring clean source-control tracking and reproducibility.

---

## Deliverable Architecture & File Layout

```text
powerbi/
├── CheckoutLens.pbip                      # Root project file (open directly in Power BI Desktop)
├── CheckoutLens.Report/                  # Report visual canvas definition (PBIR format)
│   ├── definition/
│   │   ├── pages/
│   │   │   ├── aeba095f2a718ea666de/      # "Executive Funnel & Abandonment" page (1920x1080)
│   │   │   │   ├── page.json              # Canvas layout metadata & dimensions
│   │   │   │   └── visuals/               # Modular visual container definitions
│   │   │   │       ├── header_banner/     # Executive Title & Context banner
│   │   │   │       ├── kpi_card_views/    # KPI Card: 77,020 Product Views
│   │   │   │       ├── kpi_card_checkouts/# KPI Card: 5,416 Checkout Starts
│   │   │   │       ├── kpi_card_purchases/# KPI Card: 1,792 Strict Purchases
│   │   │   │       ├── kpi_card_conversion# KPI Card: 2.33% Strict Conversion Rate
│   │   │   │       ├── funnel_stages/     # Native 6-Stage Strict Funnel Visual
│   │   │   │       ├── 816b73d2dd7f1e9474db/ # Device Category Conversion Bar Chart
│   │   │   │       ├── channel_chart/     # Traffic Acquisition Channel Bar Chart
│   │   │   │       ├── landing_table/     # Landing Page Diagnostics Table
│   │   │   │       └── footer_notes/      # Methodology & Attribution Footer Note
│   │   │   └── pages.json                 # Page ordering metadata
│   │   ├── report.json                    # Theme and report-level configurations
│   │   └── version.json                   # PBIR schema version
│   └── definition.pbir                    # Report-to-Dataset connection pointer
└── CheckoutLens.SemanticModel/            # Tabular Data Model (TMDL format)
    └── definition/
        ├── model.tmdl                     # Model metadata & table references
        └── tables/
            ├── GlobalFunnel.tmdl          # Validated 6-stage funnel calculated table
            ├── DeviceFunnel.tmdl          # Device segment table + Core KPI measures
            ├── ChannelFunnel.tmdl         # Channel table + Strict CR calculated column
            ├── CountryFunnel.tmdl         # Geographic country segmentation table
            └── LandingPageFunnel.tmdl     # Landing page table + Strict & Macro CR columns
```

---

## Dashboard Visual Layout (One-Page Executive Suite)

The dashboard is designed for high-impact executive presentation on a standard 16:9 1080p canvas (`1920 x 1080`):

### 1. Executive Header & KPI Cards (Top Section: Y = 15 to 210)
- **Header Banner:** Displays the project title, data scope (GA4 demo dataset, Nov 2020 – Jan 2021, 360,129 sessions), and core analytical purpose.
- **Card 1 — Product-View Sessions (Stage 1):** `77,020` (Denominator for strict e-commerce conversion).
- **Card 2 — Checkout Starts (Stage 3):** `5,416` (Users initiating checkout; boundary of checkout abandonment).
- **Card 3 — Strict Sequential Purchases (Stage 6):** `1,792` (Sessions strictly progressing through all 6 stages).
- **Card 4 — Strict View-to-Purchase CR:** `2.33%` (Benchmark e-commerce strict conversion rate).

### 2. Analytical Columns (Middle Section: Y = 225 to 1000)
- **Left Column (Funnel Visual, Width = 580):**
  - **Six-Stage Strict Sequential Funnel:** Visualizes progression across the 6 chronological steps using the validated global counts:
    1. Product View: `77,020`
    2. Add to Cart: `15,167`
    3. Begin Checkout: `5,416`
    4. Add Shipping: `3,119`
    5. Add Payment: `2,438`
    6. Strict Purchase: `1,792`
- **Middle Column (Segment Diagnostics, Width = 580):**
  - **Device Conversion Bar Chart (Top):** Strict conversion across Desktop (`2.27%`), Mobile (`2.42%`), and Tablet (`2.12%`).
  - **Traffic Channel Conversion Bar Chart (Bottom):** Strict conversion across Acquisition Channels (`Referral` 2.81%, `Other` 2.65%, `Direct` 2.29%, `Organic Search` 1.93%).
  - **Landing Page Performance Table:** Displays entry paths within the right-hand dashboard quadrant ($X=1230, W=660, H=775$), sorted descending by product-view sessions. Features 7 columns in exact order:
    1. *Landing page path*
    2. *Product-view sessions* (formatted as whole numbers: `#,0`)
    3. *Checkout-start sessions* (formatted as whole numbers: `#,0`)
    4. *Strict purchase sessions* (formatted as whole numbers: `#,0`)
    5. *Strict view-to-purchase conversion rate* (formatted as percentage: `0.00%`)
    6. *Macro checkout-to-purchase conversion rate* (formatted as percentage: `0.00%`)
    7. *Sample-size status* (statistical reliability tier: Robust, Moderate, Low Sample)

### 3. Footer Context & Governance Note (Bottom Section: Y = 1015 to 1060)
- Clarifies methodology:
  - **Strict Conversion:** Requires chronological stage progression ($View \to Cart \to Checkout \to Shipping \to Payment \to Purchase$).
  - **Macro Conversion:** Measures direct checkout-to-purchase completion ($Purchases / Checkout Starts = 52.33\%$).
  - **Attribution Scope:** Channel groupings reflect first-user acquisition attribution.

---

## Data Model & DAX Formulas

### Semantic Model Relationships
Segment tables are maintained as independent dimensional slices (Device, Channel, Country, Landing Page), guaranteeing that segment counts sum to the validated global totals without Cartesian fan-out errors.

### Key Measures Defined in `DeviceFunnel.tmdl`
```dax
// Global Funnel Aggregations
Total Product Views = SUM(DeviceFunnel[sessions_view_item])
Total Checkout Starts = SUM(DeviceFunnel[sessions_begin_checkout])
Total Strict Purchases = SUM(DeviceFunnel[sessions_purchase_strict])

// Strict Conversion Rate (2.33%)
Strict Conversion Rate (Overall) = 
DIVIDE(SUM(DeviceFunnel[sessions_purchase_strict]), SUM(DeviceFunnel[sessions_view_item]))

// Macro Checkout Completion Rate (52.33%)
Macro Checkout Completion Rate (Overall) = 
DIVIDE(SUM(DeviceFunnel[sessions_purchase_macro]), SUM(DeviceFunnel[sessions_begin_checkout]))
```

### Calculated Columns for Percentage Formatting
To prevent percentage-point values (e.g. `2.27`) from rendering as `227%`, explicit calculated columns divide raw values by 100 with `0.00%` format strings:
- `DeviceFunnel[Strict Conversion Rate] = DIVIDE(DeviceFunnel[overall_strict_cr_pct], 100)`
- `ChannelFunnel[Strict Conversion Rate] = DIVIDE(ChannelFunnel[overall_strict_cr_pct], 100)`
- `LandingPageFunnel[Strict Conversion Rate] = DIVIDE(LandingPageFunnel[overall_strict_cr_pct], 100)`
- `LandingPageFunnel[Macro Conversion Rate] = DIVIDE(LandingPageFunnel[macro_checkout_to_purchase_cr_pct], 100)`

---

## How to Open in Power BI Desktop

1. **Prerequisites:** Ensure **Power BI Desktop** is installed.
2. **Open the Project:**
   - Double-click `powerbi/CheckoutLens.pbip` in Windows File Explorer, **OR**
   - In Power BI Desktop, click **File** $\to$ **Open Report** $\to$ browse to `powerbi/CheckoutLens.pbip`.
3. **Verify Canvas:** Power BI Desktop will parse the TMDL model and PBIR visual definitions, loading the complete 1-page executive dashboard with all 10 visuals aligned.
4. **Export Standalone `.pbix` (Optional):**
   - Click **File** $\to$ **Save As** $\to$ select **Power BI Document (*.pbix)** $\to$ save as `powerbi/CheckoutLens_Dashboard.pbix` if you require a single binary file for sharing or submission.

---

## Backup Notice
A pristine backup of the initial project state before visual injection is archived in `powerbi_backup/`.
