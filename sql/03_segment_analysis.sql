-- =================================================================================================
-- PROJECT: CheckoutLens - E-commerce Checkout Abandonment & Funnel Analytics
-- SCRIPT: 03_segment_analysis.sql
-- PURPOSE: Multi-Dimensional Segmentation (Device, Traffic Source, Country, Landing Page,
--          Time of Day, Product Category), Quality Validations & Revenue Opportunity Sizing.
--
-- DATASET: `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
-- DATE RANGE: 2020-11-01 to 2021-01-31 (92 daily partitioned tables)
--
-- METHODOLOGICAL CONSTRAINTS & PRINCIPLES:
-- 1. Uniform Funnel Definition: All segment analyses use the validated 6-stage progressive
--    successor timestamp logic from `sql/02_funnel_analysis.sql` Query 3.1.
-- 2. Deterministic Session Attribution: Each session is mapped to exactly one authoritative
--    segment attribute (via earliest event timestamp) to guarantee 100% mathematical reconciliation
--    when summing across segments (Sum of Segments = Global Funnel Counts).
-- 3. Strict Join Architecture: Base query begins from `s1_view` with sequential `LEFT JOIN`s for
--    subsequent funnel stages. Abandoning sessions are never dropped prematurely.
-- 4. Attribution Distinction: Distinguishes First-User acquisition source from session attribution.
-- 5. Statistical Governance: Low sample sizes are explicitly flagged to prevent spurious claims.
-- =================================================================================================


-- =================================================================================================
-- SECTION 1: DEVICE CATEGORY SEGMENTATION
-- Evaluates checkout funnel drop-offs across Desktop, Mobile, and Tablet.
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 1.0: Diagnostic QA - Conflicting Device Categories per Session
-- Verifies whether any session key is associated with more than one distinct device category.
-- -------------------------------------------------------------------------------------------------
WITH session_device_counts AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    COUNT(DISTINCT device.category) AS distinct_device_categories,
    ARRAY_AGG(DISTINCT device.category) AS conflicting_categories
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
  COUNT(1) AS total_funnel_sessions,
  COUNTIF(distinct_device_categories = 1) AS single_device_sessions,
  COUNTIF(distinct_device_categories > 1) AS conflicting_device_sessions,
  ROUND(SAFE_DIVIDE(COUNTIF(distinct_device_categories > 1), COUNT(1)) * 100, 4) AS pct_conflicting_sessions
FROM
  session_device_counts;


-- -------------------------------------------------------------------------------------------------
-- QUERY 1.1: Device Funnel Progression & Step Drop-off Comparison
-- Evaluates step-level progression for sessions entering through view_item.
-- Reconciles exactly with Global Funnel (Checkout = 5,416; Shipping = 3,119).
-- -------------------------------------------------------------------------------------------------
WITH session_events AS (
  SELECT
    device.category AS device_category,
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

-- Assign one authoritative device category per session (earliest event timestamp)
session_authoritative_device AS (
  SELECT
    session_key,
    ARRAY_AGG(device_category ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] AS device_category
  FROM
    session_events
  GROUP BY
    session_key
),

-- Step 1: Earliest view_item
s1_view AS (
  SELECT session_key, MIN(event_timestamp) AS t1 
  FROM session_events WHERE event_name = 'view_item' GROUP BY session_key
),

-- Step 2: Earliest add_to_cart on or after t1
s2_cart AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t2 
  FROM session_events e INNER JOIN s1_view v ON e.session_key = v.session_key 
  WHERE e.event_name = 'add_to_cart' AND e.event_timestamp >= v.t1 GROUP BY e.session_key
),

-- Step 3: Earliest begin_checkout on or after t2
s3_checkout AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t3 
  FROM session_events e INNER JOIN s2_cart c ON e.session_key = c.session_key 
  WHERE e.event_name = 'begin_checkout' AND e.event_timestamp >= c.t2 GROUP BY e.session_key
),

-- Step 4: Earliest add_shipping_info on or after t3
s4_shipping AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t4 
  FROM session_events e INNER JOIN s3_checkout k ON e.session_key = k.session_key 
  WHERE e.event_name = 'add_shipping_info' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
),

-- Step 5: Earliest add_payment_info on or after t4
s5_payment AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t5 
  FROM session_events e INNER JOIN s4_shipping s ON e.session_key = s.session_key 
  WHERE e.event_name = 'add_payment_info' AND e.event_timestamp >= s.t4 GROUP BY e.session_key
),

-- Step 6: Earliest purchase on or after t5 (Strict 6-Step)
s6_purchase_strict AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t6 
  FROM session_events e INNER JOIN s5_payment p ON e.session_key = p.session_key 
  WHERE e.event_name = 'purchase' AND e.event_timestamp >= p.t5 GROUP BY e.session_key
),

-- Macro Funnel: Earliest purchase on or after t3 (Allowing intermediate step bypass)
macro_purchase AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t_macro 
  FROM session_events e INNER JOIN s3_checkout k ON e.session_key = k.session_key 
  WHERE e.event_name = 'purchase' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
)

SELECT
  d.device_category,
  COUNT(DISTINCT v.session_key) AS sessions_view_item,
  COUNT(DISTINCT c.session_key) AS sessions_add_to_cart,
  COUNT(DISTINCT k.session_key) AS sessions_begin_checkout,
  COUNT(DISTINCT s.session_key) AS sessions_add_shipping,
  COUNT(DISTINCT p.session_key) AS sessions_add_payment,
  COUNT(DISTINCT ps.session_key) AS sessions_purchase_strict,
  COUNT(DISTINCT mp.session_key) AS sessions_purchase_macro,
  -- Step-by-Step Conversion Rates (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT c.session_key), COUNT(DISTINCT v.session_key)) * 100, 2) AS view_to_cart_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT k.session_key), COUNT(DISTINCT c.session_key)) * 100, 2) AS cart_to_checkout_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT s.session_key), COUNT(DISTINCT k.session_key)) * 100, 2) AS checkout_to_shipping_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT p.session_key), COUNT(DISTINCT s.session_key)) * 100, 2) AS shipping_to_payment_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT ps.session_key), COUNT(DISTINCT p.session_key)) * 100, 2) AS payment_to_purchase_cr_pct,
  -- Macro Checkout-to-Purchase Completion Rate (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT mp.session_key), COUNT(DISTINCT k.session_key)) * 100, 2) AS macro_checkout_to_purchase_cr_pct,
  -- Overall Conversion from Product View (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT ps.session_key), COUNT(DISTINCT v.session_key)) * 100, 2) AS overall_strict_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT mp.session_key), COUNT(DISTINCT v.session_key)) * 100, 2) AS overall_macro_cr_pct,
  -- Sample Size Reliability Indicator
  CASE
    WHEN COUNT(DISTINCT k.session_key) < 500 THEN 'LOW SAMPLE - Interpret with caution'
    ELSE 'ROBUST SAMPLE'
  END AS sample_size_status
FROM
  s1_view v
INNER JOIN
  session_authoritative_device d ON v.session_key = d.session_key
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
  d.device_category
ORDER BY
  sessions_view_item DESC;


-- =================================================================================================
-- SECTION 2: TRAFFIC-SOURCE & ACQUISITION CHANNEL ANALYSIS
-- Analyzes funnel conversion variations across traffic channels and acquisition sources.
--
-- METHODOLOGY & ATTRIBUTION LIMITATIONS:
-- 1. Attribution Scope: In this historical GA4 export schema, the record-level fields
--    `traffic_source.source`, `traffic_source.medium`, and `traffic_source.name` represent
--    FIRST-USER ACQUISITION attribution (the channel that originally acquired the user), NOT
--    session-level dynamic re-attribution. In this dataset, session-level `collected_traffic_source`
--    is absent and event-level campaign parameters are not recorded.
-- 2. Categorization: We group sources and media into industry-standard Default Channel Groups:
--    - Organic Search: medium = 'organic'
--    - Direct: (direct) / (not set) / none
--    - Referral: medium = 'referral'
--    - Paid Search (cpc): medium IN ('cpc', 'ppc', 'paidsearch')
--    - Affiliates: medium = 'affiliates'
--    - Email: medium = 'email'
--    - Other / Unknown: all remaining unmapped sources
-- 3. Unknown Bucket: Missing or empty values are explicitly mapped to 'Unknown / Not Set'.
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 2.0: Diagnostic QA - Conflicting Traffic Source Metadata per Session
-- Verifies whether session keys map to a single user acquisition source or multiple sources.
-- -------------------------------------------------------------------------------------------------
WITH session_traffic_counts AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    COUNT(DISTINCT CONCAT(COALESCE(traffic_source.source, 'null'), '/', COALESCE(traffic_source.medium, 'null'))) AS distinct_traffic_pairs
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
  COUNT(1) AS total_funnel_sessions,
  COUNTIF(distinct_traffic_pairs = 1) AS single_source_sessions,
  COUNTIF(distinct_traffic_pairs > 1) AS conflicting_source_sessions,
  ROUND(SAFE_DIVIDE(COUNTIF(distinct_traffic_pairs > 1), COUNT(1)) * 100, 4) AS pct_conflicting_sessions
FROM
  session_traffic_counts;


-- -------------------------------------------------------------------------------------------------
-- QUERY 2.1: Traffic-Source & Channel Funnel Performance
-- Evaluates step-by-step conversion across acquisition channels.
-- Reconciles exactly with Global Funnel counts.
-- -------------------------------------------------------------------------------------------------
WITH session_events AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    COALESCE(NULLIF(traffic_source.source, ''), '(not set)') AS raw_source,
    COALESCE(NULLIF(traffic_source.medium, ''), '(not set)') AS raw_medium,
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

-- Assign one authoritative channel and source per session (from earliest interaction)
session_authoritative_traffic AS (
  SELECT
    session_key,
    ARRAY_AGG(
      STRUCT(
        CASE
          WHEN raw_medium = 'organic' THEN 'Organic Search'
          WHEN raw_source = '(direct)' OR raw_medium IN ('(none)', '(not set)') THEN 'Direct'
          WHEN raw_medium = 'referral' THEN 'Referral'
          WHEN raw_medium IN ('cpc', 'ppc', 'paidsearch') THEN 'Paid Search'
          WHEN raw_medium = 'affiliates' THEN 'Affiliates'
          WHEN raw_medium = 'email' THEN 'Email'
          WHEN raw_source = '(not set)' AND raw_medium = '(not set)' THEN 'Unknown / Not Set'
          ELSE 'Other'
        END AS default_channel_group,
        raw_source AS source,
        raw_medium AS medium
      )
      ORDER BY event_timestamp ASC
      LIMIT 1
    )[OFFSET(0)] AS traffic_meta
  FROM
    session_events
  GROUP BY
    session_key
),

-- Progressive Funnel Steps
s1_view AS (
  SELECT session_key, MIN(event_timestamp) AS t1 
  FROM session_events WHERE event_name = 'view_item' GROUP BY session_key
),
s2_cart AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t2 
  FROM session_events e INNER JOIN s1_view v ON e.session_key = v.session_key 
  WHERE e.event_name = 'add_to_cart' AND e.event_timestamp >= v.t1 GROUP BY e.session_key
),
s3_checkout AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t3 
  FROM session_events e INNER JOIN s2_cart c ON e.session_key = c.session_key 
  WHERE e.event_name = 'begin_checkout' AND e.event_timestamp >= c.t2 GROUP BY e.session_key
),
s4_shipping AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t4 
  FROM session_events e INNER JOIN s3_checkout k ON e.session_key = k.session_key 
  WHERE e.event_name = 'add_shipping_info' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
),
s5_payment AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t5 
  FROM session_events e INNER JOIN s4_shipping s ON e.session_key = s.session_key 
  WHERE e.event_name = 'add_payment_info' AND e.event_timestamp >= s.t4 GROUP BY e.session_key
),
s6_purchase_strict AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t6 
  FROM session_events e INNER JOIN s5_payment p ON e.session_key = p.session_key 
  WHERE e.event_name = 'purchase' AND e.event_timestamp >= p.t5 GROUP BY e.session_key
),
macro_purchase AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t_macro 
  FROM session_events e INNER JOIN s3_checkout k ON e.session_key = k.session_key 
  WHERE e.event_name = 'purchase' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
)

SELECT
  t.traffic_meta.default_channel_group AS channel_group,
  COUNT(DISTINCT v.session_key) AS sessions_view_item,
  COUNT(DISTINCT c.session_key) AS sessions_add_to_cart,
  COUNT(DISTINCT k.session_key) AS sessions_begin_checkout,
  COUNT(DISTINCT s.session_key) AS sessions_add_shipping,
  COUNT(DISTINCT p.session_key) AS sessions_add_payment,
  COUNT(DISTINCT ps.session_key) AS sessions_purchase_strict,
  COUNT(DISTINCT mp.session_key) AS sessions_purchase_macro,
  -- Step-by-Step Conversion Rates (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT c.session_key), COUNT(DISTINCT v.session_key)) * 100, 2) AS view_to_cart_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT k.session_key), COUNT(DISTINCT c.session_key)) * 100, 2) AS cart_to_checkout_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT s.session_key), COUNT(DISTINCT k.session_key)) * 100, 2) AS checkout_to_shipping_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT p.session_key), COUNT(DISTINCT s.session_key)) * 100, 2) AS shipping_to_payment_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT ps.session_key), COUNT(DISTINCT p.session_key)) * 100, 2) AS payment_to_purchase_cr_pct,
  -- Macro Checkout-to-Purchase Completion Rate (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT mp.session_key), COUNT(DISTINCT k.session_key)) * 100, 2) AS macro_checkout_to_purchase_cr_pct,
  -- Overall Conversion from Product View (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT ps.session_key), COUNT(DISTINCT v.session_key)) * 100, 2) AS overall_strict_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT mp.session_key), COUNT(DISTINCT v.session_key)) * 100, 2) AS overall_macro_cr_pct,
  -- Sample Size Reliability Indicator
  CASE
    WHEN COUNT(DISTINCT k.session_key) < 200 THEN 'LOW SAMPLE - Interpret with caution'
    ELSE 'ROBUST SAMPLE'
  END AS sample_size_status
FROM
  s1_view v
INNER JOIN
  session_authoritative_traffic t ON v.session_key = t.session_key
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
  channel_group
ORDER BY
  sessions_view_item DESC;


-- =================================================================================================
-- SECTION 3: COUNTRY & GEOGRAPHIC FUNNEL ANALYSIS
-- Analyzes international vs. domestic checkout abandonment using `geo.country`.
--
-- METHODOLOGY & STATISTICAL GOVERNANCE:
-- 1. Deterministic Attribution: Each session is mapped to the country recorded at its earliest event.
-- 2. Missing Value Governance: Missing or `(not set)` values are placed in an 'Unknown / Not Set' bucket.
-- 3. Small-Sample Protection: Countries with tiny sample sizes (e.g., < 100 checkout sessions) are
--    flagged to prevent misleading comparisons (e.g. 1 checkout and 1 purchase = 100% conversion).
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 3.0: Diagnostic QA - Conflicting Country Metadata per Session
-- Verifies whether session keys map to a single geographic country or switch countries mid-session.
-- -------------------------------------------------------------------------------------------------
WITH session_country_counts AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    COUNT(DISTINCT geo.country) AS distinct_countries
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
  COUNT(1) AS total_funnel_sessions,
  COUNTIF(distinct_countries = 1) AS single_country_sessions,
  COUNTIF(distinct_countries > 1) AS conflicting_country_sessions,
  ROUND(SAFE_DIVIDE(COUNTIF(distinct_countries > 1), COUNT(1)) * 100, 4) AS pct_conflicting_sessions
FROM
  session_country_counts;


-- -------------------------------------------------------------------------------------------------
-- QUERY 3.1: Geographic Country Funnel Analysis
-- Evaluates step-by-step conversion across top countries.
-- Reconciles exactly with Global Funnel counts.
-- -------------------------------------------------------------------------------------------------
WITH session_events AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    COALESCE(NULLIF(geo.country, ''), '(not set)') AS raw_country,
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

-- Assign one authoritative country per session (earliest event timestamp)
session_authoritative_country AS (
  SELECT
    session_key,
    CASE
      WHEN ARRAY_AGG(raw_country ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] = '(not set)'
        THEN 'Unknown / Not Set'
      ELSE ARRAY_AGG(raw_country ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)]
    END AS country
  FROM
    session_events
  GROUP BY
    session_key
),

-- Progressive Funnel Steps
s1_view AS (
  SELECT session_key, MIN(event_timestamp) AS t1 
  FROM session_events WHERE event_name = 'view_item' GROUP BY session_key
),
s2_cart AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t2 
  FROM session_events e INNER JOIN s1_view v ON e.session_key = v.session_key 
  WHERE e.event_name = 'add_to_cart' AND e.event_timestamp >= v.t1 GROUP BY e.session_key
),
s3_checkout AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t3 
  FROM session_events e INNER JOIN s2_cart c ON e.session_key = c.session_key 
  WHERE e.event_name = 'begin_checkout' AND e.event_timestamp >= c.t2 GROUP BY e.session_key
),
s4_shipping AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t4 
  FROM session_events e INNER JOIN s3_checkout k ON e.session_key = k.session_key 
  WHERE e.event_name = 'add_shipping_info' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
),
s5_payment AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t5 
  FROM session_events e INNER JOIN s4_shipping s ON e.session_key = s.session_key 
  WHERE e.event_name = 'add_payment_info' AND e.event_timestamp >= s.t4 GROUP BY e.session_key
),
s6_purchase_strict AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t6 
  FROM session_events e INNER JOIN s5_payment p ON e.session_key = p.session_key 
  WHERE e.event_name = 'purchase' AND e.event_timestamp >= p.t5 GROUP BY e.session_key
),
macro_purchase AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t_macro 
  FROM session_events e INNER JOIN s3_checkout k ON e.session_key = k.session_key 
  WHERE e.event_name = 'purchase' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
)

SELECT
  geo.country,
  COUNT(DISTINCT v.session_key) AS sessions_view_item,
  COUNT(DISTINCT c.session_key) AS sessions_add_to_cart,
  COUNT(DISTINCT k.session_key) AS sessions_begin_checkout,
  COUNT(DISTINCT s.session_key) AS sessions_add_shipping,
  COUNT(DISTINCT p.session_key) AS sessions_add_payment,
  COUNT(DISTINCT ps.session_key) AS sessions_purchase_strict,
  COUNT(DISTINCT mp.session_key) AS sessions_purchase_macro,
  -- Step-by-Step Conversion Rates (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT c.session_key), COUNT(DISTINCT v.session_key)) * 100, 2) AS view_to_cart_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT k.session_key), COUNT(DISTINCT c.session_key)) * 100, 2) AS cart_to_checkout_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT s.session_key), COUNT(DISTINCT k.session_key)) * 100, 2) AS checkout_to_shipping_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT p.session_key), COUNT(DISTINCT s.session_key)) * 100, 2) AS shipping_to_payment_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT ps.session_key), COUNT(DISTINCT p.session_key)) * 100, 2) AS payment_to_purchase_cr_pct,
  -- Macro Checkout-to-Purchase Completion Rate (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT mp.session_key), COUNT(DISTINCT k.session_key)) * 100, 2) AS macro_checkout_to_purchase_cr_pct,
  -- Overall Conversion from Product View (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT ps.session_key), COUNT(DISTINCT v.session_key)) * 100, 2) AS overall_strict_cr_pct,
  -- Overall Conversion from Product View Macro (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT mp.session_key), COUNT(DISTINCT v.session_key)) * 100, 2) AS overall_macro_cr_pct,
  -- Sample Size Reliability Indicator
  CASE
    WHEN COUNT(DISTINCT k.session_key) >= 500 THEN 'ROBUST SAMPLE (>= 500 Checkouts)'
    WHEN COUNT(DISTINCT k.session_key) BETWEEN 100 AND 499 THEN 'MODERATE SAMPLE (100 - 499 Checkouts)'
    ELSE 'LOW SAMPLE (< 100 Checkouts - Caution)'
  END AS sample_size_status
FROM
  s1_view v
INNER JOIN
  session_authoritative_country geo ON v.session_key = geo.session_key
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
  geo.country
ORDER BY
  sessions_view_item DESC;


-- -------------------------------------------------------------------------------------------------
-- QUERY 3.2: Standalone Reconciliation QA - Country Aggregation vs Global Funnel Benchmark
-- Returns exactly one row containing the sum of all country-level funnel counts and comparing
-- against the validated global baseline (77,020 -> 15,167 -> 5,416 -> 3,119 -> 2,438 -> 1,792).
-- Evaluates expected vs. actual counts and match/mismatch status across all segment rows.
-- -------------------------------------------------------------------------------------------------
WITH session_events AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    COALESCE(NULLIF(geo.country, ''), '(not set)') AS raw_country,
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
session_authoritative_country AS (
  SELECT
    session_key,
    CASE
      WHEN ARRAY_AGG(raw_country ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] = '(not set)'
        THEN 'Unknown / Not Set'
      ELSE ARRAY_AGG(raw_country ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)]
    END AS country
  FROM
    session_events
  GROUP BY
    session_key
),
s1_view AS (
  SELECT session_key, MIN(event_timestamp) AS t1 
  FROM session_events WHERE event_name = 'view_item' GROUP BY session_key
),
s2_cart AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t2 
  FROM session_events e INNER JOIN s1_view v ON e.session_key = v.session_key 
  WHERE e.event_name = 'add_to_cart' AND e.event_timestamp >= v.t1 GROUP BY e.session_key
),
s3_checkout AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t3 
  FROM session_events e INNER JOIN s2_cart c ON e.session_key = c.session_key 
  WHERE e.event_name = 'begin_checkout' AND e.event_timestamp >= c.t2 GROUP BY e.session_key
),
s4_shipping AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t4 
  FROM session_events e INNER JOIN s3_checkout k ON e.session_key = k.session_key 
  WHERE e.event_name = 'add_shipping_info' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
),
s5_payment AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t5 
  FROM session_events e INNER JOIN s4_shipping s ON e.session_key = s.session_key 
  WHERE e.event_name = 'add_payment_info' AND e.event_timestamp >= s.t4 GROUP BY e.session_key
),
s6_purchase_strict AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t6 
  FROM session_events e INNER JOIN s5_payment p ON e.session_key = p.session_key 
  WHERE e.event_name = 'purchase' AND e.event_timestamp >= p.t5 GROUP BY e.session_key
),
macro_purchase AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t_macro 
  FROM session_events e INNER JOIN s3_checkout k ON e.session_key = k.session_key 
  WHERE e.event_name = 'purchase' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
),
country_segment_counts AS (
  SELECT
    geo.country,
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
    session_authoritative_country geo ON v.session_key = geo.session_key
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
    geo.country
)
SELECT
  'Country (Query 3.1) Sum' AS segmentation_type,
  -- Stage 1: Product View
  SUM(sessions_view_item) AS actual_view_item,
  77020 AS expected_view_item,
  CASE WHEN SUM(sessions_view_item) = 77020 THEN 'MATCH' ELSE 'MISMATCH' END AS status_view_item,
  -- Stage 2: Add to Cart
  SUM(sessions_add_to_cart) AS actual_add_to_cart,
  15167 AS expected_add_to_cart,
  CASE WHEN SUM(sessions_add_to_cart) = 15167 THEN 'MATCH' ELSE 'MISMATCH' END AS status_add_to_cart,
  -- Stage 3: Begin Checkout
  SUM(sessions_begin_checkout) AS actual_begin_checkout,
  5416 AS expected_begin_checkout,
  CASE WHEN SUM(sessions_begin_checkout) = 5416 THEN 'MATCH' ELSE 'MISMATCH' END AS status_begin_checkout,
  -- Stage 4: Add Shipping Info
  SUM(sessions_add_shipping) AS actual_add_shipping,
  3119 AS expected_add_shipping,
  CASE WHEN SUM(sessions_add_shipping) = 3119 THEN 'MATCH' ELSE 'MISMATCH' END AS status_add_shipping,
  -- Stage 5: Add Payment Info
  SUM(sessions_add_payment) AS actual_add_payment,
  2438 AS expected_add_payment,
  CASE WHEN SUM(sessions_add_payment) = 2438 THEN 'MATCH' ELSE 'MISMATCH' END AS status_add_payment,
  -- Stage 6: Strict Purchase
  SUM(sessions_purchase_strict) AS actual_purchase_strict,
  1792 AS expected_purchase_strict,
  CASE WHEN SUM(sessions_purchase_strict) = 1792 THEN 'MATCH' ELSE 'MISMATCH' END AS status_purchase_strict,
  -- Macro Purchase
  SUM(sessions_purchase_macro) AS actual_purchase_macro
FROM
  country_segment_counts;


-- =================================================================================================
-- SECTION 4: LANDING-PAGE FUNNEL ANALYSIS
-- Analyzes funnel conversion variations according to the entry page of the user session.
--
-- METHODOLOGY & NORMALIZATION RULES:
-- 1. Landing Page Definition: The URL of the CHRONOLOGICALLY FIRST `page_view` event in the session,
--    extracted from `event_params` where `key = 'page_location'`.
-- 2. Strict Semantic Rule: Does NOT use `view_item` URL as a substitute for landing page.
-- 3. URL Normalization:
--    - Strips query parameters (e.g. `?utm_source=...`) and hash fragments (`#...`).
--    - Extracts normalized URI path (e.g. `/home`, `/basket.html`, `/google+redesign/...`).
-- 4. Unknown Bucket: Sessions where no preceding `page_view` was tracked are bucketed as
--    'Unknown / No Initial page_view Recorded'.
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 4.0: Diagnostic QA - Landing Page Detection & Coverage
-- Audits the proportion of sessions that have a recorded `page_view` with a non-null `page_location`.
-- -------------------------------------------------------------------------------------------------
WITH pageview_events AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    event_timestamp,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'page_view'
    AND user_pseudo_id IS NOT NULL
),
session_landing_check AS (
  SELECT
    session_key,
    COUNT(1) AS page_view_count,
    COUNTIF(page_location IS NOT NULL AND page_location != '') AS valid_location_count
  FROM
    pageview_events
  GROUP BY
    session_key
)
SELECT
  COUNT(1) AS total_sessions_with_pageviews,
  COUNTIF(valid_location_count > 0) AS sessions_with_valid_landing_page,
  COUNTIF(valid_location_count = 0) AS sessions_with_missing_landing_page,
  ROUND(SAFE_DIVIDE(COUNTIF(valid_location_count > 0), COUNT(1)) * 100, 2) AS landing_page_capture_rate_pct
