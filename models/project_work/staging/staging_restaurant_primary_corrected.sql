-- Purpose: to clean and standardize the NYC DOHMH Restaurant Inspection Results (primary dataset)
-- Project grain (confirmed with the professor): one restaurant inspection of a restaurant located in NYC, 2020 to 2025.
-- The grain of THIS STAGING model is one level lower: one VIOLATION cited during one inspection
--   (camis + inspection_date + inspection_type + violation_code), because that is how the raw data
--   is published: an inspection with several violations has several rows; an inspection with no
--   violations has one row with violation_code = NULL.
--   fact_rstrnt_inspection rolls these rows up to one row per inspection_key.
-- Column names follow the ERD (dba_name, restaurant_address, zipcode) and are conformed to stg 311
-- where they mean the same thing (borough, zipcode, latitude, longitude).

WITH source AS (
   SELECT * FROM {{ source('raw', 'nyc_restaurant_inspection_primary') }}
), -- Easier to refer to the dbt reference to a long name table this way

cleaned AS (
   SELECT
       -- NOTE: unlike stg 311, we list every column explicitly instead of using * EXCEPT,
       -- because almost every column in this dataset needs cleaning, renaming or casting.
       -- As in stg 311, CASTs on columns that already have the right type are kept as a
       -- "type contract" in case the raw table is re-extracted with different types.

       -- Identifiers
       CAST(camis AS STRING) AS camis,  -- restaurant ID, one per establishment; kept as STRING because it is an ID, not a number to do math with

       -- Restaurant details
       REGEXP_REPLACE(TRIM(CAST(dba AS STRING)), r'\s+', ' ') AS dba_name,  -- "dba" = "doing business as"; named as in dim_restaurants
       TRIM(CAST(cuisine_description AS STRING)) AS cuisine_description,
       CASE
           -- phone: keep only 10-digit numbers; placeholders like '__________' become NULL
           WHEN REGEXP_CONTAINS(REGEXP_REPLACE(CAST(phone AS STRING), r'\D', ''), r'^\d{10}$')
           THEN REGEXP_REPLACE(CAST(phone AS STRING), r'\D', '')
           ELSE NULL
       END AS phone,

       -- Inspection details
       -- inspection_date and grade_date are stored as TIMESTAMPs but always have 00:00:00,
       -- so the time is not real information -> converted to DATE
       DATE(CAST(inspection_date AS TIMESTAMP)) AS inspection_date,
       TRIM(CAST(inspection_type AS STRING)) AS inspection_type,
       TRIM(CAST(action AS STRING)) AS action,

       -- Violation details
       UPPER(TRIM(CAST(violation_code AS STRING))) AS violation_code,
       TRIM(CAST(violation_description AS STRING)) AS violation_description,
       TRIM(CAST(critical_flag AS STRING)) AS critical_flag,  -- 'Critical', 'Not Critical', 'Not Applicable'
       UPPER(TRIM(CAST(critical_flag AS STRING))) = 'CRITICAL' AS is_critical,  -- TRUE/FALSE version, easier to count

       -- Score and grade
       SAFE_CAST(SAFE_CAST(score AS FLOAT64) AS INT64) AS score,  -- scores are whole numbers stored as 4.0, 23.0 ...; lower score = better
       CASE
           -- valid grades: A, B, C, N = not yet graded, P = grade pending, Z = grade pending (re-opening)
           WHEN UPPER(TRIM(CAST(grade AS STRING))) IN ('A', 'B', 'C', 'N', 'P', 'Z')
           THEN UPPER(TRIM(CAST(grade AS STRING)))
           ELSE NULL
       END AS grade,
       DATE(CAST(grade_date AS TIMESTAMP)) AS grade_date,

       -- Location - standardized borough, same mapping as stg 311 so the two tables can be joined/compared
       CASE
           WHEN UPPER(TRIM(CAST(boro AS STRING))) IN ('MANHATTAN', 'NEW YORK COUNTY') THEN 'Manhattan'
           WHEN UPPER(TRIM(CAST(boro AS STRING))) IN ('BRONX', 'THE BRONX') THEN 'Bronx'
           WHEN UPPER(TRIM(CAST(boro AS STRING))) IN ('BROOKLYN', 'KINGS COUNTY') THEN 'Brooklyn'
           WHEN UPPER(TRIM(CAST(boro AS STRING))) IN ('QUEENS', 'QUEEN', 'QUEENS COUNTY') THEN 'Queens'
           WHEN UPPER(TRIM(CAST(boro AS STRING))) IN ('STATEN ISLAND', 'RICHMOND COUNTY') THEN 'Staten Island'
           ELSE 'UNKNOWN or CITYWIDE'   -- includes boro = '0' (missing)
       END AS borough,

       -- Location - address parts
       -- building '0' is a placeholder for "no building number" -> NULL
       NULLIF(TRIM(CAST(building AS STRING)), '0') AS building,
       -- street: uppercase (to match 311 addresses), collapse repeated spaces,
       -- and strip leading junk characters such as '& GRAND CENTRAL' or '- JFK AIRPORT'
       NULLIF(
           REGEXP_REPLACE(REGEXP_REPLACE(UPPER(TRIM(CAST(street AS STRING))), r'^[\s&\-]+', ''), r'\s+', ' '),
           ''
       ) AS street,

       -- Location - clean zip code, same 5-digit rule as stg 311 (dim_location.zipcode is varchar(5))
       -- (the regex at the start strips a trailing '.0' in case zipcode was loaded as a FLOAT)
       CASE
           WHEN REGEXP_CONTAINS(REGEXP_REPLACE(TRIM(CAST(zipcode AS STRING)), r'\.0+$', ''), r'^\d{5}$')
           THEN REGEXP_REPLACE(TRIM(CAST(zipcode AS STRING)), r'\.0+$', '')
           ELSE NULL
       END AS zipcode,

       -- Location - coordinates: 0.0 is a placeholder for "unknown" (it is a real point in the ocean) -> NULL
       -- FLOAT64 to match the ERD (float) and stg 311
       NULLIF(SAFE_CAST(latitude AS FLOAT64), 0) AS latitude,
       NULLIF(SAFE_CAST(longitude AS FLOAT64), 0) AS longitude,

       -- Location - NYC geographic codes
       -- bbl is a 10-digit tax lot ID; values like '1' or '4' are only a borough code -> NULL
       CASE WHEN REGEXP_CONTAINS(TRIM(CAST(bbl AS STRING)), r'^\d{10}$') THEN TRIM(CAST(bbl AS STRING)) END AS bbl,
       -- bin is a 7-digit building ID; values like '1000000' (borough digit + zeros) are placeholders -> NULL
       CASE
           WHEN REGEXP_CONTAINS(TRIM(CAST(bin AS STRING)), r'^\d{7}$')
            AND NOT REGEXP_CONTAINS(TRIM(CAST(bin AS STRING)), r'^\d000000$')
           THEN TRIM(CAST(bin AS STRING))
       END AS bin,
       TRIM(CAST(nta AS STRING)) AS nta,
       TRIM(CAST(census_tract AS STRING)) AS census_tract,
       TRIM(CAST(community_board AS STRING)) AS community_board,
       TRIM(CAST(council_district AS STRING)) AS council_district,

       -- Metadata
       CAST(record_date AS TIMESTAMP) AS record_date,  -- when NYC Open Data last refreshed the record; this one has a real time, so kept as TIMESTAMP
       DATE(CAST(record_date AS TIMESTAMP)) AS record_on,  -- [ERD] date-only version for record_date_key -> dim_date
       CURRENT_TIMESTAMP() AS _stg_loaded_at

   FROM source

   -- Filters
   WHERE camis IS NOT NULL
   AND inspection_date IS NOT NULL

   -- Restaurants that have NOT been inspected yet appear with inspection_date = 1900-01-01.
   -- They are not inspections, so they do not belong to this grain.
   AND DATE(CAST(inspection_date AS TIMESTAMP)) > DATE('1900-01-01')

   -- [GRAIN] project scope confirmed with the professor: 2020 to 2025.
   -- Same shared dbt variables as stg 311, so both datasets always cover the same period.
   AND DATE(CAST(inspection_date AS TIMESTAMP)) BETWEEN DATE('{{ var("start_date", "2020-01-01") }}')
                                                    AND DATE('{{ var("end_date", "2025-12-31") }}')

   -- Note: we do NOT filter out rows with missing borough / zip / coordinates here,
   -- because they are still real inspections and violations (e.g. airport and Grand Central locations).

   -- Deduplicate
   -- This dataset can contain exact repeated rows for the same violation. Keep one row per
   -- restaurant + inspection date + inspection type + violation code, preferring the most recently refreshed record.
   QUALIFY ROW_NUMBER() OVER (
       PARTITION BY camis, inspection_date, inspection_type, violation_code
       ORDER BY record_date DESC
   ) = 1
),

