-- Location dimension shared (conformed) by 311 service requests and restaurant inspections.
-- Grain: one row per distinct (borough, zipcode) combination found in either staging model,
-- plus one '-1' row for an unknown location.
-- Columns follow the ERD: location_key, borough, zipcode.
-- Both staging models use the same borough mapping and the same 5-digit zipcode rule,
-- so the same place gets the same location_key in both fact tables.

WITH stg_311 AS (
    SELECT * FROM {{ ref('staging_311_secondary') }}
),

stg_restaurant AS (
    SELECT * FROM {{ ref('staging_restaurant_primary') }}
),

all_locations AS (
    -- 311 service request locations
    SELECT borough, zipcode
    FROM stg_311

    UNION DISTINCT

    -- Restaurant inspection locations
    SELECT borough, zipcode
    FROM stg_restaurant
),

dim_location AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['borough', 'zipcode']) }} AS location_key,
        borough,
        zipcode      -- can be NULL (e.g. 'Manhattan' with no zip); that combination is still a valid row
    FROM all_locations
),

unknown_member AS (
    -- Used by the fact tables when a location cannot be matched
    SELECT
        '-1'                 AS location_key,
        'UNKNOWN'            AS borough,
        CAST(NULL AS STRING) AS zipcode
)

SELECT * FROM dim_location
UNION ALL
SELECT * FROM unknown_member

-- The fact tables join with IS NOT DISTINCT FROM, so a row with a NULL zipcode matches the
-- dimension row with the same borough and a NULL zipcode:
--   LEFT JOIN dim_location l
--       ON  s.borough IS NOT DISTINCT FROM l.borough
--       AND s.zipcode IS NOT DISTINCT FROM l.zipcode
