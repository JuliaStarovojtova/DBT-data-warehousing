-- Purpose: to clean and standardize nyc_restaurant_inspection_primary data
-- Grain: one row per violation cited during one DOHMH restaurant inspection, identified by camis + inspection_date + inspection_type + violation_code.
-- Scope: inspections dated 2020-01-01 through 2025-12-31 (filtered at extraction). Inspections with no violations are kept as one row with violation_code NULL.

WITH source AS (
   SELECT DISTINCT * FROM {{ source('raw', 'nyc_restaurant_inspection_primary') }} -- Source extract contains 1,245 exact-duplicate rows (each duplicated once); removed here by adding DISTINCT.
), -- Easier to refer to the dbt reference to a long name table this way

cleaned AS (
   SELECT
       -- Get all columns from source, except ones we're transforming below
       -- To do cleaning on them or explicitly cast them as types just in case
       * EXCEPT (
           camis,
           inspection_date,
           grade_date,
           record_date,           
           violation_code,
           violation_description,
           critical_flag,
           score,
           grade,
           inspection_type,
           zipcode,
           boro,
           latitude,
           longitude           
       ),

       -- Identifiers
       CAST(camis AS STRING) AS camis,

       -- Date/Time
       CAST(inspection_date AS TIMESTAMP) AS inspection_date,
       CAST(grade_date AS TIMESTAMP) AS grade_date,
       CAST(record_date AS TIMESTAMP) AS record_date,

       -- Request details
       CAST(violation_code AS STRING) AS violation_code,
       CAST(violation_description AS STRING) AS violation_description,
       CAST(critical_flag AS STRING) AS critical_flag,
       CAST(score AS DECIMAL) AS score,
       CAST(grade AS STRING) AS grade,
       CAST(inspection_type AS STRING) AS inspection_type,
    
       -- Location - clean zip code, handling several common zip code data problems
       CASE
           WHEN UPPER(TRIM(CAST(zipcode AS STRING))) IN ('N/A', 'NA') THEN NULL
           WHEN UPPER(TRIM(CAST(zipcode AS STRING))) = 'ANONYMOUS' THEN 'Anonymous'
           WHEN LENGTH(CAST(zipcode AS STRING)) = 5 THEN CAST(zipcode AS STRING)
           WHEN LENGTH(CAST(zipcode AS STRING)) = 9 THEN CAST(zipcode AS STRING)
           WHEN LENGTH(CAST(zipcode AS STRING)) = 10
               AND REGEXP_CONTAINS(CAST(zipcode AS STRING), r'^\d{5}-\d{4}')
           THEN CAST(zipcode AS STRING)
           ELSE NULL
       END AS zipcode,

       -- Location - standardized borough, just in case
       CASE
           WHEN UPPER(TRIM(boro)) IN ('MANHATTAN', 'NEW YORK COUNTY') THEN 'Manhattan'
           WHEN UPPER(TRIM(boro)) IN ('BRONX', 'THE BRONX') THEN 'Bronx'
           WHEN UPPER(TRIM(boro)) IN ('BROOKLYN', 'KINGS COUNTY') THEN 'Brooklyn'
           WHEN UPPER(TRIM(boro)) IN ('QUEENS', 'QUEEN', 'QUEENS COUNTY') THEN 'Queens'
           WHEN UPPER(TRIM(boro)) IN ('STATEN ISLAND', 'RICHMOND COUNTY') THEN 'Staten Island'
           ELSE 'UNKNOWN or CITYWIDE'
       END AS borough,

       CAST(latitude AS DECIMAL) AS latitude,
       CAST(longitude AS DECIMAL) AS longitude,

       -- Metadata
       CURRENT_TIMESTAMP() AS _stg_loaded_at -- might not need this line of code

   FROM source

   -- Filters
   WHERE camis IS NOT NULL
   AND inspection_date IS NOT NULL
   AND inspection_type IS NOT NULL
   AND violation_code IS NOT NULL 
   AND inspection_type IS NOT NULL 
   AND CAST(inspection_date AS DATE) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 YEAR)
   AND boro IS NOT NULL

)

SELECT * FROM cleaned
-- All should be part of this table after running: nyc_restaurant_inspection_primary data