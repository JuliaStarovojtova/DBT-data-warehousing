-- Purpose: to clean and standardize nyc_restaurant_inspection_secondary_311
-- The grain is one 311 service request (complaint) responded by DOHMH for a Restaurant and Restaurant/Bar/Deli/Bakery location types.    

WITH source AS (
   SELECT * FROM {{ source('raw', 'nyc_restaurant_inspection_secondary_311') }}
), -- Easier to refer to the dbt reference to a long name table this way

cleaned AS (
   SELECT
       -- Get all columns from source, except ones we're transforming below
       -- To do cleaning on them or explicitly cast them as types just in case
       * EXCEPT (
           unique_key,
           created_date,
           closed_date,
           agency,
           agency_name,
           complaint_type,
           descriptor,
           status,
           incident_zip,
           borough,
           incident_address,
           street_name,
           cross_street_1,
           cross_street_2,
           latitude,
           longitude,
           open_data_channel_type
       ),

       -- Identifiers
       CAST(unique_key AS STRING) AS unique_key, -- this field is already a STRING in the source data, so dont know the true value of CASTing it 

       -- Date/Time
       CAST(created_date AS TIMESTAMP) AS created_date, -- this field is already a TIMESTAMP in the source data, so dont know the true value of CASTing it
       CAST(closed_date AS TIMESTAMP) AS closed_date, -- this field as well is already a TIMESTAMP in the source data, so dont know the true value of CASTing it

       -- Request details
       CAST(agency AS STRING) AS agency, -- this field is already a STRING in the source data, so dont know the true value of CASTing it 
       CAST(agency_name AS STRING) AS agency_name, -- this field is already a STRING in the source data, so dont know the true value of CASTing it 
       CAST(complaint_type AS STRING) AS complaint_type, -- this field is already a STRING in the source data, so dont know the true value of CASTing it 
       CAST(descriptor AS STRING) AS descriptor, -- this field is already a STRING in the source data, so dont know the true value of CASTing it 
       UPPER(TRIM(CAST(status AS STRING))) AS status,  -- this field is already a STRING in the source data, so dont know the true value of CASTing it 

       -- Location - clean zip code, handling several common zip code data problems
       CASE
           WHEN UPPER(TRIM(CAST(incident_zip AS STRING))) IN ('N/A', 'NA') THEN NULL
           WHEN UPPER(TRIM(CAST(incident_zip AS STRING))) = 'ANONYMOUS' THEN 'Anonymous'
           WHEN LENGTH(CAST(incident_zip AS STRING)) = 5 THEN CAST(incident_zip AS STRING)
           WHEN LENGTH(CAST(incident_zip AS STRING)) = 9 THEN CAST(incident_zip AS STRING)
           WHEN LENGTH(CAST(incident_zip AS STRING)) = 10
               AND REGEXP_CONTAINS(CAST(incident_zip AS STRING), r'^\d{5}-\d{4}')
           THEN CAST(incident_zip AS STRING)
           ELSE NULL
       END AS zip,

       -- Location - standardized borough, just in case
       CASE
           WHEN UPPER(TRIM(borough)) IN ('MANHATTAN', 'NEW YORK COUNTY') THEN 'Manhattan'
           WHEN UPPER(TRIM(borough)) IN ('BRONX', 'THE BRONX') THEN 'Bronx'
           WHEN UPPER(TRIM(borough)) IN ('BROOKLYN', 'KINGS COUNTY') THEN 'Brooklyn'
           WHEN UPPER(TRIM(borough)) IN ('QUEENS', 'QUEEN', 'QUEENS COUNTY') THEN 'Queens'
           WHEN UPPER(TRIM(borough)) IN ('STATEN ISLAND', 'RICHMOND COUNTY') THEN 'Staten Island'
           ELSE 'UNKNOWN or CITYWIDE'
       END AS borough,

       CAST(incident_address AS STRING) AS incident_address,
       CAST(street_name AS STRING) AS street_name,
       CAST(cross_street_1 AS STRING) AS cross_street_1,
       CAST(cross_street_2 AS STRING) AS cross_street_2,
       CAST(latitude AS DECIMAL) AS latitude,
       CAST(longitude AS DECIMAL) AS longitude,

       -- Clearer column name as well for this one
       CAST(open_data_channel_type AS STRING) AS method_of_submission,

       -- Metadata
       CURRENT_TIMESTAMP() AS _stg_loaded_at

   FROM source

   -- Filters

   -- Remember: The grain is one 311 service request (complaint) responded by DOHMH for a Restaurant and Restaurant/Bar/Deli/Bakery location types.   
   -- However, we realized we do not need to filter by agency, agency_name, nor location_type because the source raw data 
   -- that KAVITA extracted from NYC Open Data was already filtered by agency at the time of extraction.
   -- However, to verify these assumtions and be able explain them in official documentation, we went to BQ and ran sql queries to verify them as follows:
   
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
     
   WHERE unique_key IS NOT NULL -- using this even though source data has 0 rows with null values, as extracted by KAVITA
   AND created_date IS NOT NULL -- using this even though source data has 0 rows with null values, as extracted by KAVITA
   AND CAST(created_date AS DATE) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 YEAR) 
        -- Using this even though we are aware that this line has 2 effects:
        -- 1: it removes the time portion
        -- 2: it keeps only complaints created in the last 7 years, counted back from the day the query runs, which ultimately means each run will return a different set of rows
        -- QUESTION: Could it quietly drop history from our fact table in the future? 
        -- QUESTION: If so, should we use a fixed cutoff or a dbt variable instead? Example: AND DATE(created_date) >= DATE('{{ var("start_date", "2019-01-01") }}')
   AND borough IS NOT NULL -- using this because source data has 5 rows with null values representing a 0.01% of rows; and 1118 "Unspecified" values representing 1.53% of rows
   AND incident_zip IS NOT NULL -- using this because source has 1258 rows with null values representing a 1.72% of rows
        -- Below is query used in BQ to explore the source data set for null values in important fields
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
   QUALIFY ROW_NUMBER() OVER (PARTITION BY unique_key ORDER BY created_date DESC) = 1
)

SELECT * FROM cleaned
-- All should be part of this table after running: stg_nyc_311_dot