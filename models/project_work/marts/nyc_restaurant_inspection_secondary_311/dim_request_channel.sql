-- Request Channel dimension for DOHMH 311 service requests (restaurant complaints).
-- Grain: one row per channel type (e.g. PHONE, ONLINE, MOBILE),
-- plus one '-1' row for requests with an unknown channel.

WITH stg_311 AS (
    SELECT * FROM {{ ref('staging_311_secondary') }}
),

distinct_channels AS (
    -- UPPER(TRIM()) so 'Phone' and 'PHONE ' do not become two different channels
    SELECT DISTINCT
        UPPER(TRIM(method_of_submission)) AS channel_type
    FROM stg_311
    WHERE method_of_submission IS NOT NULL
      AND TRIM(method_of_submission) != ''
),

dim_request_channel AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['channel_type']) }} AS request_channel_key,
        channel_type
    FROM distinct_channels
),

unknown_member AS (
    -- Used by the fact table when a request has no channel
    SELECT
        '-1'      AS request_channel_key,
        'UNKNOWN' AS channel_type
)

SELECT * FROM dim_request_channel
UNION ALL
SELECT * FROM unknown_member
