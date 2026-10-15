-- Run as owner; changes are fully rolled back. Repeatable on the seeded database.
BEGIN;
SET search_path=hospital,public;
CALL sp_set_actor(1);
DO $$
DECLARE p bigint; a bigint; e bigint; rx bigint; adm bigint; check_bed bigint; stamp timestamptz; failed_id bigint;
BEGIN
 CALL sp_create_patient('CHECK-ROLLBACK','Test','Checks','2000-01-01',NULL,p);
 ASSERT EXISTS(SELECT 1 FROM v_patients WHERE id=p),'create patient';
 SELECT updated_at INTO stamp FROM patient WHERE id=p;
 CALL sp_update_patient(p,'111',stamp);
 ASSERT (SELECT phone='111' AND updated_by=1 FROM patient WHERE id=p),'update metadata';
 BEGIN
  CALL sp_update_patient(p,'222',stamp);
  RAISE EXCEPTION 'Expected optimistic concurrency rejection';
 EXCEPTION WHEN serialization_failure THEN NULL; END;
 CALL sp_delete_patient(p);
 ASSERT NOT EXISTS(SELECT 1 FROM v_patients WHERE id=p),'soft delete visibility';
 ASSERT EXISTS(SELECT 1 FROM v_patient_archive WHERE id=p AND deleted_at IS NOT NULL),'archive';
 BEGIN
  CALL sp_book_appointment(p,1,'2090-01-01 10:00+00','2090-01-01 10:30+00',a);
  RAISE EXCEPTION 'Expected archived-patient rejection';
 EXCEPTION WHEN check_violation THEN NULL; END;
 CALL sp_restore_patient(p);
 ASSERT EXISTS(SELECT 1 FROM v_patients WHERE id=p),'restore';
 CALL sp_book_appointment(p,1,'2090-01-01 10:00+00','2090-01-01 10:30+00',a);
 BEGIN
  CALL sp_delete_patient(p);
  RAISE EXCEPTION 'Expected active-patient deletion rejection';
 EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN
  CALL sp_book_appointment(p,1,'2090-01-01 10:15+00','2090-01-01 10:45+00',failed_id);
  RAISE EXCEPTION 'Expected appointment overlap rejection';
 EXCEPTION WHEN exclusion_violation THEN NULL; END;
 CALL sp_cancel_appointment(a);
 ASSERT EXISTS(SELECT 1 FROM v_appointment_archive WHERE id=a),'cancel soft delete';
 CALL sp_book_appointment(p,1,'2090-01-01 10:00+00','2090-01-01 10:30+00',a);
 CALL sp_complete_appointment(a,'demo check notes',e);
 CALL sp_add_diagnosis(e,1,true);
 BEGIN
  CALL sp_add_diagnosis(e,2,true);
  RAISE EXCEPTION 'Expected second primary diagnosis rejection';
 EXCEPTION WHEN unique_violation THEN NULL; END;
 SELECT updated_at INTO stamp FROM encounter WHERE id=e;
 CALL sp_update_encounter(e,'demo updated notes',stamp);
 ASSERT (SELECT notes='demo updated notes' FROM v_encounters WHERE id=e),'encounter update';
 CALL sp_create_prescription(e,rx);
 CALL sp_add_prescription_item(rx,1,'DEMO','DEMO',1);
 ASSERT EXISTS(SELECT 1 FROM v_prescription_items WHERE prescription_id=rx),'prescription item';
 CALL sp_delete_prescription(rx);
 ASSERT NOT EXISTS(SELECT 1 FROM v_prescription_items WHERE prescription_id=rx),'prescription archive';
 INSERT INTO bed(room_id,bed_number)
 VALUES ((SELECT id FROM room ORDER BY id LIMIT 1),'CHECK-' || txid_current()::text)
 RETURNING id INTO check_bed;
 CALL sp_admit_patient(p,1,check_bed,'2090-01-01 12:00+00',adm);
 BEGIN
  CALL sp_admit_patient(p,1,check_bed,'2090-01-01 13:00+00',failed_id);
  RAISE EXCEPTION 'Expected admission overlap rejection';
 EXCEPTION WHEN exclusion_violation THEN NULL; END;
 CALL sp_discharge_patient(adm,'2090-01-03 12:00+00');
 ASSERT (SELECT stay_days=2 FROM v_admissions WHERE id=adm),'stay duration';
 CALL sp_delete_patient(p);
 ASSERT EXISTS(SELECT 1 FROM v_encounters WHERE id=e),'history preserved';
 BEGIN
  DELETE FROM patient WHERE id=p;
  RAISE EXCEPTION 'Expected physical delete rejection';
 EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN
  CALL sp_create_patient('CHECK-FUTURE','Test','Future',current_date+1,NULL,failed_id);
  RAISE EXCEPTION 'Expected future birth rejection';
 EXCEPTION WHEN check_violation THEN NULL; END;
 ASSERT NOT EXISTS(SELECT 1 FROM patient WHERE medical_record_number='CHECK-FUTURE'),'failed insert rollback';
 ASSERT (SELECT count(*)>=5 FROM audit_log WHERE table_name='patient' AND row_id=p),'audit exists';
 ASSERT NOT EXISTS(SELECT 1 FROM audit_log WHERE table_name='patient' AND row_id=p AND changed_by<>1),'audit actor';
 ASSERT EXISTS(SELECT 1 FROM v_encounters WHERE id=e AND to_tsvector('simple',notes) @@ plainto_tsquery('simple','demo')),'full text search';
 ASSERT fn_age_years('2000-01-01','2026-01-01')=26,'age function';
 BEGIN
  CALL sp_create_patient('CHECK-ATOMIC','Test','Atomic','2000-01-01',NULL,failed_id);
  CALL sp_book_appointment(failed_id,-1,'2091-01-01 10:00+00','2091-01-01 10:30+00',a);
  RAISE EXCEPTION 'Expected FK rejection';
 EXCEPTION WHEN foreign_key_violation THEN NULL; END;
 ASSERT NOT EXISTS(SELECT 1 FROM patient WHERE medical_record_number='CHECK-ATOMIC'),'atomic rollback';
 RAISE NOTICE 'All SQL assertions passed';
END $$;
SET LOCAL ROLE hospital_app;
DO $$ BEGIN
 PERFORM 1 FROM hospital.v_patients;
 BEGIN
  PERFORM 1 FROM hospital.patient;
  RAISE EXCEPTION 'Unexpected direct table access';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
  DELETE FROM hospital.patient WHERE id=-1;
  RAISE EXCEPTION 'Unexpected direct delete access';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
ROLLBACK;
