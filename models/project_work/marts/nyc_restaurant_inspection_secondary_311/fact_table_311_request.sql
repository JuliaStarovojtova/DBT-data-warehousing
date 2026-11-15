-- Fact table: DOT 311 service requests
-- Grain: one row per service request (request_id, controlled in staging model)

WITH stg_311 AS (
    SELECT * FROM {{ ref('staging_311_secondary') }}
),

-- All the dimensions in their own CTEs for easy reference
dim_date AS (
    SELECT * 
    FROM {{ ref('dim_date') }}
),

dim_location AS (
    SELECT * 
    FROM {{ ref('dim_location') }}
),

dim_request_channel AS (
    SELECT * FROM {{ ref('dim_request_channel')}}
),

dim_complaint_type AS (
    SELECT * FROM {{ ref('dim_complaint_type')}}
),

-- Build initial CTE for fact table
fact AS (
    
    SELECT
        -- request_key (surrogate key)
        {{ dbt_utils.generate_surrogate_key(['s.unique_key']) }} AS request_key,
        --Degenerate dimension (business identifier)
        -- unique_id
        s.unique_key as unique_id,
        -- created_date_key
        created_d.date_key AS created_date_key,
        -- closed_date_key
        -- Open requests have no closed date -> unknown memeber
        CASE WHEN s.closed_date IS NULL THEN '-1' ELSE closed_d.date_key END AS close_date_key, 
        -- location_key (Always will have a location key)
        l.location_key,
        -- complaint_type_key
        ct.complaint_type_key,
        -- request_channel_key
        rc.request_channel_key,

        -- Plus the data we're passing on right from staging -> fact table
        s.location_type,
        s.incident_address,
        s.latitude,
        s.longitude,
        s.status AS request_status,
        s.resolution_description,

        -- Calculated fields
        s.status = 'CLOSED' AS is_closed

        --timestamp_diff(s.closed_date, s.created_date, HOUR) AS hours_to_close  
    
    FROM stg_311 s

    -- Left join because you want all the rows from staging table..
    -- JOIN ON the itmes that make up surrogate key in the dimension
    LEFT JOIN dim_date created_d
        ON CAST(s.created_date AS DATE) = created_d.full_date
    LEFT JOIN dim_date closed_d
        ON CAST(s.closed_date AS DATE) = closed_d.full_date

    -- IS NOT DISTINCT FROM so a NULL zip/ council_district matches  
    -- Could leave out the NULL exception and make these =s
    LEFT JOIN dim_location l
        ON s.borough    IS NOT DISTINCT FROM l.borough
        
        AND s.zipcode   IS NOT DISTINCT FROM l.zipcode
    
    LEFT JOIN dim_request_channel rc
        ON s.method_of_submission IS NOT DISTINCT FROM rc.channel_type
        

    LEFT JOIN dim_complaint_type ct
        ON s.complaint_type IS NOT DISTINCT FROM ct.complaint_type
        AND s.descriptor    IS NOT DISTINCT FROM ct.descriptor

)

SELECT * FROM fact