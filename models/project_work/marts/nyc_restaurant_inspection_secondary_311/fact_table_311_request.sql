-- Fact table: DOHMH 311 service requests (restaurant complaints)
-- Grain: one row per service request (unique_key, deduplicated in the staging model)

WITH stg_311 AS (
    SELECT * FROM {{ ref('staging_311_secondary') }}
),

-- All the dimensions in their own CTEs for easy reference
dim_date AS (
    SELECT * FROM {{ ref('dim_date') }}
),

dim_location AS (
    SELECT * FROM {{ ref('dim_location') }}
),

dim_request_channel AS (
    SELECT * FROM {{ ref('dim_request_channel') }}
),

dim_complaint_type AS (
    SELECT * FROM {{ ref('dim_complaint_type') }}
),

fact AS (
    SELECT
        -- Surrogate key
        {{ dbt_utils.generate_surrogate_key(['s.unique_key']) }} AS request_key,

        -- Degenerate dimension (business identifier)
        s.unique_key AS unique_id,

        -- Foreign keys to dimensions
        -- COALESCE(..., '-1'): if a join finds no match, point to the 'unknown' row
        -- instead of leaving a NULL key (these keys are NOT NULL in the ERD)
        COALESCE(created_d.date_key, '-1')     AS created_date_key,
        -- Open requests have no closed date -> unknown member
        COALESCE(closed_d.date_key, '-1')      AS closed_date_key,
        COALESCE(l.location_key, '-1')         AS location_key,
        COALESCE(ct.complaint_type_key, '-1')  AS complaint_type_key,
        COALESCE(rc.request_channel_key, '-1') AS request_channel_key,

        -- Attributes passed on from staging
        s.location_type,
        s.incident_address,
        s.latitude,
        s.longitude,
        s.status AS request_status,
        s.resolution_description,

        -- Calculated fields
        s.status = 'CLOSED' AS is_closed

        -- Optional measure. If you add it, remember the comma after is_closed above.
        -- Old requests bulk-closed by DOHMH in June 2024 ("administratively closed") are set to NULL,
        -- because their closed_date is not a real response and would inflate the average.
        -- , CASE
        --       WHEN LOWER(s.resolution_description) LIKE '%administratively closed%' THEN NULL
        --       ELSE TIMESTAMP_DIFF(s.closed_date, s.created_date, HOUR)
        --   END AS hours_to_close

    FROM stg_311 s

    -- LEFT JOINs keep every request from staging, even if a dimension has no match.
    -- Join on the same columns the dimension uses to build its surrogate key.
    LEFT JOIN dim_date created_d
        ON CAST(s.created_date AS DATE) = created_d.full_date

    LEFT JOIN dim_date closed_d
        ON CAST(s.closed_date AS DATE) = closed_d.full_date

    -- IS NOT DISTINCT FROM so a NULL zipcode still matches the dimension row with a NULL zipcode
    LEFT JOIN dim_location l
        ON  s.borough IS NOT DISTINCT FROM l.borough
        AND s.zipcode IS NOT DISTINCT FROM l.zipcode

    -- Same cleaning as in dim_request_channel, so the values match
    LEFT JOIN dim_request_channel rc
        ON UPPER(TRIM(s.method_of_submission)) = rc.channel_type

    -- IS NOT DISTINCT FROM so a NULL descriptor still matches
    LEFT JOIN dim_complaint_type ct
        ON  s.complaint_type IS NOT DISTINCT FROM ct.complaint_type
        AND s.descriptor     IS NOT DISTINCT FROM ct.descriptor
)

SELECT * FROM fact