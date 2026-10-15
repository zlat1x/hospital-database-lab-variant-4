BEGIN;
SET search_path = hospital, public;
-- Actor context is transaction-local. In production it must come from authenticated middleware.
CREATE FUNCTION fn_actor() RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE actor bigint;
BEGIN
 actor := nullif(current_setting('hospital.actor_id',true),'')::bigint;
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM hospital.app_user WHERE id=actor AND is_active) THEN
  RAISE EXCEPTION 'An active actor is required' USING ERRCODE='22023';
 END IF;
 RETURN actor;
END $$;
CREATE PROCEDURE sp_set_actor(p_actor bigint) LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM app_user WHERE id=p_actor AND is_active) THEN
  RAISE EXCEPTION 'Unknown or inactive actor' USING ERRCODE='22023';
 END IF;
 PERFORM set_config('hospital.actor_id',p_actor::text,true);
END $$;
CREATE FUNCTION fn_stamp() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 NEW.updated_at := clock_timestamp();
 NEW.updated_by := hospital.fn_actor();
 IF TG_TABLE_NAME IN ('patient','appointment','prescription') THEN
  IF NEW.is_deleted THEN
   IF TG_OP='INSERT' THEN NEW.deleted_at:=clock_timestamp();
   ELSIF NOT OLD.is_deleted THEN NEW.deleted_at:=clock_timestamp();
   ELSE NEW.deleted_at:=OLD.deleted_at;
   END IF;
  ELSE NEW.deleted_at:=NULL;
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION fn_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO hospital.audit_log(table_name,row_id,operation,changed_by,old_data,new_data)
 VALUES(TG_TABLE_NAME,NEW.id,TG_OP,NEW.updated_by,
 CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE NULL END,to_jsonb(NEW));
 RETURN NEW;
END $$;
CREATE FUNCTION fn_no_hard_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Physical deletion is forbidden for %',TG_TABLE_NAME USING ERRCODE='23514'; END $$;
CREATE FUNCTION fn_patient_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.birth_date > current_date THEN RAISE EXCEPTION 'Birth date cannot be in the future' USING ERRCODE='23514'; END IF;
 IF TG_OP='UPDATE' AND NEW.is_deleted AND NOT OLD.is_deleted AND (
  EXISTS(SELECT 1 FROM hospital.appointment WHERE patient_id=NEW.id AND status='booked' AND NOT is_deleted)
  OR EXISTS(SELECT 1 FROM hospital.admission WHERE patient_id=NEW.id AND discharged_at IS NULL)
 ) THEN RAISE EXCEPTION 'Patient has active appointments or admission' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_patient_guard BEFORE INSERT OR UPDATE ON patient FOR EACH ROW EXECUTE FUNCTION fn_patient_guard();
CREATE FUNCTION fn_appointment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 -- Lock the patient so concurrent soft delete cannot race with booking.
 PERFORM 1 FROM hospital.patient WHERE id=NEW.patient_id AND NOT is_deleted FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Patient is missing or deleted' USING ERRCODE='23514'; END IF;
 IF TG_OP='UPDATE' THEN
  IF OLD.status <> 'booked' AND NEW IS DISTINCT FROM OLD THEN
   RAISE EXCEPTION 'Completed/cancelled appointment is immutable' USING ERRCODE='23514';
  END IF;
  IF NEW.patient_id <> OLD.patient_id OR NEW.doctor_id <> OLD.doctor_id THEN
   RAISE EXCEPTION 'Reassignment is forbidden; create another appointment' USING ERRCODE='23514';
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_appointment_guard BEFORE INSERT OR UPDATE ON appointment FOR EACH ROW EXECUTE FUNCTION fn_appointment_guard();
CREATE FUNCTION fn_admission_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 PERFORM 1 FROM hospital.patient WHERE id=NEW.patient_id AND NOT is_deleted FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Patient is missing or deleted' USING ERRCODE='23514'; END IF;
 IF TG_OP='UPDATE' AND (OLD.discharged_at IS NOT NULL OR NEW.patient_id<>OLD.patient_id OR NEW.doctor_id<>OLD.doctor_id OR NEW.bed_id<>OLD.bed_id OR NEW.admitted_at<>OLD.admitted_at) THEN
  RAISE EXCEPTION 'Admission history is immutable' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_admission_guard BEFORE INSERT OR UPDATE ON admission FOR EACH ROW EXECUTE FUNCTION fn_admission_guard();
CREATE FUNCTION fn_age_years(p_birth_date date,p_on_date date) RETURNS integer
 LANGUAGE sql IMMUTABLE STRICT AS $$ SELECT extract(year FROM age(p_on_date,p_birth_date))::integer $$;
CREATE FUNCTION fn_stay_days(p_start timestamptz,p_end timestamptz) RETURNS numeric
 LANGUAGE sql IMMUTABLE STRICT AS $$ SELECT round((extract(epoch FROM p_end-p_start)/86400)::numeric,2) $$;
