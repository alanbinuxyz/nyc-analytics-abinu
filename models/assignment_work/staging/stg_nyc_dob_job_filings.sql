
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
          postcode,
          zip,
          borough,
          house_no,
          street_name,
          initial_cost,
          total_construction_floor_area,
          latitude,
          longitude
      ),

      -- Identifiers
      CAST(job_filing_number AS STRING) AS filing_id,

      -- Date/Time
      SAFE_CAST(filing_date AS TIMESTAMP) AS filing_date,
      SAFE_CAST(current_status_date AS TIMESTAMP) AS current_status_date,

      -- Job filing details
      CAST(job_type AS STRING) AS job_type,
      UPPER(TRIM(CAST(filing_status AS STRING))) AS status,

      -- Location - clean zip code, handling several common zip code data problems
      -- Postcode is the building, while zip is the applicant 
      CASE
          WHEN UPPER(TRIM(CAST(postcode AS STRING))) IN ('N/A', 'NA') THEN NULL
          WHEN UPPER(TRIM(CAST(postcode AS STRING))) = 'ANONYMOUS' THEN 'Anonymous'
          WHEN REGEXP_CONTAINS(TRIM(CAST(postcode AS STRING)), r'^\d{5}$')
              THEN TRIM(CAST(postcode AS STRING))
          WHEN REGEXP_CONTAINS(TRIM(CAST(postcode AS STRING)), r'^\d{9}$')
              THEN SUBSTR(TRIM(CAST(postcode AS STRING)), 1, 5)
          WHEN REGEXP_CONTAINS(TRIM(CAST(postcode AS STRING)), r'^\d{5}-\d{4}$')
              THEN SUBSTR(TRIM(CAST(postcode AS STRING)), 1, 5)
          ELSE NULL
      END AS zip,

      -- Location - standardized borough, just in case
      CASE
          WHEN UPPER(TRIM(CAST(borough AS STRING))) IN ('MANHATTAN', 'NEW YORK COUNTY') THEN 'Manhattan'
          WHEN UPPER(TRIM(CAST(borough AS STRING))) IN ('BRONX', 'THE BRONX') THEN 'Bronx'
          WHEN UPPER(TRIM(CAST(borough AS STRING))) IN ('BROOKLYN', 'KINGS COUNTY') THEN 'Brooklyn'
          WHEN UPPER(TRIM(CAST(borough AS STRING))) IN ('QUEENS', 'QUEEN', 'QUEENS COUNTY') THEN 'Queens'
          WHEN UPPER(TRIM(CAST(borough AS STRING))) IN ('STATEN ISLAND', 'RICHMOND COUNTY') THEN 'Staten Island'
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

      -- Preserve applicant ZIP under a clearer column name
      CAST(zip AS STRING) AS applicant_zip,

      -- Job costs and construction details
      SAFE_CAST(
          REGEXP_REPLACE(CAST(initial_cost AS STRING), r'[$,]', '')
          AS NUMERIC
      ) AS initial_cost,

      SAFE_CAST(total_construction_floor_area AS FLOAT64)
          AS construction_floor_area,

      CAST(latitude AS DECIMAL) AS latitude,
      CAST(longitude AS DECIMAL) AS longitude,

      -- Metadata
      CURRENT_TIMESTAMP() AS _stg_loaded_at

  FROM source

  -- Filters
  WHERE job_filing_number IS NOT NULL
  AND filing_date IS NOT NULL
  AND borough IS NOT NULL

  -- Deduplicate
  QUALIFY ROW_NUMBER() OVER (
      PARTITION BY job_filing_number
      ORDER BY current_status_date DESC
  ) = 1
)

SELECT * FROM cleaned
