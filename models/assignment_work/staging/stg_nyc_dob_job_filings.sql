-- Clean and standardize DOB NOW Build job application filings
-- One row per job filing
 
WITH source AS (
   SELECT * FROM {{ source('raw', 'source_nyc_dob_job_apps') }}
), -- Easier to refer to the dbt reference to a long name table this way
 
cleaned AS (
   SELECT
       -- Get all columns from source, except ones we're transforming below
       -- To do cleaning on them or explicitly cast them as types just in case
       * EXCEPT (
           job_filing_number,
           filing_status,
           job_type,
           job_description,
           filing_date,
           approved_date,
           first_permit_date,
           signoff_date,
           current_status_date,
           house_no,
           street_name,
           borough,
           postcode,
           zip,  -- raw "zip" is the building OWNER's zip, not needed; job-site zip comes from postcode
           bin,
           commmunity_board,
           council_district,
           latitude,
           longitude,
           curb_cut_work_type,
           sidewalk_shed_work_type,
           scaffold_work_type,
           fence_work_type,
           shed_work_type
       ),
 
       -- Identifiers
       UPPER(TRIM(CAST(job_filing_number AS STRING))) AS job_filing_number,
 
       -- Parse the filing number suffix (e.g. B00123456-I1):
       -- I = Initial, P = Post Approval Amendment, S = Subsequent, + sequence number
       CASE REGEXP_EXTRACT(UPPER(job_filing_number), r'-([A-Z])\d+$')
           WHEN 'I' THEN 'Initial'
           WHEN 'P' THEN 'Post Approval Amendment'
           WHEN 'S' THEN 'Subsequent'
           ELSE NULL
       END AS filing_type,
       SAFE_CAST(REGEXP_EXTRACT(job_filing_number, r'-[A-Za-z](\d+)$') AS INT64) AS filing_sequence,
 
       -- Date/Time
       CAST(filing_date AS TIMESTAMP) AS filing_date,
       CAST(approved_date AS TIMESTAMP) AS approved_date,
       CAST(first_permit_date AS TIMESTAMP) AS first_permit_date,
       CAST(signoff_date AS TIMESTAMP) AS signoff_date,
       CAST(current_status_date AS TIMESTAMP) AS current_status_date,
 
       -- Filing details
       UPPER(TRIM(CAST(filing_status AS STRING))) AS filing_status,
       TRIM(CAST(job_type AS STRING)) AS job_type,
       TRIM(CAST(job_description AS STRING)) AS job_description,
 
       -- Location - clean zip code (renamed postcode -> zip to match 311 data)
       CASE
           WHEN UPPER(TRIM(CAST(postcode AS STRING))) IN ('N/A', 'NA', '') THEN NULL
           WHEN LENGTH(TRIM(CAST(postcode AS STRING))) = 5 THEN TRIM(CAST(postcode AS STRING))
           WHEN LENGTH(TRIM(CAST(postcode AS STRING))) = 9 THEN TRIM(CAST(postcode AS STRING))
           WHEN LENGTH(TRIM(CAST(postcode AS STRING))) = 10
               AND REGEXP_CONTAINS(TRIM(CAST(postcode AS STRING)), r'^\d{5}-\d{4}$')
           THEN TRIM(CAST(postcode AS STRING))
           ELSE NULL
       END AS zip,
 
       -- Location - standardized borough, same values as 311 data
       -- Falls back to the first letter of the job filing number if borough is missing
       -- (B=Brooklyn, M=Manhattan, Q=Queens, S=Staten Island, X=Bronx)
       CASE
           WHEN UPPER(TRIM(borough)) IN ('MANHATTAN', 'NEW YORK COUNTY')
               OR (borough IS NULL AND STARTS_WITH(UPPER(job_filing_number), 'M')) THEN 'Manhattan'
           WHEN UPPER(TRIM(borough)) IN ('BRONX', 'THE BRONX')
               OR (borough IS NULL AND STARTS_WITH(UPPER(job_filing_number), 'X')) THEN 'Bronx'
           WHEN UPPER(TRIM(borough)) IN ('BROOKLYN', 'KINGS COUNTY')
               OR (borough IS NULL AND STARTS_WITH(UPPER(job_filing_number), 'B')) THEN 'Brooklyn'
           WHEN UPPER(TRIM(borough)) IN ('QUEENS', 'QUEEN', 'QUEENS COUNTY')
               OR (borough IS NULL AND STARTS_WITH(UPPER(job_filing_number), 'Q')) THEN 'Queens'
           WHEN UPPER(TRIM(borough)) IN ('STATEN ISLAND', 'RICHMOND COUNTY')
               OR (borough IS NULL AND STARTS_WITH(UPPER(job_filing_number), 'S')) THEN 'Staten Island'
           ELSE 'UNKNOWN or CITYWIDE'
       END AS borough,
 
       -- Address - full address built to match 311's incident_address, plus street_name
       NULLIF(TRIM(CONCAT(COALESCE(TRIM(house_no), ''), ' ', COALESCE(TRIM(street_name), ''))), '') AS incident_address,
       TRIM(CAST(house_no AS STRING)) AS house_no,
       UPPER(TRIM(CAST(street_name AS STRING))) AS street_name,
 
       -- Other location identifiers
       TRIM(CAST(bin AS STRING)) AS bin,
       TRIM(CAST(commmunity_board AS STRING)) AS community_board,  -- fix triple-m typo from source
       TRIM(CAST(council_district AS STRING)) AS council_district,
       CAST(latitude AS DECIMAL) AS latitude,
       CAST(longitude AS DECIMAL) AS longitude,
 
       -- Work types - convert YES/NO and TRUE/FALSE text into real booleans
       CASE
           WHEN UPPER(TRIM(CAST(curb_cut_work_type AS STRING))) IN ('YES', 'Y', 'TRUE', '1') THEN TRUE
           WHEN UPPER(TRIM(CAST(curb_cut_work_type AS STRING))) IN ('NO', 'N', 'FALSE', '0') THEN FALSE
           ELSE NULL
       END AS is_curb_cut_work,
       CASE
           WHEN UPPER(TRIM(CAST(sidewalk_shed_work_type AS STRING))) IN ('YES', 'Y', 'TRUE', '1') THEN TRUE
           WHEN UPPER(TRIM(CAST(sidewalk_shed_work_type AS STRING))) IN ('NO', 'N', 'FALSE', '0') THEN FALSE
           ELSE NULL
       END AS is_sidewalk_shed_work,
       CASE
           WHEN UPPER(TRIM(CAST(scaffold_work_type AS STRING))) IN ('YES', 'Y', 'TRUE', '1') THEN TRUE
           WHEN UPPER(TRIM(CAST(scaffold_work_type AS STRING))) IN ('NO', 'N', 'FALSE', '0') THEN FALSE
           ELSE NULL
       END AS is_scaffold_work,
       CASE
           WHEN UPPER(TRIM(CAST(fence_work_type AS STRING))) IN ('YES', 'Y', 'TRUE', '1') THEN TRUE
           WHEN UPPER(TRIM(CAST(fence_work_type AS STRING))) IN ('NO', 'N', 'FALSE', '0') THEN FALSE
           ELSE NULL
       END AS is_fence_work,
       CASE
           WHEN UPPER(TRIM(CAST(shed_work_type AS STRING))) IN ('YES', 'Y', 'TRUE', '1') THEN TRUE
           WHEN UPPER(TRIM(CAST(shed_work_type AS STRING))) IN ('NO', 'N', 'FALSE', '0') THEN FALSE
           ELSE NULL
       END AS is_shed_work,
 
       -- Metadata
       CURRENT_TIMESTAMP() AS _stg_loaded_at
 
   FROM source
 
   -- Filters
   WHERE job_filing_number IS NOT NULL
   AND filing_date IS NOT NULL
   AND CAST(filing_date AS DATE) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 YEAR)  -- same window as 311 data
 
   -- Deduplicate - keep the most recent record per job filing number
   QUALIFY ROW_NUMBER() OVER (
       PARTITION BY job_filing_number
       ORDER BY filing_date DESC, first_permit_date DESC
   ) = 1
)
 
SELECT * FROM cleaned
-- All should be part of this table after running: stg_nyc_dob_job_filings
 