-- =================================================================================================
-- PROJECT: CheckoutLens - E-commerce Checkout Abandonment & Funnel Analytics
-- SCRIPT: 01_data_audit.sql
-- PURPOSE: Comprehensive data quality, schema validation, and field availability audit for the
--          Google Analytics 4 (GA4) Obfuscated Sample E-commerce dataset.
--
-- DATASET: `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
-- DATE RANGE: 2020-11-01 to 2021-01-31 (92 daily partitioned tables)
--
-- COST & EXECUTION NOTE:
-- In Google BigQuery, querying wildcard tables scans all matching partitions.
-- To minimize data scan costs during exploratory validation:
--   - For initial fast/low-cost testing: Change the suffix filter to a 1-day or 7-day slice:
--       `WHERE _TABLE_SUFFIX = '20201201'`
--       or `WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201207'`
--   - For the full 3-month audit validation:
--       `WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'`
-- Always review the query validator ("This query will process XX MB when run") before executing!
-- =================================================================================================


-- -------------------------------------------------------------------------------------------------
-- QUERY 1: Event Inventory & Volume Distribution
-- Inspect overall event volume, distinct users, and proportion of total events per event type.
-- Identifies presence and relative frequency of core e-commerce funnel events.
-- -------------------------------------------------------------------------------------------------
SELECT
  event_name,
  COUNT(1) AS total_events,
  COUNT(DISTINCT user_pseudo_id) AS distinct_users,
  ROUND(COUNT(1) * 100.0 / SUM(COUNT(1)) OVER(), 2) AS pct_of_all_events
FROM
  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE
  _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY
  event_name
ORDER BY
  total_events DESC;


-- -------------------------------------------------------------------------------------------------
-- QUERY 2: Temporal Coverage & Daily Event Distribution
-- Validate date boundaries, active collection days, and detect any reporting gaps or missing days.
-- -------------------------------------------------------------------------------------------------
SELECT
  PARSE_DATE('%Y%m%d', event_date) AS event_date,
  COUNT(1) AS total_events,
  COUNT(DISTINCT user_pseudo_id) AS active_users,
  COUNTIF(event_name = 'purchase') AS daily_purchases,
  ROUND(SUM(ecommerce.purchase_revenue_in_usd), 2) AS daily_revenue_usd
FROM
  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE
  _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY
  event_date
ORDER BY
  event_date ASC;


-- -------------------------------------------------------------------------------------------------
-- QUERY 3: Device Category, OS, and Browser Audit
-- Inspect user environment breakdowns to identify primary traffic platforms for funnel segmentation.
-- -------------------------------------------------------------------------------------------------
SELECT
  device.category AS device_category,
  device.operating_system AS operating_system,
  device.web_info.browser AS browser,
  COUNT(1) AS total_events,
  COUNT(DISTINCT user_pseudo_id) AS distinct_users,
  COUNTIF(event_name = 'purchase') AS total_purchases
FROM
  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE
  _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY
  device_category,
  operating_system,
  browser
ORDER BY
  distinct_users DESC;


-- -------------------------------------------------------------------------------------------------
-- QUERY 4: User & Session Identifier Integrity (user_pseudo_id & ga_session_id)
-- Note: In GA4, ga_session_id is an integer timestamp stored inside the nested event_params array.
-- A ga_session_id is NOT globally unique by itself; the true session identifier is:
--   CONCAT(user_pseudo_id, '-', CAST(ga_session_id AS STRING))
-- Check completeness and null/missing rates.
-- -------------------------------------------------------------------------------------------------
WITH session_extracted AS (
  SELECT
    user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS ga_session_id,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'session_engaged') AS session_engaged
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
)
SELECT
  COUNT(1) AS total_records,
  COUNTIF(user_pseudo_id IS NULL OR user_pseudo_id = '') AS missing_user_pseudo_id,
  ROUND(COUNTIF(user_pseudo_id IS NULL OR user_pseudo_id = '') * 100.0 / COUNT(1), 2) AS pct_missing_user_id,
  COUNTIF(ga_session_id IS NULL) AS missing_ga_session_id,
  ROUND(COUNTIF(ga_session_id IS NULL) * 100.0 / COUNT(1), 2) AS pct_missing_session_id,
  COUNT(DISTINCT user_pseudo_id) AS unique_users,
  COUNT(DISTINCT CONCAT(user_pseudo_id, '-', CAST(ga_session_id AS STRING))) AS unique_composite_sessions
FROM
  session_extracted;


