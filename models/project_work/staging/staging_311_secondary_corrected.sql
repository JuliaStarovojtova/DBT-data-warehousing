-- Purpose: to clean and standardize nyc_restaurant_inspection_secondary_311
-- The grain is one 311 service request (complaint) responded to by DOHMH for Restaurant and Restaurant/Bar/Deli/Bakery location types.

WITH source AS (
   SELECT * FROM {{ source('raw', 'nyc_restaurant_inspection_secondary_311') }}
), -- Easier to refer to the dbt reference to a long name table this way

cleaned AS (
   SELECT
       -- Get all columns from source, except ones we're transforming below
       -- to clean them or explicitly cast them as types
       * EXCEPT (
           unique_key,
           created_date,
           closed_date,
           resolution_action_updated_date,   --  cast to TIMESTAMP below
           agency,
           agency_name,
           complaint_type,
           descriptor,
           descriptor_2,                     -- 'N/A' -> NULL below
           status,
           incident_zip,
           borough,
           incident_address,
           street_name,
           cross_street_1,
           cross_street_2,
           intersection_street_1,            --  extra spaces cleaned below
           intersection_street_2,             
           community_board,                  --  'Unspecified' -> NULL below
           park_borough,                     
           park_facility_name,               
           police_precinct,                  
           latitude,
           longitude,
           open_data_channel_type
       ),

       -- NOTE on CASTs: most of these columns already have the right type in the source,
       -- so the CAST does not change the values today. We keep them on purpose as a
       -- "type contract": if the raw table is ever re-extracted and a column is loaded
       -- with a different type (e.g. incident_zip as INT64), the staging output stays stable.

       -- Identifiers
       CAST(unique_key AS STRING) AS unique_key,

       -- Date/Time
       CAST(created_date AS TIMESTAMP) AS created_date,
       DATE(CAST(created_date AS TIMESTAMP)) AS created_on,  -- new: date only, for joins and comparisons with inspections
       CAST(closed_date AS TIMESTAMP) AS closed_date,
       CAST(resolution_action_updated_date AS TIMESTAMP) AS resolution_action_updated_date, -- [CHANGE 1]

       -- Request details
       CAST(agency AS STRING) AS agency,
       CAST(agency_name AS STRING) AS agency_name,
       CAST(complaint_type AS STRING) AS complaint_type,
       CAST(descriptor AS STRING) AS descriptor,
       CASE                                                           -- [CHANGE 2]
           WHEN UPPER(TRIM(CAST(descriptor_2 AS STRING))) IN ('N/A', 'NA', 'UNSPECIFIED', '') THEN NULL
           ELSE TRIM(CAST(descriptor_2 AS STRING))
       END AS descriptor_2,
       UPPER(TRIM(CAST(status AS STRING))) AS status,

       -- Flag for the June 2024 bulk "administrative" closures of old tickets       -- [CHANGE 4]
       -- (these closed_date values are not real responses and would inflate any time-to-close metric)
       COALESCE(LOWER(resolution_description) LIKE '%administratively closed%', FALSE) AS is_admin_closed,

       -- Location - clean zip code, handling several common zip code data problems
       CASE
           WHEN UPPER(TRIM(CAST(incident_zip AS STRING))) IN ('N/A', 'NA') THEN NULL
           WHEN UPPER(TRIM(CAST(incident_zip AS STRING))) = 'ANONYMOUS' THEN 'Anonymous'
           -- [CHANGE 5] check that the value is actually digits, not just the right length
           WHEN REGEXP_CONTAINS(TRIM(CAST(incident_zip AS STRING)), r'^\d{5}$')       THEN TRIM(CAST(incident_zip AS STRING))
           WHEN REGEXP_CONTAINS(TRIM(CAST(incident_zip AS STRING)), r'^\d{9}$')       THEN TRIM(CAST(incident_zip AS STRING))
           WHEN REGEXP_CONTAINS(TRIM(CAST(incident_zip AS STRING)), r'^\d{5}-\d{4}$') THEN TRIM(CAST(incident_zip AS STRING))
           ELSE NULL
       END AS zip,

       -- Location - standardized borough, just in case
       CASE
           WHEN UPPER(TRIM(borough)) IN ('MANHATTAN', 'NEW YORK COUNTY') THEN 'Manhattan'
           WHEN UPPER(TRIM(borough)) IN ('BRONX', 'THE BRONX') THEN 'Bronx'
           WHEN UPPER(TRIM(borough)) IN ('BROOKLYN', 'KINGS COUNTY') THEN 'Brooklyn'
           WHEN UPPER(TRIM(borough)) IN ('QUEENS', 'QUEEN', 'QUEENS COUNTY') THEN 'Queens'
           WHEN UPPER(TRIM(borough)) IN ('STATEN ISLAND', 'RICHMOND COUNTY') THEN 'Staten Island'
           ELSE 'UNKNOWN or CITYWIDE'   -- includes the "Unspecified" rows
       END AS borough,

       -- [CHANGE 3] collapse repeated spaces, e.g. 'WEST   26 STREET' -> 'WEST 26 STREET'
       REGEXP_REPLACE(TRIM(CAST(incident_address AS STRING)), r'\s+', ' ')      AS incident_address,
       REGEXP_REPLACE(TRIM(CAST(street_name AS STRING)), r'\s+', ' ')           AS street_name,
       REGEXP_REPLACE(TRIM(CAST(cross_street_1 AS STRING)), r'\s+', ' ')        AS cross_street_1,
       REGEXP_REPLACE(TRIM(CAST(cross_street_2 AS STRING)), r'\s+', ' ')        AS cross_street_2,
       REGEXP_REPLACE(TRIM(CAST(intersection_street_1 AS STRING)), r'\s+', ' ') AS intersection_street_1,
       REGEXP_REPLACE(TRIM(CAST(intersection_street_2 AS STRING)), r'\s+', ' ') AS intersection_street_2,

       -- [CHANGE 2] "Unspecified" is a placeholder, not a real value -> NULL
       CASE
           WHEN UPPER(TRIM(CAST(community_board AS STRING))) IN ('0 UNSPECIFIED', 'UNSPECIFIED') THEN NULL
           ELSE TRIM(CAST(community_board AS STRING))
       END AS community_board,
       NULLIF(TRIM(CAST(park_borough AS STRING)), 'Unspecified')       AS park_borough,
       NULLIF(TRIM(CAST(park_facility_name AS STRING)), 'Unspecified') AS park_facility_name,
       NULLIF(TRIM(CAST(police_precinct AS STRING)), 'Unspecified')    AS police_precinct,

       CAST(latitude AS DECIMAL) AS latitude,
       CAST(longitude AS DECIMAL) AS longitude,

       -- Clearer column name as well for this one
       CAST(open_data_channel_type AS STRING) AS method_of_submission,

       -- Metadata
       CURRENT_TIMESTAMP() AS _stg_loaded_at

   FROM source

   -- Filters

   -- Remember: The grain is one 311 service request (complaint) responded to by DOHMH for Restaurant and Restaurant/Bar/Deli/Bakery location types.
   -- We do not need to filter by agency, agency_name, or location_type because the raw data
   -- KAVITA extracted from NYC Open Data was already filtered at the time of extraction.
   -- To verify these assumptions and be able to explain them in official documentation, we ran these queries in BQ:

        -- SELECT
        -- COUNT(DISTINCT agency_name) AS distinct_agency_count
        -- FROM `josedata26.nyc_restaurant_data_analysis.nyc_restaurant_inspection_secondary_311`;

        -- SELECT
        -- agency_name,
        -- COUNT(*)                                            AS row_count,
        -- ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)    AS pct_of_rows
        -- FROM `josedata26.nyc_restaurant_data_analysis.nyc_restaurant_inspection_secondary_311`
        -- GROUP BY agency_name
        -- ORDER BY row_count DESC;

        -- SELECT
        -- COUNT(DISTINCT location_type) AS distinct_location_type
        -- FROM `josedata26.nyc_restaurant_data_analysis.nyc_restaurant_inspection_secondary_311`;

        -- SELECT
        -- location_type,
        -- COUNT(*)                                            AS row_count,
        -- ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)    AS pct_of_rows
        -- FROM `josedata26.nyc_restaurant_data_analysis.nyc_restaurant_inspection_secondary_311`
        -- GROUP BY location_type
        -- ORDER BY row_count DESC;

   WHERE unique_key IS NOT NULL   -- source has 0 null rows as extracted by KAVITA; kept as a safeguard
   AND created_date IS NOT NULL   -- source has 0 null rows as extracted by KAVITA; kept as a safeguard

   -- [CHANGE 6] fixed start date (dbt variable) instead of a rolling 7-year window.
   -- A rolling window (DATE_SUB(CURRENT_DATE(), INTERVAL 7 YEAR)) moves forward every day,
   -- so each run silently drops the oldest complaints and results are not reproducible.
   -- DATE() is only used for the comparison; the created_date column itself keeps its time.
   -- Override at run time with: dbt run --vars '{"start_date_311": "2020-01-01"}'
   AND DATE(created_date) >= DATE('{{ var("start_date_311", "2019-01-01") }}')

   AND borough IS NOT NULL        -- drops 5 null rows (0.01%). Note: 1,118 "Unspecified" rows (1.53%) are NOT null, so they are kept and mapped to 'UNKNOWN or CITYWIDE'
   AND incident_zip IS NOT NULL   -- drops 1,258 null rows (1.72%)
        -- Query used in BQ to explore the source data for null values in important fields:
            -- SELECT
            -- COUNT(*)                          AS total_rows,
            -- COUNTIF(unique_key IS NULL)       AS null_unique_key,
            -- COUNTIF(created_date IS NULL)     AS null_created_date,
            -- COUNTIF(closed_date IS NULL)      AS null_closed_date,
            -- COUNTIF(borough IS NULL)          AS null_borough,
            -- COUNTIF(incident_zip IS NULL)     AS null_incident_zip,
            -- COUNTIF(complaint_type IS NULL)   AS null_complaint_type,
            -- COUNTIF(open_data_channel_type IS NULL) AS null_channel_type
            -- FROM `josedata26.nyc_restaurant_data_analysis.nyc_restaurant_inspection_secondary_311`;

   -- Deduplicate
   -- [CHANGE 7] keep the most recently UPDATED version of a request. Duplicates of the same
   -- unique_key normally share the same created_date, so ordering by created_date alone
   -- picks a random row; the last update / close date breaks the tie.
   QUALIFY ROW_NUMBER() OVER (
       PARTITION BY unique_key
       ORDER BY resolution_action_updated_date DESC, closed_date DESC, created_date DESC
   ) = 1
)

SELECT * FROM cleaned
-- [CHANGE 8] -- All should be part of this table after running: staging_311_secondary 
