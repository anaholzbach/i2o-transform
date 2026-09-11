IF EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.GPI_ISLANDS_ALL') AND type IN (N'P', N'PC'))
    DROP PROCEDURE dbo.GPI_ISLANDS_ALL;
GO

CREATE PROCEDURE dbo.GPI_ISLANDS_ALL
AS
BEGIN
    SET NOCOUNT ON;

    /*------------------------------------------------------------
      0) Make rerunnable: drop outputs if they exist
    ------------------------------------------------------------*/
    IF OBJECT_ID(N'dbo.GPI_ISLANDS', N'U') IS NOT NULL
        DROP TABLE dbo.GPI_ISLANDS;

    IF OBJECT_ID(N'dbo.visit_dimension_gpi', N'U') IS NOT NULL
        DROP TABLE dbo.visit_dimension_gpi;

    /*------------------------------------------------------------
      1) Materialize base filter into #base (so we can reuse it)
    ------------------------------------------------------------*/
    IF OBJECT_ID('tempdb..#base', 'U') IS NOT NULL
        DROP TABLE #base;

    SELECT
        vd.patient_num,
        vd.encounter_num,
        vd.sourcesystem_cd,
        vd.inout_cd,
        vd.location_cd,
        vd.location_path,
        vd.start_date,
        vd.end_date
    INTO #base
    FROM dbo.visit_dimension vd
    WHERE
        (
            (vd.location_cd = 'MGH' AND vd.start_date > '2014-08-01')
         OR (vd.location_cd = 'BWH' AND vd.start_date > '2015-08-01')
         OR (vd.location_cd = 'FH'  AND vd.start_date > '2015-06-01')
         OR (vd.location_cd = 'NWH' AND vd.start_date > '2015-12-01')
         OR (vd.location_cd = 'MCL' AND vd.start_date > '2017-05-01')
         OR (vd.location_cd = 'MEE' AND vd.start_date > '2015-02-01')
         OR (vd.location_cd = 'NSM' AND vd.start_date > '2016-04-01')
         OR (vd.location_cd = 'SRH' AND vd.start_date > '2015-03-01')
         OR (vd.location_cd = 'WDH' AND vd.start_date > '2019-10-01')
        )
        AND vd.sourcesystem_cd NOT LIKE '%Oncall%'
        AND vd.sourcesystem_cd NOT LIKE '%PB'
        AND vd.location_path NOT LIKE '%LMR%';

    /* (Optional but recommended) index temp table for window performance */
    CREATE INDEX IX_base_pt_loc_dates ON #base(patient_num, location_cd, start_date, end_date) INCLUDE (encounter_num, sourcesystem_cd, inout_cd);

    /*------------------------------------------------------------
      2) Build grouped islands into dbo.visit_dimension_gpi
    ------------------------------------------------------------*/
    ;WITH grouped_src AS (
        SELECT *
        FROM #base
        WHERE
            sourcesystem_cd NOT IN ('Constrack', 'EMSI')
            AND (inout_cd <> 'O' OR (inout_cd = 'O' AND DATEDIFF(DAY, start_date, end_date) < 2))
    ),
    grp AS (
        SELECT
            patient_num,
            encounter_num,
            sourcesystem_cd,
            inout_cd,
            location_cd,
            location_path,
            start_date,
            end_date,
            MAX(end_date) OVER (
                PARTITION BY patient_num, location_cd
                ORDER BY start_date, end_date
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS previous_end_date
        FROM grouped_src
    ),
    grp_marked AS (
        SELECT
            patient_num,
            encounter_num,
            sourcesystem_cd,
            inout_cd,
            location_cd,
            location_path,
            start_date,
            end_date,
            previous_end_date,
            CASE
                WHEN previous_end_date IS NULL THEN 1
                WHEN CAST(previous_end_date AS date) >= CAST(start_date AS date) THEN 0
                ELSE 1
            END AS island_start_ind
        FROM grp
    ),
    grp_islands AS (
        SELECT
            patient_num,
            encounter_num,
            sourcesystem_cd,
            inout_cd,
            location_cd,
            location_path,
            start_date,
            end_date,
            previous_end_date,
            island_start_ind,
            SUM(island_start_ind) OVER (
                PARTITION BY patient_num, location_cd
                ORDER BY start_date, end_date
                ROWS UNBOUNDED PRECEDING
            ) AS island_id
        FROM grp_marked
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY patient_num, location_cd, start_date, end_date, encounter_num) AS RN,
        patient_num,
        encounter_num,
        sourcesystem_cd,
        inout_cd,
        location_cd,
        location_path,
        start_date,
        end_date,
        previous_end_date,
        island_start_ind,
        island_id,
        CAST(NULL AS int) AS main
    INTO dbo.visit_dimension_gpi
    FROM grp_islands;

    /*------------------------------------------------------------
      3) Insert singles (each is its own island, negative ids)
    ------------------------------------------------------------*/
    ;WITH singles AS (
        SELECT *
        FROM #base
        WHERE
            sourcesystem_cd IN ('Constrack', 'EMSI')
            OR (inout_cd = 'O' AND DATEDIFF(DAY, start_date, end_date) > 1)
    )
    INSERT INTO dbo.visit_dimension_gpi (
        RN,
        patient_num,
        encounter_num,
        sourcesystem_cd,
        inout_cd,
        location_cd,
        location_path,
        start_date,
        end_date,
        previous_end_date,
        island_start_ind,
        island_id,
        main
    )
    SELECT
        0 AS RN,
        s.patient_num,
        s.encounter_num,
        s.sourcesystem_cd,
        s.inout_cd,
        s.location_cd,
        s.location_path,
        s.start_date,
        s.end_date,
        CAST(NULL AS datetime) AS previous_end_date,
        1 AS island_start_ind,
        -1 * ROW_NUMBER() OVER (ORDER BY s.patient_num, s.location_cd, s.start_date, s.end_date, s.encounter_num) AS island_id,
        CAST(NULL AS int) AS main
    FROM singles s;

    /*------------------------------------------------------------
      4) Build GPI_ISLANDS summary
    ------------------------------------------------------------*/
    SELECT
        v.patient_num,
        v.location_cd,
        v.island_id,
        MIN(v.start_date) AS island_start,
        MAX(v.end_date) AS island_end,
        STUFF((
            SELECT DISTINCT N', ' + u.inout_cd
            FROM dbo.visit_dimension_gpi u
            WHERE u.patient_num = v.patient_num
              AND u.location_cd = v.location_cd
              AND u.island_id   = v.island_id
              AND u.inout_cd <> '@'
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, N'') AS visit_types,
        DATEDIFF(DAY, MIN(v.start_date), MAX(v.end_date)) AS length,
        COUNT(v.encounter_num) AS num_visits
    INTO dbo.GPI_ISLANDS
    FROM dbo.visit_dimension_gpi v
    GROUP BY
        v.patient_num,
        v.location_cd,
        v.island_id;

    /*------------------------------------------------------------
      5) main = 1 for single-visit islands (matches your original)
    ------------------------------------------------------------*/
    UPDATE v
        SET v.main = 1
    FROM dbo.visit_dimension_gpi v
    INNER JOIN dbo.GPI_ISLANDS i
        ON  i.patient_num = v.patient_num
        AND i.location_cd = v.location_cd
        AND i.island_id   = v.island_id
    WHERE i.num_visits = 1;

END
GO