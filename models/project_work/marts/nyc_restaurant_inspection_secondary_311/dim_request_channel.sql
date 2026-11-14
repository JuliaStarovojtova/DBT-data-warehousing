-- 311 Request Channel dimension for DOT 311 service requests.
-- Grain: one row per one channel type. 

WITH stg_311 AS (
    SELECT * FROM {{ ref('staging_311_secondary') }}
),

distinct_channels AS (

    SELECT DISTINCT
        method_of_submission
        
    FROM stg_311
    WHERE method_of_submission IS NOT NULL

),


dim_request_channel AS (

    SELECT
        {{ dbt_utils.generate_surrogate_key([
            'method_of_submission'
        ]) }} AS request_channel_key,

       method_of_submission AS channel_type

    FROM distinct_channels

)

SELECT * FROM dim_request_channel