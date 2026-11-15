-- Restaurant dimension for NYC DOHMH restaurant inspections.
-- Grain: one row per restaurant (camis_id), plus one '-1' row for an unknown restaurant.
-- Columns follow the ERD: restaurant_key, camis_id, dba_name, restaurant_address, bin.
--
-- The raw data has many rows per restaurant (one per violation per inspection), and a restaurant's
-- name or address can change over time. This dimension keeps the MOST RECENT version
-- of each restaurant's attributes (from its latest inspection).

WITH stg_restaurant AS (
    SELECT * FROM {{ ref('staging_restaurant_primary') }}
),

latest_per_restaurant AS (
    SELECT
        camis                AS camis_id,            -- business ID from NYC Open Data (CAMIS)
        dba_name,                                     -- "doing business as" name
        restaurant_address,                           -- building + street, e.g. '123 MAIN STREET'
        bin                                           -- building ID (NULL when the source only had a placeholder)
        -- cuisine_description is NOT here: per the ERD it lives in fact_rstrnt_inspection
    FROM stg_restaurant
    WHERE camis IS NOT NULL

    -- Keep one row per restaurant: the most recent inspection, then the most recently refreshed record
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY camis
        ORDER BY inspection_date DESC, record_date DESC
    ) = 1
),

dim_restaurants AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['camis_id']) }} AS restaurant_key,
        camis_id,
        dba_name,
        restaurant_address,
        bin
    FROM latest_per_restaurant
),

unknown_member AS (
    -- Used by the fact table when an inspection cannot be matched to a restaurant
    SELECT
        '-1'                 AS restaurant_key,
        CAST(NULL AS STRING) AS camis_id,
        'UNKNOWN'            AS dba_name,
        CAST(NULL AS STRING) AS restaurant_address,
        CAST(NULL AS STRING) AS bin
)

SELECT * FROM dim_restaurants
UNION ALL
SELECT * FROM unknown_member

