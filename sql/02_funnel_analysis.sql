-- =================================================================================================
-- PROJECT: CheckoutLens - E-commerce Checkout Abandonment & Funnel Analytics
-- SCRIPT: 02_funnel_analysis.sql
-- PURPOSE: Reliable Sequential Funnel Analytics, Quality Diagnostics, and Conversion Metrics.
--
-- DATASET: `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
-- DATE RANGE: 2020-11-01 to 2021-01-31 (92 daily partitioned tables)
--
-- CONTEXT & AUDIT FINDINGS:
-- Audit established 360,129 unique composite sessions. Event presence counts:
--   - view_item: 77,020 sessions
--   - add_to_cart: 15,188 sessions
--   - begin_checkout: 11,106 sessions
--   - add_shipping_info: 11,105 sessions
--   - add_payment_info: 6,815 sessions
--   - purchase: 4,848 sessions
-- CRITICAL METHODOLOGICAL DISTINCTION:
-- Event-presence counts do NOT enforce chronological progression or prerequisite completion.
-- This script evaluates both strict sequential progression, flexible/skipped paths, and quality gaps.
-- =================================================================================================


-- =================================================================================================
-- SECTION 1: DATA QUALITY & ORDERING DIAGNOSTICS
-- Inspect whether events occur chronologically, if stages are skipped, or if orphan purchases exist.
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 1.1: Quality Check - Orphan Purchases (Purchases without Preceding Funnel Events)
-- In e-commerce telemetry, sessions with purchase but no begin_checkout or add_to_cart indicate:
-- (a) Cross-session checkout completion (saved carts / returning sessions),
-- (b) Third-party hosted payment gateways (PayPal / Stripe offsite redirect returning to receipt), or
-- (c) Telemetry event loss / ad-blocker interference.
-- -------------------------------------------------------------------------------------------------
WITH session_events AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    LOGICAL_OR(event_name = 'view_item') AS has_view_item,
    LOGICAL_OR(event_name = 'add_to_cart') AS has_add_to_cart,
    LOGICAL_OR(event_name = 'begin_checkout') AS has_begin_checkout,
    LOGICAL_OR(event_name = 'add_shipping_info') AS has_add_shipping_info,
    LOGICAL_OR(event_name = 'add_payment_info') AS has_add_payment_info,
    LOGICAL_OR(event_name = 'purchase') AS has_purchase
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name IN (
      'view_item', 'add_to_cart', 'begin_checkout',
      'add_shipping_info', 'add_payment_info', 'purchase'
    )
    AND user_pseudo_id IS NOT NULL
  GROUP BY
    session_key
)
SELECT
  COUNTIF(has_purchase) AS total_purchase_sessions,
  COUNTIF(has_purchase AND NOT has_begin_checkout) AS purchase_without_begin_checkout,
  ROUND(SAFE_DIVIDE(COUNTIF(has_purchase AND NOT has_begin_checkout), COUNTIF(has_purchase)) * 100, 2) AS pct_purchase_without_begin_checkout,
  COUNTIF(has_purchase AND NOT has_add_to_cart) AS purchase_without_add_to_cart,
  ROUND(SAFE_DIVIDE(COUNTIF(has_purchase AND NOT has_add_to_cart), COUNTIF(has_purchase)) * 100, 2) AS pct_purchase_without_add_to_cart,
  COUNTIF(has_purchase AND NOT has_view_item) AS purchase_without_view_item,
  ROUND(SAFE_DIVIDE(COUNTIF(has_purchase AND NOT has_view_item), COUNTIF(has_purchase)) * 100, 2) AS pct_purchase_without_view_item,
  COUNTIF(has_purchase AND has_begin_checkout AND NOT has_add_payment_info) AS purchase_with_checkout_but_no_payment_event,
  ROUND(SAFE_DIVIDE(COUNTIF(has_purchase AND has_begin_checkout AND NOT has_add_payment_info), COUNTIF(has_purchase)) * 100, 2) AS pct_purchase_skipping_payment_event
FROM
  session_events;


-- -------------------------------------------------------------------------------------------------
-- QUERY 1.2: Quality Check - Timestamp Inversion & Out-of-Order Sequences
-- Evaluates whether sessions have events out of natural order (e.g., purchase timestamp earlier
-- than begin_checkout timestamp, or add_to_cart timestamp earlier than view_item timestamp).
-- -------------------------------------------------------------------------------------------------
WITH session_first_timestamps AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    MIN(CASE WHEN event_name = 'view_item' THEN event_timestamp END) AS first_view_ts,
    MIN(CASE WHEN event_name = 'add_to_cart' THEN event_timestamp END) AS first_cart_ts,
    MIN(CASE WHEN event_name = 'begin_checkout' THEN event_timestamp END) AS first_checkout_ts,
    MIN(CASE WHEN event_name = 'purchase' THEN event_timestamp END) AS first_purchase_ts
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name IN ('view_item', 'add_to_cart', 'begin_checkout', 'purchase')
    AND user_pseudo_id IS NOT NULL
  GROUP BY
    session_key
)
SELECT
  COUNT(1) AS total_evaluated_sessions,
  COUNTIF(first_cart_ts IS NOT NULL AND first_view_ts IS NOT NULL AND first_cart_ts < first_view_ts) AS cart_before_view_count,
  COUNTIF(first_checkout_ts IS NOT NULL AND first_cart_ts IS NOT NULL AND first_checkout_ts < first_cart_ts) AS checkout_before_cart_count,
  COUNTIF(first_purchase_ts IS NOT NULL AND first_checkout_ts IS NOT NULL AND first_purchase_ts < first_checkout_ts) AS purchase_before_checkout_count
FROM
  session_first_timestamps;


-- =================================================================================================
-- SECTION 2: SEQUENTIAL FUNNEL MODELING
-- Builds the session-level funnel tracking chronological progression across repeated events.
--
-- Logic for Handling Repeated Events:
-- Rather than taking MIN(event_timestamp) independently for each stage (which can falsely reject
-- a valid sequence if a user added a previous item before viewing the current item), we resolve:
--   t1 = earliest view_item
--   t2 = earliest add_to_cart occurring ON OR AFTER t1
--   t3 = earliest begin_checkout occurring ON OR AFTER t2
--   t4 = earliest add_shipping_info occurring ON OR AFTER t3
--   t5 = earliest add_payment_info occurring ON OR AFTER t4
--   t6 = earliest purchase occurring ON OR AFTER t5
--
-- Additionally, we model the Standard E-commerce Macro Funnel:
--   t1 (view_item) -> t2 (add_to_cart) -> t3 (begin_checkout) -> t_purch (purchase >= t3)
-- This accommodates single-page/stored-credential checkouts where micro-steps (shipping/payment)
-- may be bundled or bypassed in tracking.
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 2.1: Master Session-Level Sequential Funnel Base CTE Table
-- -------------------------------------------------------------------------------------------------
WITH session_events AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    event_name,
    event_timestamp,
    PARSE_DATE('%Y%m%d', event_date) AS event_date,
    device.category AS device_category
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name IN (
      'view_item',
      'add_to_cart',
      'begin_checkout',
      'add_shipping_info',
      'add_payment_info',
      'purchase'
    )
    AND user_pseudo_id IS NOT NULL
),

-- Step 1: Find earliest view_item per session
step1_view AS (
  SELECT
    session_key,
    MIN(event_timestamp) AS t1_view
  FROM
    session_events
  WHERE
    event_name = 'view_item'
  GROUP BY
    session_key
),

-- Step 2: Find earliest add_to_cart occurring on or after t1_view
step2_cart AS (
  SELECT
    e.session_key,
    v.t1_view,
    MIN(e.event_timestamp) AS t2_cart
  FROM
    session_events e
  INNER JOIN
    step1_view v ON e.session_key = v.session_key
  WHERE
    e.event_name = 'add_to_cart'
    AND e.event_timestamp >= v.t1_view
  GROUP BY
    e.session_key,
    v.t1_view
),

-- Step 3: Find earliest begin_checkout occurring on or after t2_cart
step3_checkout AS (
  SELECT
    e.session_key,
    c.t1_view,
    c.t2_cart,
    MIN(e.event_timestamp) AS t3_checkout
  FROM
    session_events e
  INNER JOIN
    step2_cart c ON e.session_key = c.session_key
  WHERE
    e.event_name = 'begin_checkout'
    AND e.event_timestamp >= c.t2_cart
  GROUP BY
    e.session_key,
    c.t1_view,
    c.t2_cart
),

-- Step 4: Find earliest add_shipping_info occurring on or after t3_checkout
step4_shipping AS (
  SELECT
    e.session_key,
    k.t1_view,
    k.t2_cart,
    k.t3_checkout,
    MIN(e.event_timestamp) AS t4_shipping
  FROM
    session_events e
  INNER JOIN
    step3_checkout k ON e.session_key = k.session_key
  WHERE
    e.event_name = 'add_shipping_info'
    AND e.event_timestamp >= k.t3_checkout
  GROUP BY
    e.session_key,
    k.t1_view,
    k.t2_cart,
    k.t3_checkout
),

-- Step 5: Find earliest add_payment_info occurring on or after t4_shipping
step5_payment AS (
  SELECT
    e.session_key,
    s.t1_view,
    s.t2_cart,
    s.t3_checkout,
    s.t4_shipping,
    MIN(e.event_timestamp) AS t5_payment
  FROM
    session_events e
  INNER JOIN
    step4_shipping s ON e.session_key = s.session_key
  WHERE
    e.event_name = 'add_payment_info'
    AND e.event_timestamp >= s.t4_shipping
  GROUP BY
    e.session_key,
    s.t1_view,
    s.t2_cart,
    s.t3_checkout,
    s.t4_shipping
),

-- Step 6: Find earliest purchase occurring on or after t5_payment (Strict 6-Step)
step6_purchase_strict AS (
  SELECT
    e.session_key,
    p.t1_view,
    p.t2_cart,
    p.t3_checkout,
    p.t4_shipping,
    p.t5_payment,
    MIN(e.event_timestamp) AS t6_purchase
  FROM
    session_events e
  INNER JOIN
    step5_payment p ON e.session_key = p.session_key
  WHERE
    e.event_name = 'purchase'
    AND e.event_timestamp >= p.t5_payment
  GROUP BY
    e.session_key,
    p.t1_view,
    p.t2_cart,
    p.t3_checkout,
    p.t4_shipping,
    p.t5_payment
),

-- Also evaluate Macro Funnel Purchase (purchase on or after t3_checkout, allowing payment bypass)
macro_purchase AS (
  SELECT
    e.session_key,
    MIN(e.event_timestamp) AS t_macro_purchase
  FROM
    session_events e
  INNER JOIN
    step3_checkout k ON e.session_key = k.session_key
  WHERE
    e.event_name = 'purchase'
    AND e.event_timestamp >= k.t3_checkout
  GROUP BY
    e.session_key
)

SELECT
  COUNT(DISTINCT v.session_key) AS stage1_view_item_sessions,
  COUNT(DISTINCT c.session_key) AS stage2_add_to_cart_sessions,
  COUNT(DISTINCT k.session_key) AS stage3_begin_checkout_sessions,
  COUNT(DISTINCT s.session_key) AS stage4_shipping_sessions,
  COUNT(DISTINCT p.session_key) AS stage5_payment_sessions,
  COUNT(DISTINCT ps.session_key) AS stage6_strict_purchase_sessions,
  COUNT(DISTINCT mp.session_key) AS stage6_macro_purchase_sessions
FROM
  step1_view v
LEFT JOIN
  step2_cart c ON v.session_key = c.session_key
LEFT JOIN
  step3_checkout k ON c.session_key = k.session_key
LEFT JOIN
  step4_shipping s ON k.session_key = s.session_key
LEFT JOIN
  step5_payment p ON s.session_key = p.session_key
LEFT JOIN
  step6_purchase_strict ps ON p.session_key = ps.session_key
LEFT JOIN
  macro_purchase mp ON k.session_key = mp.session_key;


-- =================================================================================================
-- SECTION 3: STEP-BY-STEP CONVERSION, DROP-OFF & OVERALL METRICS
-- Calculates stage-to-stage conversion rates, drop-offs, and initial-to-stage conversion rates.
-- Unpivots the counts into a standardized table structure for reporting and Power BI.
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 3.1: Strict 6-Stage Sequential Funnel Conversion Table
-- -------------------------------------------------------------------------------------------------
WITH session_events AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    event_name,
    event_timestamp
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name IN (
      'view_item', 'add_to_cart', 'begin_checkout',
      'add_shipping_info', 'add_payment_info', 'purchase'
    )
    AND user_pseudo_id IS NOT NULL
),
step1_view AS (
  SELECT session_key, MIN(event_timestamp) AS t1 FROM session_events WHERE event_name = 'view_item' GROUP BY session_key
),
step2_cart AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t2 FROM session_events e INNER JOIN step1_view v ON e.session_key = v.session_key WHERE e.event_name = 'add_to_cart' AND e.event_timestamp >= v.t1 GROUP BY e.session_key
),
step3_checkout AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t3 FROM session_events e INNER JOIN step2_cart c ON e.session_key = c.session_key WHERE e.event_name = 'begin_checkout' AND e.event_timestamp >= c.t2 GROUP BY e.session_key
),
step4_shipping AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t4 FROM session_events e INNER JOIN step3_checkout k ON e.session_key = k.session_key WHERE e.event_name = 'add_shipping_info' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
),
step5_payment AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t5 FROM session_events e INNER JOIN step4_shipping s ON e.session_key = s.session_key WHERE e.event_name = 'add_payment_info' AND e.event_timestamp >= s.t4 GROUP BY e.session_key
),
step6_purchase AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t6 FROM session_events e INNER JOIN step5_payment p ON e.session_key = p.session_key WHERE e.event_name = 'purchase' AND e.event_timestamp >= p.t5 GROUP BY e.session_key
),
funnel_counts AS (
  SELECT
    (SELECT COUNT(1) FROM step1_view) AS s1_count,
    (SELECT COUNT(1) FROM step2_cart) AS s2_count,
    (SELECT COUNT(1) FROM step3_checkout) AS s3_count,
    (SELECT COUNT(1) FROM step4_shipping) AS s4_count,
    (SELECT COUNT(1) FROM step5_payment) AS s5_count,
    (SELECT COUNT(1) FROM step6_purchase) AS s6_count
),
stages AS (
  SELECT 1 AS stage_number, '1. Product View (view_item)' AS stage_name, s1_count AS sessions_entering, s1_count AS sessions_reaching, s1_count AS top_funnel_sessions FROM funnel_counts
  UNION ALL
  SELECT 2, '2. Add to Cart (add_to_cart)', s1_count, s2_count, s1_count FROM funnel_counts
  UNION ALL
  SELECT 3, '3. Begin Checkout (begin_checkout)', s2_count, s3_count, s1_count FROM funnel_counts
  UNION ALL
  SELECT 4, '4. Add Shipping Info (add_shipping_info)', s3_count, s4_count, s1_count FROM funnel_counts
  UNION ALL
  SELECT 5, '5. Add Payment Info (add_payment_info)', s4_count, s5_count, s1_count FROM funnel_counts
  UNION ALL
  SELECT 6, '6. Purchase Completed (purchase)', s5_count, s6_count, s1_count FROM funnel_counts
)
SELECT
  stage_number,
  stage_name,
  sessions_entering,
  sessions_reaching,
  (sessions_entering - sessions_reaching) AS sessions_dropped_at_stage,
  ROUND(SAFE_DIVIDE(sessions_reaching, sessions_entering) * 100, 2) AS stage_conversion_rate_pct,
  ROUND(SAFE_DIVIDE((sessions_entering - sessions_reaching), sessions_entering) * 100, 2) AS stage_dropoff_rate_pct,
  ROUND(SAFE_DIVIDE(sessions_reaching, top_funnel_sessions) * 100, 2) AS overall_conversion_from_view_pct
FROM
  stages
ORDER BY
  stage_number ASC;


-- =================================================================================================
-- SECTION 4: COMPARATIVE ANALYSIS - EVENT PRESENCE VS. SEQUENTIAL FUNNELS
-- Demonstrates to stakeholders how naive event-presence counts overstate conversion compared to
-- strict and macro sequential progression.
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 4.1: Side-by-Side Model Reconciliation
-- -------------------------------------------------------------------------------------------------
WITH session_events AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    event_name,
    event_timestamp
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name IN (
      'view_item', 'add_to_cart', 'begin_checkout',
      'add_shipping_info', 'add_payment_info', 'purchase'
    )
    AND user_pseudo_id IS NOT NULL
),
-- Event-Presence flags
presence AS (
  SELECT
    COUNT(DISTINCT CASE WHEN event_name = 'view_item' THEN session_key END) AS pres_view,
    COUNT(DISTINCT CASE WHEN event_name = 'add_to_cart' THEN session_key END) AS pres_cart,
    COUNT(DISTINCT CASE WHEN event_name = 'begin_checkout' THEN session_key END) AS pres_checkout,
    COUNT(DISTINCT CASE WHEN event_name = 'add_shipping_info' THEN session_key END) AS pres_shipping,
    COUNT(DISTINCT CASE WHEN event_name = 'add_payment_info' THEN session_key END) AS pres_payment,
    COUNT(DISTINCT CASE WHEN event_name = 'purchase' THEN session_key END) AS pres_purchase
  FROM
    session_events
),
-- Strict Sequential CTEs
s1 AS (SELECT session_key, MIN(event_timestamp) AS t1 FROM session_events WHERE event_name = 'view_item' GROUP BY session_key),
s2 AS (SELECT e.session_key, MIN(e.event_timestamp) AS t2 FROM session_events e INNER JOIN s1 ON e.session_key = s1.session_key WHERE e.event_name = 'add_to_cart' AND e.event_timestamp >= s1.t1 GROUP BY e.session_key),
s3 AS (SELECT e.session_key, MIN(e.event_timestamp) AS t3 FROM session_events e INNER JOIN s2 ON e.session_key = s2.session_key WHERE e.event_name = 'begin_checkout' AND e.event_timestamp >= s2.t2 GROUP BY e.session_key),
s4 AS (SELECT e.session_key, MIN(e.event_timestamp) AS t4 FROM session_events e INNER JOIN s3 ON e.session_key = s3.session_key WHERE e.event_name = 'add_shipping_info' AND e.event_timestamp >= s3.t3 GROUP BY e.session_key),
s5 AS (SELECT e.session_key, MIN(e.event_timestamp) AS t5 FROM session_events e INNER JOIN s4 ON e.session_key = s4.session_key WHERE e.event_name = 'add_payment_info' AND e.event_timestamp >= s4.t4 GROUP BY e.session_key),
s6 AS (SELECT e.session_key, MIN(e.event_timestamp) AS t6 FROM session_events e INNER JOIN s5 ON e.session_key = s5.session_key WHERE e.event_name = 'purchase' AND e.event_timestamp >= s5.t5 GROUP BY e.session_key),
seq_counts AS (
  SELECT
    (SELECT COUNT(1) FROM s1) AS seq_view,
    (SELECT COUNT(1) FROM s2) AS seq_cart,
    (SELECT COUNT(1) FROM s3) AS seq_checkout,
    (SELECT COUNT(1) FROM s4) AS seq_shipping,
    (SELECT COUNT(1) FROM s5) AS seq_payment,
    (SELECT COUNT(1) FROM s6) AS seq_purchase
)
SELECT
  '1. view_item' AS funnel_stage,
  p.pres_view AS event_presence_sessions,
  s.seq_view AS strict_sequential_sessions,
  (p.pres_view - s.seq_view) AS non_sequential_or_prior_dropped_sessions
FROM presence p CROSS JOIN seq_counts s
UNION ALL
SELECT '2. add_to_cart', p.pres_cart, s.seq_cart, (p.pres_cart - s.seq_cart) FROM presence p CROSS JOIN seq_counts s
UNION ALL
SELECT '3. begin_checkout', p.pres_checkout, s.seq_checkout, (p.pres_checkout - s.seq_checkout) FROM presence p CROSS JOIN seq_counts s
UNION ALL
SELECT '4. add_shipping_info', p.pres_shipping, s.seq_shipping, (p.pres_shipping - s.seq_shipping) FROM presence p CROSS JOIN seq_counts s
UNION ALL
SELECT '5. add_payment_info', p.pres_payment, s.seq_payment, (p.pres_payment - s.seq_payment) FROM presence p CROSS JOIN seq_counts s
UNION ALL
SELECT '6. purchase', p.pres_purchase, s.seq_purchase, (p.pres_purchase - s.seq_purchase) FROM presence p CROSS JOIN seq_counts s
ORDER BY funnel_stage;


-- =================================================================================================
-- SECTION 5: COMPACT POWER BI EXPORT TABLE - DAILY FUNNEL METRICS
-- Granular daily breakdown ready for export as CSV to `data/funnel_daily_summary.csv` and
-- subsequent import into Power BI.
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 5.1: Daily Session-Level Funnel Progression Export
-- Grain: event_date x device_category
-- Uses progressive event-matching aligned with Query 3.1 to guarantee exact mathematical additivity.
-- Sessions are attributed to the date and authoritative device category of their initial view_item.
-- -------------------------------------------------------------------------------------------------
WITH session_events AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    PARSE_DATE('%Y%m%d', event_date) AS event_date,
    device.category AS device_category,
    event_name,
    event_timestamp
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name IN (
      'view_item', 'add_to_cart', 'begin_checkout',
      'add_shipping_info', 'add_payment_info', 'purchase'
    )
    AND user_pseudo_id IS NOT NULL
),

-- Attribute each session to its initial date and authoritative device category
session_metadata AS (
  SELECT
    session_key,
    MIN(event_date) AS session_date,
    ARRAY_AGG(device_category ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] AS device_category
  FROM
    session_events
  GROUP BY
    session_key
),

-- Step 1: Find earliest view_item per session
s1_view AS (
  SELECT
    session_key,
    MIN(event_timestamp) AS t1
  FROM
    session_events
  WHERE
    event_name = 'view_item'
  GROUP BY
    session_key
),

-- Step 2: Earliest add_to_cart occurring on or after t1
s2_cart AS (
  SELECT
    e.session_key,
    MIN(e.event_timestamp) AS t2
  FROM
    session_events e
  INNER JOIN
    s1_view v ON e.session_key = v.session_key
  WHERE
    e.event_name = 'add_to_cart'
    AND e.event_timestamp >= v.t1
  GROUP BY
    e.session_key
),

-- Step 3: Earliest begin_checkout occurring on or after t2
s3_checkout AS (
  SELECT
    e.session_key,
    MIN(e.event_timestamp) AS t3
  FROM
    session_events e
  INNER JOIN
    s2_cart c ON e.session_key = c.session_key
  WHERE
    e.event_name = 'begin_checkout'
    AND e.event_timestamp >= c.t2
  GROUP BY
    e.session_key
),

-- Step 4: Earliest add_shipping_info occurring on or after t3
s4_shipping AS (
  SELECT
    e.session_key,
    MIN(e.event_timestamp) AS t4
  FROM
    session_events e
  INNER JOIN
    s3_checkout k ON e.session_key = k.session_key
  WHERE
    e.event_name = 'add_shipping_info'
    AND e.event_timestamp >= k.t3
  GROUP BY
    e.session_key
),

-- Step 5: Earliest add_payment_info occurring on or after t4
s5_payment AS (
  SELECT
    e.session_key,
    MIN(e.event_timestamp) AS t5
  FROM
    session_events e
  INNER JOIN
    s4_shipping s ON e.session_key = s.session_key
  WHERE
    e.event_name = 'add_payment_info'
    AND e.event_timestamp >= s.t4
  GROUP BY
    e.session_key
),

-- Step 6: Earliest purchase occurring on or after t5 (Strict 6-Step)
s6_purchase_strict AS (
  SELECT
    e.session_key,
    MIN(e.event_timestamp) AS t6
  FROM
    session_events e
  INNER JOIN
    s5_payment p ON e.session_key = p.session_key
  WHERE
    e.event_name = 'purchase'
    AND e.event_timestamp >= p.t5
  GROUP BY
    e.session_key
),

-- Macro Funnel: Earliest purchase occurring on or after t3 (Checkout to Purchase Macro)
macro_purchase AS (
  SELECT
    e.session_key,
    MIN(e.event_timestamp) AS t_macro
  FROM
    session_events e
  INNER JOIN
    s3_checkout k ON e.session_key = k.session_key
  WHERE
    e.event_name = 'purchase'
    AND e.event_timestamp >= k.t3
  GROUP BY
    e.session_key
)

SELECT
  m.session_date AS event_date,
  m.device_category,
  COUNT(DISTINCT v.session_key) AS sessions_view_item,
  COUNT(DISTINCT c.session_key) AS sessions_add_to_cart,
  COUNT(DISTINCT k.session_key) AS sessions_begin_checkout,
  COUNT(DISTINCT s.session_key) AS sessions_add_shipping,
  COUNT(DISTINCT p.session_key) AS sessions_add_payment,
  COUNT(DISTINCT ps.session_key) AS sessions_purchase_strict,
  COUNT(DISTINCT mp.session_key) AS sessions_purchase_macro
FROM
  s1_view v
INNER JOIN
  session_metadata m ON v.session_key = m.session_key
LEFT JOIN
  s2_cart c ON v.session_key = c.session_key
LEFT JOIN
  s3_checkout k ON c.session_key = k.session_key
LEFT JOIN
  s4_shipping s ON k.session_key = s.session_key
LEFT JOIN
  s5_payment p ON s.session_key = p.session_key
LEFT JOIN
  s6_purchase_strict ps ON p.session_key = ps.session_key
LEFT JOIN
  macro_purchase mp ON k.session_key = mp.session_key
GROUP BY
  event_date,
  device_category
ORDER BY
  event_date ASC,
  device_category ASC;
