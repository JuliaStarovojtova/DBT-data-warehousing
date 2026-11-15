-- Fact table: NYC DOHMH restaurant inspections, 2020-2025
-- Grain: one row per violation cited during one restaurant inspection
--   (inspections with no violations = one row with violation_type_key '-2').
--   Because the ERD keeps violation_type_key in this table, an inspection with 3 violations has 3 rows.
--   inspection_key identifies the INSPECTION and is shared by those rows, so:
--     * count inspections with COUNT(DISTINCT inspection_key), not COUNT(*)
--     * score and grade belong to the inspection and repeat on every violation row:
--       de-duplicate per inspection_key before averaging them
--   inspection_violation_key is the unique row key (primary key) of this table.

WITH stg_restaurant AS (
    SELECT * FROM {{ ref('staging_restaurant_primary') }}
),

-- All the dimensions in their own CTEs for easy reference
dim_date AS (
    SELECT * FROM {{ ref('dim_date') }}
),

dim_location AS (
    SELECT * FROM {{ ref('dim_location') }}
),

dim_restaurants AS (
    SELECT * FROM {{ ref('dim_restaurant') }}
),

dim_violation_type AS (
    SELECT * FROM {{ ref('dim_violation_type') }}
),

fact AS (
    SELECT
        -- Primary key: one value per violation row (inspection + violation code)
        {{ dbt_utils.generate_surrogate_key(['s.inspection_key', 's.violation_code']) }} AS inspection_violation_key,

        -- Inspection identifier (built in staging from camis + inspection_date + inspection_type);
        -- shared by all violation rows of the same inspection
        s.inspection_key,

        -- Degenerate dimension (business identifier of the restaurant)
        s.camis AS camis_id,

        -- Foreign keys to dimensions
        -- COALESCE(..., '-1'): if a join finds no match, point to the 'unknown' row
        -- instead of leaving a NULL key (these keys are NOT NULL in the ERD)
        COALESCE(insp_d.date_key, '-1')     AS inspection_date_key,
        COALESCE(rec_d.date_key, '-1')      AS record_date_key,
        COALESCE(l.location_key, '-1')      AS location_key,
        COALESCE(r.restaurant_key, '-1')    AS restaurant_key,
        CASE
            WHEN s.violation_code IS NULL THEN '-2'              -- inspection with no violations cited
            ELSE COALESCE(v.violation_type_key, '-1')            -- unmatched code -> unknown
        END                                 AS violation_type_key,

        -- Inspection attributes and measures
        s.inspection_type,                  -- not in the ERD yet: Initial vs Re-inspection matters for score/grade analysis
        s.action AS outcome_action,
        s.score,
        s.grade,
        s.cuisine_description,

        -- Location attributes passed on from staging
        s.latitude,
        s.longitude,
        s.nta

        -- violation_description is NOT here: it now lives in dim_violation_type

    FROM stg_restaurant s

    -- LEFT JOINs keep every row from staging, even if a dimension has no match.
    -- Join on the same columns the dimension uses to build its surrogate key.
    LEFT JOIN dim_date insp_d
        ON s.inspection_date = insp_d.full_date            -- inspection_date is already a DATE in staging

    LEFT JOIN dim_date rec_d
        ON DATE(s.record_date) = rec_d.full_date            -- record_date is a TIMESTAMP in staging

    -- IS NOT DISTINCT FROM so a NULL zipcode still matches the dimension row with a NULL zipcode
    LEFT JOIN dim_location l
        ON  s.borough IS NOT DISTINCT FROM l.borough
        AND s.zipcode IS NOT DISTINCT FROM l.zipcode

    LEFT JOIN dim_restaurants r
        ON s.camis = r.camis_id

    LEFT JOIN dim_violation_type v
        ON s.violation_code = v.violation_code
)

SELECT * FROM fact