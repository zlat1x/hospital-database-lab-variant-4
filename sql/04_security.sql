-- Run by database administrator. Dedicated educational database/role only.
BEGIN;
CREATE ROLE hospital_app LOGIN PASSWORD 'lab_demo_only';
GRANT USAGE ON SCHEMA hospital TO hospital_app;
REVOKE ALL ON ALL TABLES IN SCHEMA hospital FROM PUBLIC, hospital_app;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA hospital FROM PUBLIC, hospital_app;
REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA hospital FROM PUBLIC;
GRANT SELECT ON hospital.v_patients,hospital.v_patient_archive,hospital.v_doctors,
 hospital.v_appointments,hospital.v_appointment_archive,hospital.v_encounters,
 hospital.v_encounter_diagnoses,hospital.v_prescriptions,hospital.v_prescription_items,
 hospital.v_admissions,hospital.v_free_beds,hospital.v_lab_results,hospital.v_audit TO hospital_app;
GRANT EXECUTE ON FUNCTION hospital.fn_age_years(date,date),hospital.fn_stay_days(timestamptz,timestamptz) TO hospital_app;
DO $$ DECLARE r record; BEGIN
 FOR r IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='hospital' AND p.prokind='p' LOOP
  EXECUTE format('GRANT EXECUTE ON PROCEDURE %s TO hospital_app',r.signature);
 END LOOP;
END $$;
ALTER DEFAULT PRIVILEGES IN SCHEMA hospital REVOKE EXECUTE ON ROUTINES FROM PUBLIC;
COMMIT;
