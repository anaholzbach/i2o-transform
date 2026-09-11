/****** Object:  StoredProcedure [dbo].[GPI_EPIC_VISITS]    Script Date: 5/26/2025 5:05:08 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		Ana Holzbach
-- Create date: April 9 2025
-- Description:	Generates islands of MGH visits
-- =============================================
/*** visit detail taking place on same date regardless of time roll up to visit occurrence 							***/
/*** Epic system:																									***/
/***		@MGH > August 2014 																						***/
/*** 		@BWH > August 2015																						***/
/***		@FH  > June 2015																						***/
/***		@NWH > December 2015																					***/
/***		@MCL > May 2017																							***/
/***		@MEE > February 2015																					***/
/***		@NSM > April 2016																						***/
/***		@SRH > March 2015																						***/
/***		@WDH > October 2019																						***/
/*** sourcesystem_cd = 'Epic' or 'EPIC' should provide the 'main' visit, everything else should qualify as 'detail' ***/
/***																												***/
/*** 1. Groups visits into islands by same or overlapping dates														***/
/***		visits with sourcesystem_cd in (Constrack, EMSI)														***/
/***        or inout_cd = O with length > 1 (spanning 3 days or more)												***/
/***        --- in individual islands																				***/
/***		other visits grouped by same or overlapping dates														***/
/*** 2. Excludes billing visits (sourcesystem_cd like '%PB')														***/	
/***																												***/
/*** 																												***/
ALTER PROCEDURE [dbo].[GPI_EPIC_VISITS]
AS
BEGIN

	SET NOCOUNT ON;

    SELECT
 *,
 CASE WHEN (
	cast(grouping.previous_end_date as date) = cast(start_date as date)
	or
	cast(grouping.previous_end_date as date) >= cast(end_date as date)
	) THEN 0 ELSE 1 END AS island_start_ind,
 SUM (CASE WHEN (
	cast(grouping.previous_end_date as date) = cast(start_date as date)
	or
	cast(grouping.previous_end_date as date) >= cast(end_date as date)
	) THEN 0 ELSE 1 END) OVER (ORDER BY grouping.RN) AS island_id
into visit_dimension_gpi
FROM
 (
SELECT
  ROW_NUMBER () OVER (ORDER BY patient_num, location_cd, start_date, end_date) AS RN,
  patient_num,
  encounter_num,
  sourcesystem_cd,
  INOUT_CD,
  location_cd,
  location_path,
  start_date,
  end_date,
  MAX(end_date) OVER (PARTITION BY patient_num, location_cd ORDER BY start_date, end_date ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS previous_end_date,
  MIN(start_date) OVER (PARTITION BY patient_num, location_cd ORDER BY start_date, end_date ROWS BETWEEN 1 PRECEDING AND 1 PRECEDING) AS previous_start_date
FROM
  visit_dimension
  where (
  (location_cd = 'MGH' and start_date > '2014-08-01')
or (location_cd = 'BWH' and start_date > '2015-08-01')
or (location_cd = 'FH' and start_date > '2015-06-01')
or (location_cd = 'NWH' and start_date > '2015-12-01')
or (location_cd = 'MCL' and start_date > '2017-05-01')
or (location_cd = 'MEE' and start_date > '2015-02-01')
or (location_cd = 'NSM' and start_date > '2016-04-01')
or (location_cd = 'SRH' and start_date > '2015-03-01')
or (location_cd = 'WDH' and start_date > '2019-10-01')
)
  and SOURCESYSTEM_CD not like '%Oncall%'
  and SOURCESYSTEM_CD not like '%PB'
  and SOURCESYSTEM_CD not in ('Constrack', 'EMSI')
  and (INOUT_CD <> 'O' OR (inout_cd = 'O' and datediff(day, start_date, end_date) < 2)) 
  and location_path not like '%LMR%'
  ) grouping;

  declare @max_island_id int;

  SELECT @max_island_id = max(island_id) from visit_dimension_gpi;
  
  insert into visit_dimension_gpi
  select *,
  1 as island_start_ind,
  @max_island_id + ROW_NUMBER() OVER (ORDER BY patient_num, start_date, end_date) AS island_id
  from 
  (
  select 
  0 as RN,
  patient_num,
  encounter_num,
  sourcesystem_cd,
  INOUT_CD,
  location_cd,
  location_path,
  start_date,
  end_date,
  null as previous_end_date,
  null as previous_start_date
  from visit_dimension
  where ((location_cd = 'MGH' and start_date > '2014-08-01')
or (location_cd = 'BWH' and start_date > '2015-08-01')
or (location_cd = 'FH' and start_date > '2015-06-01')
or (location_cd = 'NWH' and start_date > '2015-12-01')
or (location_cd = 'MCL' and start_date > '2017-05-01')
or (location_cd = 'MEE' and start_date > '2015-02-01')
or (location_cd = 'NSM' and start_date > '2016-04-01')
or (location_cd = 'SRH' and start_date > '2015-03-01')
or (location_cd = 'WDH' and start_date > '2019-10-01')
)
  and SOURCESYSTEM_CD not like '%Oncall%'
  and SOURCESYSTEM_CD not like '%PB'
  and (SOURCESYSTEM_CD in ('Constrack', 'EMSI') 
  OR (inout_cd = 'O' and datediff(day, start_date, end_date) > 1 and SOURCESYSTEM_CD not like '%PB'))
  and location_path not like '%LMR%' 
  ) singles;

END
