SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
	
	IF OBJECT_ID(N'dbo.GPI_ISLANDS', N'U') IS NOT NULL  
   	DROP TABLE [dbo].[GPI_ISLANDS]
	GO
	
	SELECT distinct patient_num, island_id, min(start_date) as island_start, max(end_date) as island_end, location_cd,
	visit_types = STUFF((SELECT distinct N', ' +  inout_cd
						 FROM visit_dimension_gpi AS u
						 WHERE u.island_id = v.island_id and  u.patient_num = v.patient_num
						 and inout_cd <> '@' --ignore @
						 FOR XML PATH(N'')), 1, 2, N''),
	datediff(day, min(start_date), max(end_date)) as length,
	count(encounter_num) as num_visits
	into [GPI_ISLANDS]
	FROM visit_dimension_gpi AS v
	GROUP BY patient_num, island_id, location_cd

	GO

	-- set main visit in visit_dimension_gpi for single-visit islands
	alter table visit_dimension_gpi ADD main int;
	GO

	update visit_dimension_gpi set main = 1
	where island_id in 
	(select island_id from GPI_ISLANDS where num_visits = 1);
	GO