FROM
  session_landing_check;


-- -------------------------------------------------------------------------------------------------
-- QUERY 4.1: Landing-Page Funnel Progression & Conversion
-- Evaluates step-by-step conversion across primary site entry paths.
-- Reconciles exactly with Global Funnel counts.
-- -------------------------------------------------------------------------------------------------
WITH funnel_events AS (
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

-- Extract the chronologically first page_view per session to define the true landing page
first_pageviews AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS raw_url,
    event_timestamp
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'page_view'
    AND user_pseudo_id IS NOT NULL
),

-- Normalize URL: strip query parameters, strip fragments, extract clean path
session_landing_pages AS (
  SELECT
    session_key,
    ARRAY_AGG(
      CASE
        WHEN raw_url IS NULL OR raw_url = '' THEN 'Unknown / Not Set'
        ELSE
          COALESCE(
            -- Extract path portion: https://domain.com/path -> /path
            REGEXP_EXTRACT(
              -- Strip query string (?...) and hash fragment (#...)
              REGEXP_REPLACE(REGEXP_REPLACE(raw_url, r'\?.*$', ''), r'#.*$', ''),
              r'https?://[^/]+(/.*)'
            ),
            '/'
          )
      END
      ORDER BY event_timestamp ASC
      LIMIT 1
    )[OFFSET(0)] AS landing_page_path
  FROM
    first_pageviews
  GROUP BY
    session_key
),

-- Combine all funnel sessions with their landing page (defaulting to Unknown if page_view absent)
session_authoritative_landing AS (
  SELECT
    e.session_key,
    COALESCE(l.landing_page_path, 'Unknown / No Initial page_view Recorded') AS landing_page_path
  FROM
    (SELECT DISTINCT session_key FROM funnel_events) e
  LEFT JOIN
    session_landing_pages l ON e.session_key = l.session_key
),

-- Progressive Funnel Steps
s1_view AS (
  SELECT session_key, MIN(event_timestamp) AS t1 
  FROM funnel_events WHERE event_name = 'view_item' GROUP BY session_key
),
s2_cart AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t2 
  FROM funnel_events e INNER JOIN s1_view v ON e.session_key = v.session_key 
  WHERE e.event_name = 'add_to_cart' AND e.event_timestamp >= v.t1 GROUP BY e.session_key
),
s3_checkout AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t3 
  FROM funnel_events e INNER JOIN s2_cart c ON e.session_key = c.session_key 
  WHERE e.event_name = 'begin_checkout' AND e.event_timestamp >= c.t2 GROUP BY e.session_key
),
s4_shipping AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t4 
  FROM funnel_events e INNER JOIN s3_checkout k ON e.session_key = k.session_key 
  WHERE e.event_name = 'add_shipping_info' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
),
s5_payment AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t5 
  FROM funnel_events e INNER JOIN s4_shipping s ON e.session_key = s.session_key 
  WHERE e.event_name = 'add_payment_info' AND e.event_timestamp >= s.t4 GROUP BY e.session_key
),
s6_purchase_strict AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t6 
  FROM funnel_events e INNER JOIN s5_payment p ON e.session_key = p.session_key 
  WHERE e.event_name = 'purchase' AND e.event_timestamp >= p.t5 GROUP BY e.session_key
),
macro_purchase AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t_macro 
  FROM funnel_events e INNER JOIN s3_checkout k ON e.session_key = k.session_key 
  WHERE e.event_name = 'purchase' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
)

