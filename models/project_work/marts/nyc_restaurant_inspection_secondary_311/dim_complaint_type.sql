-- Complaint type dimension for DOHMH 311 service requests (restaurant complaints).
-- Grain: one row per distinct (complaint_type, descriptor) combination,
-- plus one '-1' row for requests with an unknown complaint type.

WITH stg_311 AS (
    SELECT * FROM {{ ref('staging_311_secondary') }}
),

distinct_complaint_types AS (
    SELECT DISTINCT
        complaint_type,
        descriptor
    FROM stg_311
    WHERE complaint_type IS NOT NULL
),

enriched AS (
    SELECT
        complaint_type,
        descriptor,

        -- Derived category, based on complaint_type first, then keywords in descriptor.
        -- Order matters: the first matching rule wins, so the more specific rules go first
        -- and the broad '%food%' rule goes last.
        -- LOWER() makes the match case-insensitive, so all patterns are written in lowercase.
        CASE
            WHEN complaint_type = 'Food Poisoning'                THEN 'Food Poisoning'
            WHEN LOWER(descriptor) LIKE '%permit%'
              OR LOWER(descriptor) LIKE '%license%'               THEN 'No Permit'
            WHEN LOWER(descriptor) LIKE '%handwashing%'
              OR LOWER(descriptor) LIKE '%hands%'                 THEN 'Handwashing'
            WHEN LOWER(descriptor) LIKE '%animal%'
              OR LOWER(descriptor) LIKE '%pet%'                   THEN 'Animal'
            WHEN LOWER(descriptor) LIKE '%worker%'                THEN 'Worker Issues'
            WHEN LOWER(descriptor) LIKE '%allerg%'                THEN 'Allergy Info'
            WHEN LOWER(descriptor) LIKE '%sewage%'
              OR LOWER(descriptor) LIKE '%water%'
              OR LOWER(descriptor) LIKE '%plumbing%'              THEN 'Sewage/Water/Plumbing'
            WHEN LOWER(descriptor) LIKE '%toxic%'
              OR LOWER(descriptor) LIKE '%pesticide%'             THEN 'Toxic Chemicals/Materials'
            WHEN LOWER(descriptor) LIKE '%odor%'                  THEN 'Odor'
            WHEN LOWER(descriptor) LIKE '%smoking%'               THEN 'Smoking'
            WHEN LOWER(descriptor) LIKE '%ventilation%'           THEN 'Ventilation'
            WHEN LOWER(descriptor) LIKE '%food%'                  THEN 'Food Related'   -- broad rule, kept near the end
            ELSE 'Other'
        END AS complaint_category

    FROM distinct_complaint_types
),

dim_complaint_type AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['complaint_type', 'descriptor']) }} AS complaint_type_key,
        complaint_type,
        descriptor,
        complaint_category
    FROM enriched
),

unknown_member AS (
    -- Used by the fact table when a request has no complaint type
    SELECT
        '-1'                 AS complaint_type_key,
        'UNKNOWN'            AS complaint_type,
        CAST(NULL AS STRING) AS descriptor,
        'Unknown'            AS complaint_category
)

SELECT * FROM dim_complaint_type
UNION ALL
SELECT * FROM unknown_member


