-- Complaint type dimension for DOT 311 service requests.
-- Grain: one row per distinct (complaint_type, descriptor) combination.

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

        -- Derived category, based on keywords appearing in descriptor
        -- Order matters due to CASE WHEN structure (worth considering)
        -- Match is case insensitive

        CASE
            WHEN LOWER(descriptor) LIKE '% or %' THEN 'Food Poisoning'
            WHEN LOWER(descriptor) LIKE '%food%' THEN 'Food related'
            WHEN LOWER(descriptor) LIKE '%animal%' THEN 'Animal'
            WHEN LOWER(descriptor) LIKE '%permit%' THEN 'No permit'
            WHEN LOWER(descriptor) LIKE '%odor%' THEN 'Odor'
            WHEN LOWER(descriptor) LIKE '%smoking%' THEN 'Smoking'
            WHEN LOWER(descriptor) LIKE '%handwashing%' THEN 'Handwashing'
            WHEN LOWER(descriptor) LIKE '%ventilation%' THEN 'Ventilation'
            WHEN LOWER(descriptor) LIKE '%worker%' THEN 'Worker issues'
            WHEN LOWER(descriptor) LIKE '%allergy%' THEN 'Allergy info'
            WHEN LOWER(descriptor) LIKE '%wewage%' THEN 'Sewage/Water/Plumbing'
            WHEN LOWER(descriptor) LIKE '%toxic%' THEN 'Toxic Chemicals/Materials'
            WHEN LOWER(descriptor) LIKE '%water%' THEN 'Sewage/Water/Plumbing'
            WHEN LOWER(descriptor) LIKE '%plumbing%' THEN 'Sewage/Water/Plumbing'
            WHEN LOWER(descriptor) LIKE '%pesticide%' THEN 'Toxic Chemicals/Materials'
            WHEN LOWER(descriptor) LIKE '%Other%' THEN 'other'

            ELSE 'other'
        END AS complaint_detail

    FROM distinct_complaint_types

),

dim_complaint_type AS (

    SELECT
        {{ dbt_utils.generate_surrogate_key([
            'complaint_type', 'descriptor'
        ]) }} AS complaint_type_key,

        complaint_type,
        descriptor,
        complaint_detail

    FROM enriched

)

SELECT * FROM dim_complaint_type