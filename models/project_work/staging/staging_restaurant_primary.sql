-- Purpose: to clean and standardize nyc_restaurant_inspection_primary data
-- Grain: one row per violation cited during one DOHMH restaurant inspection,
--   identified by camis + inspection_date + inspection_type + violation_code.
--   Inspections with no violations are kept as one row with violation_code NULL.
--   (fact_rstrnt_inspection rolls these rows up to one row per inspection_key = the project grain.)
-- Scope: inspections dated 2020-01-01 through 2025-12-31 (filtered at extraction, and enforced again below).

WITH source AS (
   -- Source extract contains 1,245 exact-duplicate rows (each duplicated once); removed here by DISTINCT.
   SELECT DISTINCT * FROM {{ source('raw', 'nyc_restaurant_inspection_primary') }}
), -- Easier to refer to the dbt reference to a long name table this way

cleaned AS (
   SELECT
       -- Get all columns from source, except ones we're transforming below
       -- to clean them or explicitly cast them as types.
       -- CASTs on columns that already have the right type are kept on purpose as a "type contract":
       -- if the raw table is re-extracted with different types, the staging output stays the same.
       * EXCEPT (
           camis,
           dba,
           cuisine_description,
           phone,
           inspection_date,
           grade_date,
           record_date,
           inspection_type,
           action,
           violation_code,
           violation_description,
           critical_flag,
           score,
           grade,
           boro,
           building,
           street,
           zipcode,
           latitude,
           longitude,
           bin,
           bbl
       ),

       -- Identifiers
       CAST(camis AS STRING) AS camis,

       -- Restaurant details  [CHANGE 1: needed by dim_restaurants]
       REGEXP_REPLACE(TRIM(CAST(dba AS STRING)), r'\s+', ' ') AS dba_name,
       TRIM(CAST(cuisine_description AS STRING)) AS cuisine_description,
       CASE   -- keep only 10-digit phone numbers; placeholders like '__________' -> NULL
           WHEN REGEXP_CONTAINS(REGEXP_REPLACE(CAST(phone AS STRING), r'\D', ''), r'^\d{10}$')
           THEN REGEXP_REPLACE(CAST(phone AS STRING), r'\D', '')
       END AS phone,

       -- Date/Time  [CHANGE 4: inspection_date and grade_date are always 00:00:00 -> DATE]
       DATE(CAST(inspection_date AS TIMESTAMP)) AS inspection_date,
       DATE(CAST(grade_date AS TIMESTAMP)) AS grade_date,
       CAST(record_date AS TIMESTAMP) AS record_date,   -- real time (when NYC Open Data refreshed the record)

       -- Inspection details
       TRIM(CAST(inspection_type AS STRING)) AS inspection_type,
       TRIM(CAST(action AS STRING)) AS action,

       -- Violation details
       UPPER(TRIM(CAST(violation_code AS STRING))) AS violation_code,
       TRIM(CAST(violation_description AS STRING)) AS violation_description,
       TRIM(CAST(critical_flag AS STRING)) AS critical_flag,              -- 'Critical', 'Not Critical', 'Not Applicable'
       UPPER(TRIM(CAST(critical_flag AS STRING))) = 'CRITICAL' AS is_critical,

       -- Score and grade  [CHANGE 5]
       SAFE_CAST(SAFE_CAST(score AS FLOAT64) AS INT64) AS score,          -- whole numbers stored as 4.0 -> INT64 (ERD: integer)
       CASE   -- valid grades: A, B, C, N (not yet graded), P and Z (grade pending)
           WHEN UPPER(TRIM(CAST(grade AS STRING))) IN ('A', 'B', 'C', 'N', 'P', 'Z')
           THEN UPPER(TRIM(CAST(grade AS STRING)))
       END AS grade,

       -- Location - standardized borough, same mapping as the 311 staging model
       CASE
           WHEN UPPER(TRIM(CAST(boro AS STRING))) IN ('MANHATTAN', 'NEW YORK COUNTY') THEN 'Manhattan'
           WHEN UPPER(TRIM(CAST(boro AS STRING))) IN ('BRONX', 'THE BRONX') THEN 'Bronx'
           WHEN UPPER(TRIM(CAST(boro AS STRING))) IN ('BROOKLYN', 'KINGS COUNTY') THEN 'Brooklyn'
           WHEN UPPER(TRIM(CAST(boro AS STRING))) IN ('QUEENS', 'QUEEN', 'QUEENS COUNTY') THEN 'Queens'
           WHEN UPPER(TRIM(CAST(boro AS STRING))) IN ('STATEN ISLAND', 'RICHMOND COUNTY') THEN 'Staten Island'
           ELSE 'UNKNOWN or CITYWIDE'   -- includes boro = '0' (missing)
       END AS borough,

       -- Location - address parts  [CHANGE 6]
       NULLIF(TRIM(CAST(building AS STRING)), '0') AS building,           -- '0' = no building number
       NULLIF(   -- uppercase like 311 addresses, collapse spaces, strip leading '&' / '-' (e.g. '- JFK AIRPORT')
           REGEXP_REPLACE(REGEXP_REPLACE(UPPER(TRIM(CAST(street AS STRING))), r'^[\s&\-]+', ''), r'\s+', ' '),
           ''
       ) AS street,

       -- Location - zip code  [CHANGE 7: always 5 digits, dim_location.zipcode is varchar(5)]
       -- (the inner regex strips a trailing '.0' in case zipcode was loaded as a FLOAT)
       CASE
           WHEN REGEXP_CONTAINS(REGEXP_REPLACE(TRIM(CAST(zipcode AS STRING)), r'\.0+$', ''), r'^\d{5}$')
           THEN REGEXP_REPLACE(TRIM(CAST(zipcode AS STRING)), r'\.0+$', '')
       END AS zipcode,

       -- Location - coordinates  [CHANGE 8: 0.0 = unknown (a point in the ocean) -> NULL; FLOAT64 as in the ERD]
       NULLIF(SAFE_CAST(latitude AS FLOAT64), 0) AS latitude,
       NULLIF(SAFE_CAST(longitude AS FLOAT64), 0) AS longitude,

       -- Location - NYC building / tax lot IDs  [CHANGE 6: placeholders -> NULL]
       CASE   -- bin is a 7-digit building ID; '1000000' style values are placeholders
           WHEN REGEXP_CONTAINS(TRIM(CAST(bin AS STRING)), r'^\d{7}$')
            AND NOT REGEXP_CONTAINS(TRIM(CAST(bin AS STRING)), r'^\d000000$')
           THEN TRIM(CAST(bin AS STRING))
       END AS bin,
       CASE   -- bbl is a 10-digit tax lot ID; values like '1' or '4' are only a borough code
           WHEN REGEXP_CONTAINS(TRIM(CAST(bbl AS STRING)), r'^\d{10}$') THEN TRIM(CAST(bbl AS STRING))
       END AS bbl,

       -- Metadata
       CURRENT_TIMESTAMP() AS _stg_loaded_at   -- when this staging table was built; useful for debugging

   FROM source

   -- Filters
   WHERE camis IS NOT NULL
   AND inspection_date IS NOT NULL
   AND inspection_type IS NOT NULL
   -- [CHANGE 2] removed "violation_code IS NOT NULL": it dropped every inspection with no violations
   --            (the cleanest restaurants), which contradicts the grain above and biases scores/grades.
   -- [CHANGE 3] fixed project scope 2020-2025 with shared dbt variables (same as the 311 staging model),
   --            instead of a rolling 7-year window that moves every day.
   AND DATE(CAST(inspection_date AS TIMESTAMP)) BETWEEN DATE('{{ var("start_date", "2020-01-01") }}')
                                                    AND DATE('{{ var("end_date", "2025-12-31") }}')
   AND boro IS NOT NULL   -- note: boro = '0' is not NULL, so those rows are kept as 'UNKNOWN or CITYWIDE'

   -- Deduplicate near-duplicates at the grain (DISTINCT above only removes rows that are identical in every column).
   -- Keeps the most recently refreshed record.
   QUALIFY ROW_NUMBER() OVER (
       PARTITION BY camis, inspection_date, inspection_type, violation_code
       ORDER BY record_date DESC
   ) = 1
),

final AS (
   SELECT
       *,
       -- [CHANGE 1] one key per inspection (several violation rows share it) = grain of fact_rstrnt_inspection.
       -- MD5 hex = 32 characters, matching the varchar(32) keys in the ERD.
       TO_HEX(MD5(CONCAT(camis, '|', CAST(inspection_date AS STRING), '|', inspection_type))) AS inspection_key,
       -- [CHANGE 1] full street address for dim_restaurants, same style as 311 incident_address
       NULLIF(TRIM(CONCAT(COALESCE(building, ''), ' ', COALESCE(street, ''))), '') AS restaurant_address
   FROM cleaned
)

SELECT * FROM final
-- This model is staging_restaurant_primary (primary dataset: NYC restaurant inspections)