SELECT
  l.landing_page_path,
  COUNT(DISTINCT v.session_key) AS sessions_view_item,
  COUNT(DISTINCT c.session_key) AS sessions_add_to_cart,
  COUNT(DISTINCT k.session_key) AS sessions_begin_checkout,
  COUNT(DISTINCT s.session_key) AS sessions_add_shipping,
  COUNT(DISTINCT p.session_key) AS sessions_add_payment,
  COUNT(DISTINCT ps.session_key) AS sessions_purchase_strict,
  COUNT(DISTINCT mp.session_key) AS sessions_purchase_macro,
  -- Step-by-Step Conversion Rates (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT c.session_key), COUNT(DISTINCT v.session_key)) * 100, 2) AS view_to_cart_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT k.session_key), COUNT(DISTINCT c.session_key)) * 100, 2) AS cart_to_checkout_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT s.session_key), COUNT(DISTINCT k.session_key)) * 100, 2) AS checkout_to_shipping_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT p.session_key), COUNT(DISTINCT s.session_key)) * 100, 2) AS shipping_to_payment_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT ps.session_key), COUNT(DISTINCT p.session_key)) * 100, 2) AS payment_to_purchase_cr_pct,
  -- Macro Checkout-to-Purchase Completion Rate (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT mp.session_key), COUNT(DISTINCT k.session_key)) * 100, 2) AS macro_checkout_to_purchase_cr_pct,
  -- Overall Conversion from Product View (%)
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT ps.session_key), COUNT(DISTINCT v.session_key)) * 100, 2) AS overall_strict_cr_pct,
  ROUND(SAFE_DIVIDE(COUNT(DISTINCT mp.session_key), COUNT(DISTINCT v.session_key)) * 100, 2) AS overall_macro_cr_pct,
  -- Sample Size Reliability Indicator
  CASE
    WHEN COUNT(DISTINCT k.session_key) < 50 THEN 'LOW SAMPLE - Interpret with caution'
    ELSE 'ROBUST SAMPLE'
  END AS sample_size_status
