-- Violation type dimension for NYC DOHMH restaurant inspections.
-- Grain: one row per violation_code, plus two special rows:
--   '-1' = unknown violation (a code that could not be matched)
--   '-2' = no violation (inspections where nothing was cited; violation_code is NULL in staging)
-- Columns: violation_type_key, violation_code, violation_description, critical_flag.
-- violation_description was moved here from fact_rstrnt_inspection, because it describes the
-- violation code, not the individual inspection (update the ERD accordingly).

WITH stg_restaurant AS (
    SELECT * FROM {{ ref('staging_restaurant_primary') }}
),

latest_per_code AS (
    SELECT
        violation_code,
        violation_description,
        critical_flag
    FROM stg_restaurant
    WHERE violation_code IS NOT NULL

    -- One row per code. DOHMH has revised violation wording over the years, so the same code
    -- can appear with slightly different descriptions (or flags). Keep the version from the
    -- most recent inspection. Run the check query at the bottom to see how often this happens.
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY violation_code
        ORDER BY inspection_date DESC, record_date DESC
    ) = 1
),

dim_violation_type AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['violation_code']) }} AS violation_type_key,
        violation_code,
        violation_description,
        critical_flag
    FROM latest_per_code
),

special_members AS (
    -- Used by the fact table when a violation code cannot be matched
    SELECT
        '-1'                         AS violation_type_key,
        'UNKNOWN'                    AS violation_code,
        'Unknown violation'          AS violation_description,
        'Unknown'                    AS critical_flag

    UNION ALL

    -- Used by the fact table for inspections with no violations cited (violation_code IS NULL)
    SELECT
        '-2'                         AS violation_type_key,
        'NONE'                       AS violation_code,
        'No violations were cited'   AS violation_description,
        'Not Applicable'             AS critical_flag
)

SELECT * FROM dim_violation_type
UNION ALL
SELECT * FROM special_members

-- In fact_rstrnt_inspection:
--   1) REMOVE s.violation_description (it now lives in this dimension)
--   2) build the key like this:
--        CASE
--            WHEN s.violation_code IS NULL THEN '-2'               -- inspection with no violations
--            ELSE COALESCE(v.violation_type_key, '-1')             -- unmatched code -> unknown
--        END AS violation_type_key
--        ...
--        LEFT JOIN dim_violation_type v   (use ref('dim_violation_type') with double curly braces in the fact model)
--            ON s.violation_code = v.violation_code

-- Checks to run in BigQuery (results are useful for the documentation):
--   Codes with more than one description or critical flag in 2020-2025:
--   SELECT violation_code,
--          COUNT(DISTINCT violation_description) AS n_descriptions,
--          COUNT(DISTINCT critical_flag)         AS n_flags
--   FROM `yuliastarovoytova01.nyc_restaurant_data_analysis_staging.staging_restaurant_primary`
--   GROUP BY violation_code
--   HAVING n_descriptions > 1 OR n_flags > 1
--   ORDER BY n_descriptions DESC;
