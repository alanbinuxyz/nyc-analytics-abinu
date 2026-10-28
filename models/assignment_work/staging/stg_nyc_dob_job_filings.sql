
{{ config(materialized='table') }}

-- Clean and standardize DOB NOW job application filings
-- One row per unique job filing number

WITH source AS (
    SELECT *
    FROM {{ source('dob_raw', 'source_nyc_dob_job_apps') }}
),

cleaned AS (
    SELECT
        * EXCEPT (
            job_filing_number,
            filing_status,
            job_type,
            filing_date,
            current_status_date,
            first_permit_date,
            approved_date,
            signoff_date,
            borough,
            postcode,
            zip,
            street_name,
            initial_cost,
            latitude,
            longitude
        ),

        -- Identifiers
        UPPER(TRIM(CAST(job_filing_number AS STRING)))
            AS job_filing_number,

        -- Extract the main job number without filing suffix
        SPLIT(
            UPPER(TRIM(CAST(job_filing_number AS STRING))),
            '-'
        )[SAFE_OFFSET(0)] AS job_number,

        -- Filing details
        UPPER(TRIM(CAST(filing_status AS STRING)))
            AS filing_status,

        UPPER(TRIM(CAST(job_type AS STRING)))
            AS job_type,

        -- Dates: convert to DATE for easier analysis
        -- Handle both standard and MM/DD/YYYY formats
        COALESCE(
            SAFE_CAST(filing_date AS DATE),
            SAFE_CAST(SAFE_CAST(filing_date AS TIMESTAMP) AS DATE),
            SAFE.PARSE_DATE(
                '%m/%d/%Y',
                SUBSTR(CAST(filing_date AS STRING), 1, 10)
            )
        ) AS filing_date,

        COALESCE(
            SAFE_CAST(current_status_date AS DATE),
            SAFE_CAST(SAFE_CAST(current_status_date AS TIMESTAMP) AS DATE),
            SAFE.PARSE_DATE(
                '%m/%d/%Y',
                SUBSTR(CAST(current_status_date AS STRING), 1, 10)
            )
        ) AS current_status_date,

        SAFE_CAST(first_permit_date AS DATE)
            AS first_permit_date,

        SAFE_CAST(approved_date AS DATE)
            AS approved_date,

        SAFE_CAST(signoff_date AS DATE)
            AS signoff_date,

        -- Conformed dimension: standardize borough
        CASE
            WHEN UPPER(TRIM(CAST(borough AS STRING)))
                IN ('MANHATTAN', 'NEW YORK COUNTY')
                THEN 'Manhattan'

            WHEN UPPER(TRIM(CAST(borough AS STRING)))
                IN ('BRONX', 'THE BRONX')
                THEN 'Bronx'

            WHEN UPPER(TRIM(CAST(borough AS STRING)))
                IN ('BROOKLYN', 'KINGS COUNTY')
                THEN 'Brooklyn'

            WHEN UPPER(TRIM(CAST(borough AS STRING)))
                IN ('QUEENS', 'QUEEN', 'QUEENS COUNTY')
                THEN 'Queens'

            WHEN UPPER(TRIM(CAST(borough AS STRING)))
                IN ('STATEN ISLAND', 'RICHMOND COUNTY')
                THEN 'Staten Island'

            ELSE 'UNKNOWN or CITYWIDE'
        END AS borough,

        -- Conformed dimension: ZIP code of job location
        -- Keep first five digits; handle ZIP+4 formats
        REGEXP_EXTRACT(
            TRIM(CAST(postcode AS STRING)),
            r'^(\d{5})(?:-?\d{4}|\.0)?$'
        ) AS zip,

        -- Preserve applicant ZIP under a clearer name
        NULLIF(TRIM(CAST(zip AS STRING)), '')
            AS applicant_zip,

        -- Clean street name
        NULLIF(
            UPPER(TRIM(CAST(street_name AS STRING))),
            ''
        ) AS street_name,

        -- Create address compatible with the 311 model
        NULLIF(
            TRIM(
                CONCAT(
                    COALESCE(TRIM(CAST(house_no AS STRING)), ''),
                    ' ',
                    COALESCE(TRIM(CAST(street_name AS STRING)), '')
                )
            ),
            ''
        ) AS incident_address,

        -- Convert construction cost to numeric
        -- Remove dollar signs and commas if present
        SAFE_CAST(
            REGEXP_REPLACE(
                CAST(initial_cost AS STRING),
                r'[$,]',
                ''
            ) AS NUMERIC
        ) AS initial_cost,

        -- Geographic coordinates
        SAFE_CAST(latitude AS FLOAT64) AS latitude,
        SAFE_CAST(longitude AS FLOAT64) AS longitude,

        -- Metadata
        CURRENT_TIMESTAMP() AS _stg_loaded_at

    FROM source

    -- Filter out rows without a usable filing identifier
    WHERE NULLIF(
        TRIM(CAST(job_filing_number AS STRING)),
        ''
    ) IS NOT NULL
)

-- Deduplicate by filing number
-- Keep the record with the most recent status date
SELECT *
FROM cleaned

QUALIFY ROW_NUMBER() OVER (
    PARTITION BY job_filing_number
    ORDER BY
        current_status_date DESC NULLS LAST,
        filing_date DESC NULLS LAST
) = 1

-- Final model: stg_nyc_dob_job_filings