FROM
  s1_view v
INNER JOIN
  session_authoritative_landing l ON v.session_key = l.session_key
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
  landing_page_path
ORDER BY
  sessions_view_item DESC;


-- -------------------------------------------------------------------------------------------------
-- QUERY 4.2: Standalone Reconciliation QA - Landing-Page Aggregation vs Global Funnel Benchmark
-- Returns exactly one row containing the sum of all landing-page funnel counts and comparing
-- against the validated global baseline (77,020 -> 15,167 -> 5,416 -> 3,119 -> 2,438 -> 1,792).
-- Evaluates expected vs. actual counts and match/mismatch status across all segment rows.
-- -------------------------------------------------------------------------------------------------
WITH funnel_events AS (
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
first_pageviews AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS raw_url,
    event_timestamp
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'page_view'
    AND user_pseudo_id IS NOT NULL
),
session_landing_pages AS (
  SELECT
    session_key,
    ARRAY_AGG(
      CASE
        WHEN raw_url IS NULL OR raw_url = '' THEN 'Unknown / Not Set'
        ELSE
          COALESCE(
            REGEXP_EXTRACT(
              REGEXP_REPLACE(REGEXP_REPLACE(raw_url, r'\?.*$', ''), r'#.*$', ''),
              r'https?://[^/]+(/.*)'
            ),
            '/'
          )
      END
      ORDER BY event_timestamp ASC
      LIMIT 1
    )[OFFSET(0)] AS landing_page_path
  FROM
    first_pageviews
  GROUP BY
    session_key
),
session_authoritative_landing AS (
  SELECT
    e.session_key,
    COALESCE(l.landing_page_path, 'Unknown / No Initial page_view Recorded') AS landing_page_path
  FROM
    (SELECT DISTINCT session_key FROM funnel_events) e
  LEFT JOIN
    session_landing_pages l ON e.session_key = l.session_key
),
s1_view AS (
  SELECT session_key, MIN(event_timestamp) AS t1 
  FROM funnel_events WHERE event_name = 'view_item' GROUP BY session_key
),
s2_cart AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t2 
  FROM funnel_events e INNER JOIN s1_view v ON e.session_key = v.session_key 
  WHERE e.event_name = 'add_to_cart' AND e.event_timestamp >= v.t1 GROUP BY e.session_key
),
s3_checkout AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t3 
  FROM funnel_events e INNER JOIN s2_cart c ON e.session_key = c.session_key 
  WHERE e.event_name = 'begin_checkout' AND e.event_timestamp >= c.t2 GROUP BY e.session_key
),
s4_shipping AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t4 
  FROM funnel_events e INNER JOIN s3_checkout k ON e.session_key = k.session_key 
  WHERE e.event_name = 'add_shipping_info' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
),
s5_payment AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t5 
  FROM funnel_events e INNER JOIN s4_shipping s ON e.session_key = s.session_key 
  WHERE e.event_name = 'add_payment_info' AND e.event_timestamp >= s.t4 GROUP BY e.session_key
),
s6_purchase_strict AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t6 
  FROM funnel_events e INNER JOIN s5_payment p ON e.session_key = p.session_key 
  WHERE e.event_name = 'purchase' AND e.event_timestamp >= p.t5 GROUP BY e.session_key
),
macro_purchase AS (
  SELECT e.session_key, MIN(e.event_timestamp) AS t_macro 
  FROM funnel_events e INNER JOIN s3_checkout k ON e.session_key = k.session_key 
  WHERE e.event_name = 'purchase' AND e.event_timestamp >= k.t3 GROUP BY e.session_key
),
landing_segment_counts AS (
  SELECT
    l.landing_page_path,
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
    session_authoritative_landing l ON v.session_key = l.session_key
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
    landing_page_path
)
SELECT
  'Landing Page (Query 4.1) Sum' AS segmentation_type,
  -- Stage 1: Product View
  SUM(sessions_view_item) AS actual_view_item,
  77020 AS expected_view_item,
  CASE WHEN SUM(sessions_view_item) = 77020 THEN 'MATCH' ELSE 'MISMATCH' END AS status_view_item,
  -- Stage 2: Add to Cart
  SUM(sessions_add_to_cart) AS actual_add_to_cart,
  15167 AS expected_add_to_cart,
  CASE WHEN SUM(sessions_add_to_cart) = 15167 THEN 'MATCH' ELSE 'MISMATCH' END AS status_add_to_cart,
  -- Stage 3: Begin Checkout
  SUM(sessions_begin_checkout) AS actual_begin_checkout,
  5416 AS expected_begin_checkout,
  CASE WHEN SUM(sessions_begin_checkout) = 5416 THEN 'MATCH' ELSE 'MISMATCH' END AS status_begin_checkout,
  -- Stage 4: Add Shipping Info
  SUM(sessions_add_shipping) AS actual_add_shipping,
  3119 AS expected_add_shipping,
  CASE WHEN SUM(sessions_add_shipping) = 3119 THEN 'MATCH' ELSE 'MISMATCH' END AS status_add_shipping,
  -- Stage 5: Add Payment Info
  SUM(sessions_add_payment) AS actual_add_payment,
  2438 AS expected_add_payment,
  CASE WHEN SUM(sessions_add_payment) = 2438 THEN 'MATCH' ELSE 'MISMATCH' END AS status_add_payment,
  -- Stage 6: Strict Purchase
  SUM(sessions_purchase_strict) AS actual_purchase_strict,
  1792 AS expected_purchase_strict,
  CASE WHEN SUM(sessions_purchase_strict) = 1792 THEN 'MATCH' ELSE 'MISMATCH' END AS status_purchase_strict,
  -- Macro Purchase
  SUM(sessions_purchase_macro) AS actual_purchase_macro