final AS (
   SELECT
       *,
       -- [ERD] inspection_key: one value per inspection (several violation rows share it).
       -- MD5 hex = 32 characters, matching varchar(32) keys in the ERD.
       -- This is the grain of fact_rstrnt_inspection.
       TO_HEX(MD5(CONCAT(camis, '|', CAST(inspection_date AS STRING), '|', COALESCE(inspection_type, 'UNKNOWN')))) AS inspection_key,

       -- [ERD] restaurant_address for dim_restaurants, in the same style as 311 incident_address
       -- (e.g. '123 MAIN STREET'), to help match 311 complaints to restaurants
       NULLIF(TRIM(CONCAT(COALESCE(building, ''), ' ', COALESCE(street, ''))), '') AS restaurant_address
   FROM cleaned
)

SELECT * FROM final

-- Queries to run in BQ before finalizing (replace the table name), to verify the assumptions above
-- and to have numbers for the documentation, as done for stg 311:

    -- Rows with no inspection yet (1900-01-01):
    -- SELECT COUNTIF(DATE(inspection_date) = '1900-01-01') AS not_inspected, COUNT(*) AS total_rows
    -- FROM `josedata26.nyc_restaurant_data_analysis.<primary raw table>`;

    -- Placeholder values in location fields:
    -- SELECT
    -- COUNTIF(boro = '0')                       AS boro_zero,
    -- COUNTIF(CAST(building AS STRING) = '0')   AS building_zero,
    -- COUNTIF(zipcode IS NULL)                  AS null_zip,
    -- COUNTIF(latitude = 0 OR latitude IS NULL) AS no_coordinates,
    -- COUNT(*)                                  AS total_rows
    -- FROM `josedata26.nyc_restaurant_data_analysis.<primary raw table>`;

    -- Distinct values of the categorical fields:
    -- SELECT grade, COUNT(*) FROM `josedata26.nyc_restaurant_data_analysis.<primary raw table>` GROUP BY grade;
    -- SELECT critical_flag, COUNT(*) FROM `josedata26.nyc_restaurant_data_analysis.<primary raw table>` GROUP BY critical_flag;

    -- Duplicates at the chosen grain (should be > 0 if dedup is needed, 0 after running the model):
    -- SELECT camis, inspection_date, inspection_type, violation_code, COUNT(*) AS n
    -- FROM `josedata26.nyc_restaurant_data_analysis.<primary raw table>`
    -- GROUP BY 1, 2, 3, 4 HAVING n > 1 ORDER BY n DESC;