CREATE TRIGGER tr_patient_stamp BEFORE INSERT OR UPDATE ON patient FOR EACH ROW EXECUTE FUNCTION fn_stamp();
CREATE TRIGGER tr_patient_audit AFTER INSERT OR UPDATE ON patient FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER tr_patient_no_delete BEFORE DELETE ON patient FOR EACH ROW EXECUTE FUNCTION fn_no_hard_delete();
CREATE TRIGGER tr_appointment_stamp BEFORE INSERT OR UPDATE ON appointment FOR EACH ROW EXECUTE FUNCTION fn_stamp();
CREATE TRIGGER tr_appointment_audit AFTER INSERT OR UPDATE ON appointment FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER tr_appointment_no_delete BEFORE DELETE ON appointment FOR EACH ROW EXECUTE FUNCTION fn_no_hard_delete();
CREATE TRIGGER tr_encounter_stamp BEFORE INSERT OR UPDATE ON encounter FOR EACH ROW EXECUTE FUNCTION fn_stamp();
CREATE TRIGGER tr_encounter_audit AFTER INSERT OR UPDATE ON encounter FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER tr_encounter_no_delete BEFORE DELETE ON encounter FOR EACH ROW EXECUTE FUNCTION fn_no_hard_delete();
CREATE TRIGGER tr_prescription_stamp BEFORE INSERT OR UPDATE ON prescription FOR EACH ROW EXECUTE FUNCTION fn_stamp();
CREATE TRIGGER tr_prescription_audit AFTER INSERT OR UPDATE ON prescription FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER tr_prescription_no_delete BEFORE DELETE ON prescription FOR EACH ROW EXECUTE FUNCTION fn_no_hard_delete();
CREATE TRIGGER tr_admission_stamp BEFORE INSERT OR UPDATE ON admission FOR EACH ROW EXECUTE FUNCTION fn_stamp();
CREATE TRIGGER tr_admission_audit AFTER INSERT OR UPDATE ON admission FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER tr_admission_no_delete BEFORE DELETE ON admission FOR EACH ROW EXECUTE FUNCTION fn_no_hard_delete();
CREATE PROCEDURE sp_create_patient(p_mrn text,p_first text,p_last text,p_birth date,p_phone text,INOUT p_id bigint DEFAULT NULL)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 INSERT INTO patient(medical_record_number,first_name,last_name,birth_date,phone,updated_by)
 VALUES(p_mrn,p_first,p_last,p_birth,p_phone,fn_actor()) RETURNING id INTO p_id;
END $$;
CREATE PROCEDURE sp_update_patient(p_id bigint,p_phone text,p_expected timestamptz)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 UPDATE patient SET phone=p_phone WHERE id=p_id AND NOT is_deleted AND updated_at=p_expected;
 IF NOT FOUND THEN RAISE EXCEPTION 'Patient missing, deleted or changed concurrently' USING ERRCODE='40001'; END IF;
END $$;
CREATE PROCEDURE sp_delete_patient(p_id bigint) LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 UPDATE patient SET is_deleted=true WHERE id=p_id AND NOT is_deleted;
 IF NOT FOUND THEN RAISE EXCEPTION 'Active patient not found' USING ERRCODE='P0002'; END IF;
END $$;
CREATE PROCEDURE sp_restore_patient(p_id bigint) LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 UPDATE patient SET is_deleted=false WHERE id=p_id AND is_deleted;
 IF NOT FOUND THEN RAISE EXCEPTION 'Deleted patient not found' USING ERRCODE='P0002'; END IF;
END $$;
CREATE PROCEDURE sp_book_appointment(p_patient bigint,p_doctor bigint,p_start timestamptz,p_end timestamptz,INOUT p_id bigint DEFAULT NULL)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 INSERT INTO appointment(patient_id,doctor_id,starts_at,ends_at,updated_by)
 VALUES(p_patient,p_doctor,p_start,p_end,fn_actor()) RETURNING id INTO p_id;
END $$;
CREATE PROCEDURE sp_cancel_appointment(p_id bigint) LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 UPDATE appointment SET status='cancelled',is_deleted=true WHERE id=p_id AND status='booked' AND NOT is_deleted;
 IF NOT FOUND THEN RAISE EXCEPTION 'Booked appointment not found' USING ERRCODE='P0002'; END IF;
END $$;
CREATE PROCEDURE sp_complete_appointment(p_id bigint,p_notes text,INOUT p_encounter bigint DEFAULT NULL)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 UPDATE appointment SET status='completed' WHERE id=p_id AND status='booked' AND NOT is_deleted;
 IF NOT FOUND THEN RAISE EXCEPTION 'Booked appointment not found' USING ERRCODE='P0002'; END IF;
 INSERT INTO encounter(appointment_id,notes,updated_by) VALUES(p_id,p_notes,fn_actor()) RETURNING id INTO p_encounter;
END $$;
CREATE PROCEDURE sp_update_encounter(p_id bigint,p_notes text,p_expected timestamptz)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 UPDATE encounter SET notes=p_notes WHERE id=p_id AND updated_at=p_expected;
 IF NOT FOUND THEN RAISE EXCEPTION 'Encounter missing or changed concurrently' USING ERRCODE='40001'; END IF;