FROM
  landing_segment_counts;


-- =================================================================================================
-- SECTION 5: TEMPORAL & TIME-OF-DAY PATTERNS
-- Extracts UTC hour of day from event_timestamp to analyze engagement, checkout intensity, and
-- conversion rates across 24 hours and daily time blocks.
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 5.1: 24-Hour Funnel Intensity & Time Block Analysis
-- Time Blocks:
--   - Night (00:00 - 05:59 UTC)
--   - Morning (06:00 - 11:59 UTC)
--   - Afternoon (12:00 - 17:59 UTC)
--   - Evening (18:00 - 23:59 UTC)
-- -------------------------------------------------------------------------------------------------
WITH session_time_events AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    event_name,
    event_timestamp,
    EXTRACT(HOUR FROM TIMESTAMP_MICROS(event_timestamp)) AS event_hour_utc
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name IN ('view_item', 'begin_checkout', 'purchase')
    AND user_pseudo_id IS NOT NULL
),
hourly_aggregates AS (
  SELECT
    event_hour_utc,
    CASE
      WHEN event_hour_utc BETWEEN 0 AND 5 THEN 'Night (00-05 UTC)'
      WHEN event_hour_utc BETWEEN 6 AND 11 THEN 'Morning (06-11 UTC)'
      WHEN event_hour_utc BETWEEN 12 AND 17 THEN 'Afternoon (12-17 UTC)'
      ELSE 'Evening (18-23 UTC)'
    END AS time_block,
    COUNT(DISTINCT CASE WHEN event_name = 'view_item' THEN session_key END) AS view_item_sessions,
    COUNT(DISTINCT CASE WHEN event_name = 'begin_checkout' THEN session_key END) AS checkout_sessions,
    COUNT(DISTINCT CASE WHEN event_name = 'purchase' THEN session_key END) AS purchase_sessions
  FROM
    session_time_events
  GROUP BY
    event_hour_utc,
    time_block
)
SELECT
  event_hour_utc,
  time_block,
  view_item_sessions,
  checkout_sessions,
  purchase_sessions,
  ROUND(SAFE_DIVIDE(checkout_sessions, view_item_sessions) * 100, 2) AS view_to_checkout_rate_pct,
  ROUND(SAFE_DIVIDE(purchase_sessions, checkout_sessions) * 100, 2) AS checkout_completion_rate_pct,
  ROUND(SAFE_DIVIDE(purchase_sessions, view_item_sessions) * 100, 2) AS view_to_purchase_cr_pct
