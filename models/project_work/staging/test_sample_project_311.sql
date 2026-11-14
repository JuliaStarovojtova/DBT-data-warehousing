 -- Quick test to verify source connection works
 SELECT
     unique_key,
     created_date,
     complaint_type,
     borough
 FROM {{ source('raw', 'nyc_restaurant_inspection_secondary_311') }}
 LIMIT 10