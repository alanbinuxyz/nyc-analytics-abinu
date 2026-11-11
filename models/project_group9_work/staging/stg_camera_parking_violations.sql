-- Clean and standardize Open Parking and Camera Violations
-- One row per summons

WITH source AS (
    SELECT * FROM {{ source('raw_data', 'source_parking_camera_violations') }}
), -- Easier to refer to the dbt reference to a long name table this way

cleaned AS (
    SELECT
        -- Get all columns from source, except ones we're transforming below
        -- To do cleaning on them or explicitly cast them as types just in case
        -- Passing through unchanged via *: license_type, violation_status
        -- (already strings in the raw data, no renaming needed)
        * EXCEPT (
            summons_number,
            plate,
            state,
            issue_date,
            violation_time,
            judgment_entry_date,
            precinct,
            issuing_agency,
            fine_amount,
            penalty_amount,
            interest_amount,
            reduction_amount,
            payment_amount,
            amount_due,
            county,
            violation
        ),
        
        -- Identifiers
        CAST(summons_number AS STRING) AS summons_number,

        -- Date/Time
        SAFE.PARSE_DATE('%m/%d/%Y', issue_date) AS issue_date,
        SAFE.PARSE_DATE('%m/%d/%Y', judgment_entry_date) AS judgment_entry_date,

        CASE
            -- placeholder for "time not recorded"
            WHEN violation_time IN ('00:00A', '00:00P') THEN NULL

            -- normal format: 09:32A / 11:15P
            WHEN REGEXP_CONTAINS(violation_time, r'^\d{2}:\d{2}[AP]$') THEN
                SAFE.PARSE_TIME(
                    '%I:%M%p',
                    CONCAT(
                        -- some records use 00 for the midnight hour, which a 12-hour clock doesn't allow
                        IF(LEFT(violation_time, 2) = '00', CONCAT('12', SUBSTR(violation_time, 3)), violation_time),
                        'M'  -- turns "09:32A" into "09:32AM"
                    )
                )

            -- no A/P but hour 13-23: must be a 24-hour time
            WHEN REGEXP_CONTAINS(violation_time, r'^(1[3-9]|2[0-3]):\d{2}$') THEN
                SAFE.PARSE_TIME('%H:%M', violation_time)

            -- no A/P and hour 00-12: ambiguous, so leave null
            ELSE NULL
        END AS violation_time,

        -- Details
        CAST(issuing_agency AS STRING) AS agency_name,
        CAST(plate AS STRING) AS license_plate_number,
        CAST(state AS STRING) AS license_state,

        -- Location - standardized borough to match 311 staging
        CASE
            WHEN UPPER(TRIM(county)) IN ('NY', 'MN', 'MAN', 'MANHATTAN', 'NEW YORK') THEN 'Manhattan'
            WHEN UPPER(TRIM(county)) IN ('BX', 'BRONX') THEN 'Bronx'
            WHEN UPPER(TRIM(county)) IN ('BK', 'K', 'KINGS', 'BROOKLYN') THEN 'Brooklyn'
            WHEN UPPER(TRIM(county)) IN ('QN', 'Q', 'QNS', 'QUEEN', 'QUEENS') THEN 'Queens'
            WHEN UPPER(TRIM(county)) IN ('ST', 'R', 'RICH', 'RICHMOND', 'SI', 'STATEN ISLAND') THEN 'Staten Island'

            -- fallback: infer borough from precinct number when county is missing or invalid
            WHEN SAFE_CAST(precinct AS INT64) BETWEEN 1 AND 34 THEN 'Manhattan'
            WHEN SAFE_CAST(precinct AS INT64) BETWEEN 40 AND 52 THEN 'Bronx'
            WHEN SAFE_CAST(precinct AS INT64) BETWEEN 60 AND 94 THEN 'Brooklyn'
            WHEN SAFE_CAST(precinct AS INT64) BETWEEN 100 AND 115 THEN 'Queens'
            WHEN SAFE_CAST(precinct AS INT64) BETWEEN 120 AND 123 THEN 'Staten Island'

            ELSE 'UNKNOWN or CITYWIDE'
        END AS borough,

        -- Precinct - kept as string; 000 means not recorded
        NULLIF(TRIM(precinct), '000') AS precinct,

        -- Fine amounts - NUMERIC for exact currency values
        CAST(fine_amount AS NUMERIC) AS fine_amount,
        CAST(penalty_amount AS NUMERIC) AS penalty_amount,
        CAST(interest_amount AS NUMERIC) AS interest_amount,
        CAST(reduction_amount AS NUMERIC) AS reduction_amount,
        CAST(payment_amount AS NUMERIC) AS payment_amount,
        CAST(amount_due AS NUMERIC) AS amount_due,

        -- Violation details
        CAST(violation AS STRING) AS violation_type,

        -- Metadata
        CURRENT_TIMESTAMP() AS _stg_loaded_at

    FROM source

    -- Filters
    WHERE summons_number IS NOT NULL
        AND SAFE.PARSE_DATE('%m/%d/%Y', issue_date) IS NOT NULL

    -- Deduplicate: no duplicates found at time of writing, kept as a safeguard for future loads
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY summons_number
        ORDER BY judgment_entry_date DESC NULLS LAST
    ) = 1
)

SELECT * FROM cleaned
-- All should be part of this table after running: stg_nyc_parking_camera_violations