FROM
  hourly_aggregates
ORDER BY
  event_hour_utc ASC;


-- =================================================================================================
-- SECTION 6: PRODUCT CATEGORY & ITEM-LEVEL FUNNEL ANALYSIS
-- Unnests the `items` repeated record to inspect item_category across view_item, add_to_cart,
-- and purchase. Includes missing/null category handling and sample size validation.
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 6.1: Product Category Funnel Performance & Drop-offs
-- Evaluates item-level demand, cart addition rate, purchase rate, and total revenue.
-- -------------------------------------------------------------------------------------------------
WITH item_events AS (
  SELECT
    event_name,
    COALESCE(NULLIF(i.item_category, '(not set)'), 'Uncategorized / Not Set') AS product_category,
    i.item_id,
    i.price_in_usd,
    ecommerce.purchase_revenue_in_usd
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
    UNNEST(items) AS i
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name IN ('view_item', 'add_to_cart', 'purchase')
)
SELECT
  product_category,
  COUNTIF(event_name = 'view_item') AS item_views,
  COUNTIF(event_name = 'add_to_cart') AS item_cart_adds,
  COUNTIF(event_name = 'purchase') AS item_purchases,
  ROUND(SUM(CASE WHEN event_name = 'purchase' THEN purchase_revenue_in_usd ELSE 0 END), 2) AS total_revenue_usd,
  -- Item-level Funnel Conversion Rates (%)
  ROUND(SAFE_DIVIDE(COUNTIF(event_name = 'add_to_cart'), COUNTIF(event_name = 'view_item')) * 100, 2) AS view_to_cart_rate_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(event_name = 'purchase'), COUNTIF(event_name = 'add_to_cart')) * 100, 2) AS cart_to_purchase_rate_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(event_name = 'purchase'), COUNTIF(event_name = 'view_item')) * 100, 2) AS overall_item_conversion_rate_pct,
  -- Data Quality & Sample Size Flag
  CASE
    WHEN COUNTIF(event_name = 'view_item') < 100 THEN 'LOW VOLUME - Caution'
    WHEN product_category = 'Uncategorized / Not Set' THEN 'UNCLASSIFIED TELEMETRY'
    ELSE 'SUFFICIENT VOLUME'
  END AS category_data_status
