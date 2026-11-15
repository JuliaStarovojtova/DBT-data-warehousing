-- Location dimension shared by both data sources
-- Grain: one row per distinct combination of borough and zip code.

WITH stg_311 AS (
    SELECT * FROM {{ ref('staging_311_secondary') }}
),

stg_restaurant AS (
    SELECT * FROM {{ ref('staging_restaurant_primary') }}
),

all_locations AS (
    SELECT DISTINCT
        borough,
        zipcode
    FROM stg_311
    WHERE borough IS NOT NULL
       OR zipcode IS NOT NULL
    UNION DISTINCT
    SELECT DISTINCT
        borough,
        zipcode
    FROM stg_restaurant
    WHERE borough IS NOT NULL
       OR zipcode IS NOT NULL
),

location_dimension AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key([
            'borough', 'zipcode'
        ]) }} AS location_key,
        borough,
        zipcode
    FROM all_locations
),

null_placeholder AS (
    SELECT
        '-1' AS location_key,
        CAST(NULL AS STRING) AS borough,
        CAST(NULL AS STRING) AS zipcode
)

SELECT * FROM location_dimension
UNION ALL
SELECT * FROM null_placeholder