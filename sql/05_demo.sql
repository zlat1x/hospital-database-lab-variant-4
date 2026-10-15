-- Run as hospital_app; seeded demonstration data.
SELECT * FROM hospital.v_patients;
SELECT * FROM hospital.v_doctors;
SELECT * FROM hospital.v_appointments;
SELECT * FROM hospital.v_encounters;
SELECT * FROM hospital.v_encounter_diagnoses;
SELECT * FROM hospital.v_prescriptions;
SELECT * FROM hospital.v_prescription_items;
SELECT * FROM hospital.v_admissions;
SELECT * FROM hospital.v_free_beds;
SELECT * FROM hospital.v_lab_results;
SELECT * FROM hospital.v_audit ORDER BY id DESC LIMIT 20;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM hospital.v_appointments
 WHERE patient_id=1 AND starts_at>='2026-01-01' ORDER BY starts_at;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM hospital.v_encounters
 WHERE to_tsvector('simple',notes) @@ plainto_tsquery('simple','demo');
-- Sequential scans on tiny tables are normal. GiST enforces no overlap on writes.