END $$;
CREATE PROCEDURE sp_add_diagnosis(p_encounter bigint,p_diagnosis bigint,p_primary boolean)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 INSERT INTO encounter_diagnosis VALUES(p_encounter,p_diagnosis,p_primary);
 -- Record who changed the clinical aggregate, including its related data.
 UPDATE encounter SET updated_by=fn_actor() WHERE id=p_encounter;
END $$;
CREATE PROCEDURE sp_create_prescription(p_encounter bigint,INOUT p_id bigint DEFAULT NULL)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 INSERT INTO prescription(encounter_id,updated_by) VALUES(p_encounter,fn_actor()) RETURNING id INTO p_id;
END $$;
CREATE PROCEDURE sp_add_prescription_item(p_prescription bigint,p_medication bigint,p_dosage text,p_frequency text,p_days integer)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 PERFORM 1 FROM prescription WHERE id=p_prescription AND NOT is_deleted FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Active prescription not found' USING ERRCODE='P0002'; END IF;
 INSERT INTO prescription_item VALUES(p_prescription,p_medication,p_dosage,p_frequency,p_days);
 UPDATE prescription SET updated_by=fn_actor() WHERE id=p_prescription;
END $$;
CREATE PROCEDURE sp_delete_prescription(p_id bigint) LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 UPDATE prescription SET is_deleted=true WHERE id=p_id AND NOT is_deleted;
 IF NOT FOUND THEN RAISE EXCEPTION 'Active prescription not found' USING ERRCODE='P0002'; END IF;
END $$;
CREATE PROCEDURE sp_admit_patient(p_patient bigint,p_doctor bigint,p_bed bigint,p_start timestamptz,INOUT p_id bigint DEFAULT NULL)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 INSERT INTO admission(patient_id,doctor_id,bed_id,admitted_at,updated_by)
 VALUES(p_patient,p_doctor,p_bed,p_start,fn_actor()) RETURNING id INTO p_id;
END $$;
CREATE PROCEDURE sp_discharge_patient(p_id bigint,p_end timestamptz) LANGUAGE plpgsql SECURITY DEFINER SET search_path=hospital,pg_temp AS $$
BEGIN
 UPDATE admission SET discharged_at=p_end WHERE id=p_id AND discharged_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Open admission not found' USING ERRCODE='P0002'; END IF;
END $$;
CREATE VIEW v_patients AS SELECT id,medical_record_number,first_name,last_name,birth_date,phone,
 fn_age_years(birth_date,current_date) AS age_years,updated_at,updated_by FROM patient WHERE NOT is_deleted;
CREATE VIEW v_patient_archive AS SELECT * FROM patient WHERE is_deleted;
CREATE VIEW v_doctors AS SELECT d.id,d.first_name,d.last_name,d.department_id,dp.name AS department_name
 FROM doctor d JOIN department dp ON dp.id=d.department_id;
-- Historical views keep records even after the parent patient is archived.
CREATE VIEW v_appointments AS SELECT a.*,p.first_name,p.last_name,d.last_name AS doctor_last_name
 FROM appointment a JOIN patient p ON p.id=a.patient_id JOIN doctor d ON d.id=a.doctor_id WHERE NOT a.is_deleted;
CREATE VIEW v_appointment_archive AS SELECT * FROM appointment WHERE is_deleted;
CREATE VIEW v_encounters AS SELECT e.*,a.patient_id,a.doctor_id,a.starts_at
 FROM encounter e JOIN appointment a ON a.id=e.appointment_id;
CREATE VIEW v_encounter_diagnoses AS SELECT ed.*,d.code,d.name FROM encounter_diagnosis ed JOIN diagnosis d ON d.id=ed.diagnosis_id;
CREATE VIEW v_prescriptions AS SELECT * FROM prescription WHERE NOT is_deleted;
CREATE VIEW v_prescription_items AS SELECT i.*,m.name,m.form,m.strength FROM prescription_item i
 JOIN prescription p ON p.id=i.prescription_id JOIN medication m ON m.id=i.medication_id WHERE NOT p.is_deleted;
CREATE VIEW v_admissions AS SELECT a.*,fn_stay_days(admitted_at,coalesce(discharged_at,current_timestamp)) AS stay_days FROM admission a;
CREATE VIEW v_free_beds AS SELECT b.id,b.room_id,b.bed_number FROM bed b WHERE NOT EXISTS(
 SELECT 1 FROM admission a WHERE a.bed_id=b.id AND tstzrange(a.admitted_at,a.discharged_at,'[)') @> current_timestamp);
CREATE VIEW v_lab_results AS SELECT o.id AS order_id,o.encounter_id,t.code,t.name,t.unit,i.result_text,i.resulted_at
 FROM lab_order o JOIN lab_order_item i ON i.lab_order_id=o.id JOIN lab_test t ON t.id=i.lab_test_id;
CREATE VIEW v_audit AS SELECT * FROM audit_log;
-- B-tree and GIN query examples are in 05_demo.sql.
COMMIT;