-- -------------------------------------------------------------------------------------------------
-- QUERY 5: Nested Item & Product Hierarchy Audit
-- Unnest the `items` repeated record to check item_id, item_name, item_category, price, and missingness.
-- -------------------------------------------------------------------------------------------------
SELECT
  i.item_category,
  COUNT(1) AS item_view_instances,
  COUNT(DISTINCT i.item_id) AS distinct_products,
  COUNTIF(i.item_id IS NULL OR i.item_id = '(not set)') AS missing_item_id_count,
  COUNTIF(i.price IS NULL OR i.price = 0) AS zero_or_null_price_count,
  ROUND(AVG(i.price_in_usd), 2) AS avg_price_usd,
  ROUND(MIN(i.price_in_usd), 2) AS min_price_usd,
  ROUND(MAX(i.price_in_usd), 2) AS max_price_usd
FROM
  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
  UNNEST(items) AS i
WHERE
  _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  AND event_name IN ('view_item', 'add_to_cart', 'purchase')
GROUP BY
  item_category
ORDER BY
  item_view_instances DESC;


-- -------------------------------------------------------------------------------------------------
-- QUERY 6: Purchase Event & Transaction Revenue Field Integrity
-- Inspect transaction_id availability, revenue field populated states, and currency consistency.
-- -------------------------------------------------------------------------------------------------
SELECT
  COUNT(1) AS total_purchase_events,
  COUNT(DISTINCT ecommerce.transaction_id) AS unique_transaction_ids,
  COUNTIF(ecommerce.transaction_id IS NULL OR ecommerce.transaction_id = '(not set)') AS missing_transaction_ids,
  COUNTIF(ecommerce.purchase_revenue_in_usd IS NULL) AS null_revenue_in_usd,
  COUNTIF(ecommerce.purchase_revenue_in_usd = 0) AS zero_revenue_in_usd,
  ROUND(SUM(ecommerce.purchase_revenue_in_usd), 2) AS total_revenue_usd,
  ROUND(AVG(ecommerce.purchase_revenue_in_usd), 2) AS avg_order_value_usd,
  ROUND(MIN(ecommerce.purchase_revenue_in_usd), 2) AS min_revenue_usd,
  ROUND(MAX(ecommerce.purchase_revenue_in_usd), 2) AS max_revenue_usd
FROM
  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE
  _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  AND event_name = 'purchase';


-- -------------------------------------------------------------------------------------------------
-- QUERY 7: Duplicate Transaction ID Verification
-- In e-commerce telemetry, duplicate purchase events or reused transaction IDs distort revenue and conversion.
-- -------------------------------------------------------------------------------------------------
WITH transaction_counts AS (
  SELECT
    ecommerce.transaction_id,
    COUNT(1) AS occurrence_count,
    COUNT(DISTINCT user_pseudo_id) AS user_count,
    ARRAY_AGG(ecommerce.purchase_revenue_in_usd) AS revenue_values
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'purchase'
    AND ecommerce.transaction_id IS NOT NULL
    AND ecommerce.transaction_id != '(not set)'
  GROUP BY
    ecommerce.transaction_id
  HAVING
    COUNT(1) > 1
)
SELECT
  occurrence_count,
  COUNT(1) AS duplicate_transaction_count
FROM
  transaction_counts
GROUP BY
  occurrence_count
ORDER BY
  occurrence_count DESC;


-- -------------------------------------------------------------------------------------------------
-- QUERY 8: Funnel Stage Inventory (User & Session Level Counts)
-- High-level baseline comparison across standard GA4 e-commerce funnel events:
-- 1. view_item -> 2. add_to_cart -> 3. begin_checkout -> 4. add_shipping_info -> 5. add_payment_info -> 6. purchase
-- -------------------------------------------------------------------------------------------------
WITH extracted_events AS (
  SELECT
    event_name,
    user_pseudo_id,
    CONCAT(user_pseudo_id, '-', CAST((
      SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'
    ) AS STRING)) AS session_key
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
)
SELECT
  CASE event_name
    WHEN 'view_item' THEN '1. Product View (view_item)'
    WHEN 'add_to_cart' THEN '2. Add to Cart (add_to_cart)'
    WHEN 'begin_checkout' THEN '3. Begin Checkout (begin_checkout)'
    WHEN 'add_shipping_info' THEN '4. Add Shipping (add_shipping_info)'
    WHEN 'add_payment_info' THEN '5. Add Payment (add_payment_info)'
    WHEN 'purchase' THEN '6. Purchase (purchase)'
  END AS funnel_step,
  event_name,
  COUNT(1) AS raw_event_count,
  COUNT(DISTINCT session_key) AS distinct_sessions_with_event,
  COUNT(DISTINCT user_pseudo_id) AS distinct_users_with_event
FROM
  extracted_events
GROUP BY
  funnel_step,
  event_name
ORDER BY
  funnel_step ASC;