FROM
  item_events
GROUP BY
  product_category
ORDER BY
  item_views DESC;


-- =================================================================================================
-- SECTION 7: REVENUE OPPORTUNITY SIZING & INCREMENTAL LIFT MODELING
-- Inspects actual transaction revenue from `purchase` events and models scenarios where checkout
-- completion rate improves by configurable percentage points (+1%, +2%, +5%).
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 7.1: Revenue Baseline & Incremental Sensitivity Matrix
-- -------------------------------------------------------------------------------------------------
WITH purchase_metrics AS (
  SELECT
    COUNT(1) AS total_purchase_events,
    COUNT(DISTINCT ecommerce.transaction_id) AS total_unique_transactions,
    ROUND(SUM(ecommerce.purchase_revenue_in_usd), 2) AS total_observed_revenue_usd,
    ROUND(AVG(ecommerce.purchase_revenue_in_usd), 2) AS observed_aov_usd
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'purchase'
    AND ecommerce.purchase_revenue_in_usd IS NOT NULL
    AND ecommerce.purchase_revenue_in_usd > 0
),
checkout_baseline AS (
  SELECT
    COUNT(DISTINCT CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING))) AS sessions_reaching_checkout
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'begin_checkout'
    AND user_pseudo_id IS NOT NULL
),
scenario_parameters AS (
  SELECT 0.01 AS lift_rate, '+1.0% Checkout Completion Lift' AS scenario_name
  UNION ALL
  SELECT 0.02, '+2.0% Checkout Completion Lift'
  UNION ALL
  SELECT 0.03, '+3.0% Checkout Completion Lift'
  UNION ALL
  SELECT 0.05, '+5.0% Checkout Completion Lift'
)
SELECT
  p.total_observed_revenue_usd,
  p.total_unique_transactions,
  p.observed_aov_usd,
  c.sessions_reaching_checkout,
  s.scenario_name,
  -- Potential incremental orders generated
  ROUND(c.sessions_reaching_checkout * s.lift_rate, 0) AS potential_incremental_orders,
  -- Potential incremental revenue modeled
  ROUND(c.sessions_reaching_checkout * s.lift_rate * p.observed_aov_usd, 2) AS potential_incremental_revenue_usd,
  -- Potential percentage lift over observed revenue
  ROUND(SAFE_DIVIDE((c.sessions_reaching_checkout * s.lift_rate * p.observed_aov_usd), p.total_observed_revenue_usd) * 100, 2) AS pct_revenue_expansion
