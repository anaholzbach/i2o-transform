create procedure pmi_id_step2 as

begin
----------------------------------------------------------
-- Step two loop through the mappings and fill in the new values into the new columns
-------------------------------------------------------------
declare @aou_id as int;
declare @pmi_id as varchar;
declare @patient_num as int;
declare @ids as cursor
set @ids = cursor for
select cast(substring(am.PMI_ID, 2, 10) as int) as aou_id, am.pmi_id, mm.patient_num from dbo.aou_mapping am
join mrn_mapping mm on am.mrn = mm.mrn and substring(am.MRN_FACILITY,1,3) = mm.company_cd;

open @ids
fetch next from @ids into @aou_id, @pmi_id, @patient_num

while @@FETCH_STATUS = 0
begin 
	update dbo.person set aou_id = @aou_id where person_id = @patient_num;
	update dbo.visit_occurrence set aou_id = @aou_id where person_id = @patient_num;
	update dbo.visit_detail set aou_id = @aou_id where person_id = @patient_num;
	update dbo.condition_occurrence set aou_id = @aou_id where person_id = @patient_num;
	update dbo.condition_era set aou_id = @aou_id where person_id = @patient_num;
	update dbo.procedure_occurrence set aou_id = @aou_id where person_id = @patient_num;
	update dbo.drug_exposure set aou_id = @aou_id where person_id = @patient_num;
	update dbo.drug_era set aou_id = @aou_id where person_id = @patient_num;
	update dbo.measurement set aou_id = @aou_id where person_id = @patient_num;
	update dbo.observation set aou_id = @aou_id where person_id = @patient_num;
	update dbo.observation_period set aou_id = @aou_id where person_id = @patient_num;
	update dbo.device_exposure set aou_id = @aou_id where person_id = @patient_num;
	update dbo.death set aou_id = @aou_id where person_id = @patient_num;
	update dbo.specimen set aou_id = @aou_id where person_id = @patient_num;
	update dbo.note set aou_id = @aou_id where person_id = @patient_num;

	fetch next from @ids into @aou_id, @pmi_id, @patient_num
end

close @ids;
deallocate @ids;
end
