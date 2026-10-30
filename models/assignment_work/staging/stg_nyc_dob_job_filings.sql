
-- Clean and standardize DOB NOW Job Application Filings data
-- One row per job filing

WITH source AS (
   SELECT * FROM {{ source('dob_raw', 'source_nyc_dob_job_apps') }}
), -- Easier to refer to the dbt reference to a long name table this way

cleaned AS (
   SELECT
       -- Get all columns from source, except ones we're transforming below
       -- To do cleaning on them or explicitly cast them as types just in case
       * EXCEPT (
           job_filing_number,
           filing_date,
           current_status_date,
           filing_status,
           job_type,
           job_description,
           postcode,
           borough,
           house_no,
           street_name,
           latitude,
           longitude,
           initial_cost,
           total_construction_floor_area
       ),

       -- Identifiers
       CAST(job_filing_number AS STRING) AS filing_id,

       -- Date/Time
       SAFE_CAST(filing_date AS TIMESTAMP) AS filing_date,
       SAFE_CAST(current_status_date AS TIMESTAMP) AS current_status_date,

       -- Job filing details
       CAST(job_type AS STRING) AS job_type,
       CAST(job_description AS STRING) AS job_description,
       UPPER(TRIM(CAST(filing_status AS STRING))) AS status,

       -- Location - clean zip code, handling several common zip code data problems
       CASE
           WHEN UPPER(TRIM(CAST(postcode AS STRING))) IN ('N/A', 'NA') THEN NULL
           WHEN UPPER(TRIM(CAST(postcode AS STRING))) = 'ANONYMOUS' THEN 'Anonymous'
           WHEN LENGTH(CAST(postcode AS STRING)) = 5 THEN CAST(postcode AS STRING)
           WHEN LENGTH(CAST(postcode AS STRING)) = 9 THEN CAST(postcode AS STRING)
           WHEN LENGTH(CAST(postcode AS STRING)) = 10
               AND REGEXP_CONTAINS(CAST(postcode AS STRING), r'^\d{5}-\d{4}')
           THEN CAST(postcode AS STRING)
           ELSE NULL
       END AS zip,

       -- Location - standardized borough, just in case
       CASE
           WHEN UPPER(TRIM(borough)) IN ('MANHATTAN', 'NEW YORK COUNTY') THEN 'Manhattan'
           WHEN UPPER(TRIM(borough)) IN ('BRONX', 'THE BRONX') THEN 'Bronx'
           WHEN UPPER(TRIM(borough)) IN ('BROOKLYN', 'KINGS COUNTY') THEN 'Brooklyn'
           WHEN UPPER(TRIM(borough)) IN ('QUEENS', 'QUEEN', 'QUEENS COUNTY') THEN 'Queens'
           WHEN UPPER(TRIM(borough)) IN ('STATEN ISLAND', 'RICHMOND COUNTY') THEN 'Staten Island'
           ELSE 'UNKNOWN or CITYWIDE'
       END AS borough,

       CAST(house_no AS STRING) AS house_number,
       CAST(street_name AS STRING) AS street_name,

       -- Combine house number and street name into one address
       CONCAT(
           TRIM(CAST(house_no AS STRING)),
           ' ',
           TRIM(CAST(street_name AS STRING))
       ) AS incident_address,

       CAST(latitude AS DECIMAL) AS latitude,
       CAST(longitude AS DECIMAL) AS longitude,

       -- Construction details
       SAFE_CAST(initial_cost AS NUMERIC) AS initial_cost,
       SAFE_CAST(total_construction_floor_area AS NUMERIC) AS construction_floor_area,

       -- Metadata
       CURRENT_TIMESTAMP() AS _stg_loaded_at

   FROM source

   -- Filters
   WHERE job_filing_number IS NOT NULL
   AND filing_date IS NOT NULL
   AND DATE(SAFE_CAST(filing_date AS TIMESTAMP)) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 YEAR)
   AND borough IS NOT NULL

   -- Deduplicate
   QUALIFY ROW_NUMBER() OVER (PARTITION BY job_filing_number ORDER BY current_status_date DESC) = 1
)

SELECT * FROM cleaned
-- All should be part of this table after running: stg_nyc_dob_job_filings