FROM
  purchase_metrics p
CROSS JOIN
  checkout_baseline c
CROSS JOIN
  scenario_parameters s
ORDER BY
  s.lift_rate ASC;


-- =================================================================================================
-- SECTION 8: COMPACT POWER BI EXPORT TABLE - SEGMENT & REVENUE SUMMARY
-- Compact aggregated table ready for export to `data/segment_funnel_summary.csv` and direct
-- integration into the Power BI star schema.
-- =================================================================================================

-- -------------------------------------------------------------------------------------------------
-- QUERY 8.1: Consolidated Segment Funnel Export
-- Grain: device_category x country_tier
-- -------------------------------------------------------------------------------------------------
WITH session_base AS (
  SELECT
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key,
    device.category AS device_category,
    CASE WHEN geo.country = 'United States' THEN 'United States' ELSE 'International / Other' END AS geography_tier,
    event_name,
    event_timestamp,
    ecommerce.purchase_revenue_in_usd
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
session_summary AS (
  SELECT
    session_key,
    ARRAY_AGG(device_category ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] AS device_category,
    ARRAY_AGG(geography_tier ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] AS geography_tier,
    LOGICAL_OR(event_name = 'view_item') AS has_view_item,
    LOGICAL_OR(event_name = 'add_to_cart') AS has_add_to_cart,
    LOGICAL_OR(event_name = 'begin_checkout') AS has_begin_checkout,
    LOGICAL_OR(event_name = 'add_shipping_info') AS has_add_shipping,
    LOGICAL_OR(event_name = 'add_payment_info') AS has_add_payment,
    LOGICAL_OR(event_name = 'purchase') AS has_purchase,
    MAX(purchase_revenue_in_usd) AS session_revenue_usd
  FROM
    session_base
  GROUP BY
    session_key
)
SELECT
  device_category,
  geography_tier,
  COUNT(DISTINCT session_key) AS total_sessions,
  COUNTIF(has_view_item) AS sessions_with_view_item,
  COUNTIF(has_add_to_cart) AS sessions_with_add_to_cart,
  COUNTIF(has_begin_checkout) AS sessions_with_begin_checkout,
  COUNTIF(has_add_shipping) AS sessions_with_add_shipping,
  COUNTIF(has_add_payment) AS sessions_with_add_payment,
  COUNTIF(has_purchase) AS sessions_with_purchase,
  ROUND(SUM(COALESCE(session_revenue_usd, 0)), 2) AS total_segment_revenue_usd,
  ROUND(SAFE_DIVIDE(SUM(session_revenue_usd), COUNTIF(has_purchase)), 2) AS segment_aov_usd,
  -- Macro conversion rates
  ROUND(SAFE_DIVIDE(COUNTIF(has_add_to_cart), COUNTIF(has_view_item)) * 100, 2) AS view_to_cart_cr_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(has_begin_checkout), COUNTIF(has_add_to_cart)) * 100, 2) AS cart_to_checkout_cr_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(has_purchase), COUNTIF(has_begin_checkout)) * 100, 2) AS checkout_completion_cr_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(has_purchase), COUNTIF(has_view_item)) * 100, 2) AS overall_cr_pct
FROM
  session_summary
GROUP BY
  device_category,
  geography_tier
ORDER BY
  total_sessions DESC;
