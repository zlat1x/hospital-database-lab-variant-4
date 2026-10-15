-- PostgreSQL 16+. Run once in an empty database; no DROP operations.
BEGIN;
CREATE SCHEMA hospital;
REVOKE CREATE ON SCHEMA hospital FROM PUBLIC;
CREATE EXTENSION IF NOT EXISTS btree_gist;
SET search_path = hospital, public;
CREATE TABLE app_user (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 username text NOT NULL UNIQUE CHECK (btrim(username) <> ''),
 display_name text NOT NULL CHECK (btrim(display_name) <> ''),
 is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE department (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 name text NOT NULL UNIQUE CHECK (btrim(name) <> '')
);
CREATE TABLE specialty (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 name text NOT NULL UNIQUE
);
CREATE TABLE doctor (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 department_id bigint NOT NULL REFERENCES department(id),
 user_id bigint NOT NULL UNIQUE REFERENCES app_user(id),
 license_number text NOT NULL UNIQUE,
 first_name text NOT NULL,
 last_name text NOT NULL
);
CREATE TABLE doctor_specialty (
 doctor_id bigint REFERENCES doctor(id),
 specialty_id bigint REFERENCES specialty(id),
 PRIMARY KEY (doctor_id, specialty_id)
);
CREATE TABLE patient (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 medical_record_number text NOT NULL UNIQUE CHECK (btrim(medical_record_number) <> ''),
 first_name text NOT NULL CHECK (btrim(first_name) <> ''),
 last_name text NOT NULL CHECK (btrim(last_name) <> ''),
 birth_date date NOT NULL,
 phone text,
 is_deleted boolean NOT NULL DEFAULT false,
 deleted_at timestamptz,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_by bigint NOT NULL REFERENCES app_user(id),
 CHECK (is_deleted = (deleted_at IS NOT NULL))
);
CREATE TABLE room (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 department_id bigint NOT NULL REFERENCES department(id),
 room_number text NOT NULL,
 UNIQUE (department_id, room_number)
);
CREATE TABLE bed (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 room_id bigint NOT NULL REFERENCES room(id),
 bed_number text NOT NULL,
 UNIQUE (room_id, bed_number)
);
CREATE TABLE appointment (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 patient_id bigint NOT NULL REFERENCES patient(id),
 doctor_id bigint NOT NULL REFERENCES doctor(id),
 starts_at timestamptz NOT NULL,
 ends_at timestamptz NOT NULL,
 status text NOT NULL DEFAULT 'booked' CHECK (status IN ('booked','completed','cancelled')),
 is_deleted boolean NOT NULL DEFAULT false,
 deleted_at timestamptz,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_by bigint NOT NULL REFERENCES app_user(id),
 CHECK (ends_at > starts_at),
 CHECK (is_deleted = (deleted_at IS NOT NULL)),
 CHECK (NOT is_deleted OR status = 'cancelled'),
 EXCLUDE USING gist (doctor_id WITH =, tstzrange(starts_at,ends_at,'[)') WITH &&)
 WHERE (status <> 'cancelled' AND NOT is_deleted),
 EXCLUDE USING gist (patient_id WITH =, tstzrange(starts_at,ends_at,'[)') WITH &&)
 WHERE (status <> 'cancelled' AND NOT is_deleted)
);
CREATE TABLE encounter (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 appointment_id bigint NOT NULL UNIQUE REFERENCES appointment(id),
 notes text NOT NULL DEFAULT '',
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_by bigint NOT NULL REFERENCES app_user(id)
);
CREATE TABLE diagnosis (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 code text NOT NULL UNIQUE,
 name text NOT NULL
);
CREATE TABLE encounter_diagnosis (
 encounter_id bigint REFERENCES encounter(id),
 diagnosis_id bigint REFERENCES diagnosis(id),
 is_primary boolean NOT NULL DEFAULT false,
 PRIMARY KEY (encounter_id, diagnosis_id)
);
CREATE UNIQUE INDEX uq_primary_diagnosis ON encounter_diagnosis(encounter_id) WHERE is_primary;
CREATE TABLE medication (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 name text NOT NULL,
 form text NOT NULL,
 strength text NOT NULL,
 UNIQUE(name, form, strength)
);
CREATE TABLE prescription (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 encounter_id bigint NOT NULL REFERENCES encounter(id),
 issued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 is_deleted boolean NOT NULL DEFAULT false,
 deleted_at timestamptz,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_by bigint NOT NULL REFERENCES app_user(id),
 CHECK (is_deleted = (deleted_at IS NOT NULL))
);
CREATE TABLE prescription_item (
 prescription_id bigint REFERENCES prescription(id),
 medication_id bigint REFERENCES medication(id),
 dosage text NOT NULL CHECK (btrim(dosage) <> ''),
 frequency text NOT NULL CHECK (btrim(frequency) <> ''),
 duration_days integer NOT NULL CHECK (duration_days > 0),
 PRIMARY KEY (prescription_id, medication_id)
);
CREATE TABLE admission (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 patient_id bigint NOT NULL REFERENCES patient(id),
 doctor_id bigint NOT NULL REFERENCES doctor(id),
 bed_id bigint NOT NULL REFERENCES bed(id),
 admitted_at timestamptz NOT NULL,
 discharged_at timestamptz,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_by bigint NOT NULL REFERENCES app_user(id),
 CHECK (discharged_at IS NULL OR discharged_at > admitted_at),
 EXCLUDE USING gist (bed_id WITH =, tstzrange(admitted_at,discharged_at,'[)') WITH &&),
 EXCLUDE USING gist (patient_id WITH =, tstzrange(admitted_at,discharged_at,'[)') WITH &&)
);
CREATE TABLE lab_test (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 code text NOT NULL UNIQUE,
 name text NOT NULL,
 unit text
);
CREATE TABLE lab_order (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 encounter_id bigint NOT NULL REFERENCES encounter(id),
 ordered_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE lab_order_item (
 lab_order_id bigint REFERENCES lab_order(id),
 lab_test_id bigint REFERENCES lab_test(id),
 result_text text,
 resulted_at timestamptz,
 PRIMARY KEY(lab_order_id,lab_test_id),
 CHECK ((result_text IS NULL) = (resulted_at IS NULL))
);
CREATE TABLE audit_log (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 table_name text NOT NULL,
 row_id bigint NOT NULL,
 operation text NOT NULL CHECK(operation IN ('INSERT','UPDATE')),
 changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 changed_by bigint NOT NULL REFERENCES app_user(id),
 old_data jsonb,
 new_data jsonb NOT NULL
);
-- Three genuinely different access methods: B-tree, GiST, GIN.
CREATE INDEX ix_patient_name ON patient(last_name, first_name) WHERE NOT is_deleted;
CREATE INDEX ix_appointment_patient_time ON appointment(patient_id, starts_at) INCLUDE(status) WHERE NOT is_deleted;
CREATE INDEX ix_encounter_notes ON encounter USING gin(to_tsvector('simple',notes));
CREATE INDEX ix_audit_row ON audit_log(table_name,row_id,changed_at);
CREATE INDEX ix_doctor_department ON doctor(department_id);
CREATE INDEX ix_specialty_doctor ON doctor_specialty(specialty_id);
CREATE INDEX ix_prescription_encounter ON prescription(encounter_id);
CREATE INDEX ix_admission_doctor ON admission(doctor_id);
CREATE INDEX ix_diagnosis_encounter ON encounter_diagnosis(diagnosis_id);
CREATE INDEX ix_medication_prescription ON prescription_item(medication_id);
CREATE INDEX ix_lab_order_encounter ON lab_order(encounter_id);
CREATE INDEX ix_lab_test_order ON lab_order_item(lab_test_id);
COMMIT;
