USE CATALOG uc;
CREATE SCHEMA IF NOT EXISTS public_health_silver;

CREATE TABLE IF NOT EXISTS uc.public_health_silver.refined_encounters (
    patient_id STRING,
    report_date DATE,
    clinic_code STRING,
    diagnosis_code STRING,
    severity_score INT,
    geom_location STRING
) USING iceberg PARTITIONED BY (days(report_date));

INSERT INTO uc.public_health_silver.refined_encounters
WITH ranked AS (
    SELECT
        TRIM(UPPER(patient_id)) as patient_id,
        CAST(encounter_timestamp AS DATE) as report_date,
        COALESCE(clinic_id, 'UNKNOWN') as clinic_code,
        REGEXP_REPLACE(raw_diagnosis, '[^a-zA-Z0-9]', '') as diagnosis_code,
        CASE WHEN fever_temp > 39 THEN 3 WHEN fever_temp > 38 THEN 2 ELSE 1 END as severity_score,
        CONCAT('POINT(', CAST(lon AS DOUBLE), ' ', CAST(lat AS DOUBLE), ')') as geom_location,
        ROW_NUMBER() OVER (
            PARTITION BY patient_id, CAST(encounter_timestamp AS DATE)
            ORDER BY encounter_timestamp DESC
        ) as rn
    FROM uc.public_health_bronze.raw_clinic_ingest
    WHERE encounter_timestamp IS NOT NULL
)
SELECT patient_id, report_date, clinic_code, diagnosis_code, severity_score, geom_location
FROM ranked
WHERE rn = 1;
