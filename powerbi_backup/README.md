# CheckoutLens: Power BI Dashboard Specification

## Overview
This directory will contain the Power BI reporting assets (`.pbix` report file, theme configurations, DAX measure documentation, and visual layouts) built in **Phase 3** of the project.

---

## Planned Dashboard Architecture

### Page 1: Executive Funnel Overview & Drop-off Waterfall
- **Primary Objective:** Provide business leadership with high-level conversion health and identify the single largest leakage point in the checkout process.
- **Key Visuals:**
  - **KPI Scorecards:** Total Sessions, Checkout Started, Overall Conversion Rate (E-commerce CR), Total Revenue ($), and Average Order Value (AOV).
  - **Horizontal Funnel / Waterfall Visual:** Progression from Product View -> Add to Cart -> Begin Checkout -> Add Shipping -> Add Payment -> Purchase.
  - **Drop-off Heatmap:** Step-by-step abandonment rate (%) and absolute lost session volume.

### Page 2: Customer & Device Segment Drill-Down
- **Primary Objective:** Equip product and engineering teams with granular segment visibility to isolate technical or UX frictions.
- **Key Dimensions & Slicers:**
  - **Device Category:** Mobile vs. Desktop vs. Tablet
  - **Browser & OS:** Chrome, Safari, Firefox, Edge, iOS, Android
  - **Traffic Medium:** Organic Search, Paid (cpc), Direct, Referral
  - **User Type:** New vs. Returning visitors
- **Key Visuals:**
  - Multi-line conversion comparison across device categories
  - Matrix table showing step-by-step drop-offs by device/browser combination

### Page 3: Revenue Opportunity Sizing & Action Matrix
- **Primary Objective:** Size the financial value of fixing friction points and route action items to specific cross-functional teams.
- **Key Elements:**
  - **Opportunity Calculator:** Interactive what-if parameter (e.g. "+1.5% checkout completion rate = $XX,XXX annual revenue recovered").
  - **Cross-Functional Ownership Matrix:**
    - *UX / Design:* Cart-to-Checkout transition clarity
    - *Engineering:* Mobile checkout latency & payment form validation
    - *Marketing / Merchandising:* Shipping threshold transparency & abandoned cart triggers

---

## Planned Data Model
- **Fact Table:** `Fact_FunnelSessions` (Granular session-level funnel step flags)
- **Dimension Tables:**
  - `Dim_Device` (Device category, OS, Browser)
  - `Dim_Traffic` (Source, Medium, Campaign)
  - `Dim_Date` (Calendar hierarchy)
- **Star Schema Design:** All relationships single-direction 1-to-many.

---

## Planned DAX Measure Portfolio Preview
```dax
// Step Conversion Rate
Conversion_Rate_Overall = 
DIVIDE(
    CALCULATE(COUNTROWS('Fact_FunnelSessions'), 'Fact_FunnelSessions'[has_purchased] = 1),
    CALCULATE(COUNTROWS('Fact_FunnelSessions'), 'Fact_FunnelSessions'[has_view_item] = 1),
    0
)

// Checkout to Purchase Completion Rate
Checkout_Completion_Rate = 
DIVIDE(
    CALCULATE(COUNTROWS('Fact_FunnelSessions'), 'Fact_FunnelSessions'[has_purchased] = 1),
    CALCULATE(COUNTROWS('Fact_FunnelSessions'), 'Fact_FunnelSessions'[has_begin_checkout] = 1),
    0
)
```

*(Detailed report implementation will occur in Phase 3 following Phase 2 SQL modeling)*
