"""Only CALL and SELECT from views. Connection/transaction belongs to the UoW."""
from datetime import date, datetime
from psycopg import Connection


class PatientRepository:
    def __init__(self, connection: Connection):
        self._connection = connection

    def create(self, mrn: str, first: str, last: str, birth: date, phone: str | None = None) -> int:
        return self._connection.execute(
            'CALL hospital.sp_create_patient(%s,%s,%s,%s,%s,NULL)',
            (mrn, first, last, birth, phone)).fetchone()['p_id']

    def get(self, patient_id: int):
        return self._connection.execute('SELECT * FROM hospital.v_patients WHERE id=%s', (patient_id,)).fetchone()

    def archive(self, patient_id: int):
        self._connection.execute('CALL hospital.sp_delete_patient(%s)', (patient_id,))

    def restore(self, patient_id: int):
        self._connection.execute('CALL hospital.sp_restore_patient(%s)', (patient_id,))

    def change_phone(self, patient_id: int, phone: str | None, expected_updated_at: datetime):
        self._connection.execute('CALL hospital.sp_update_patient(%s,%s,%s)',
                                 (patient_id, phone, expected_updated_at))


class AppointmentRepository:
    def __init__(self, connection: Connection):
        self._connection = connection

    def book(self, patient_id: int, doctor_id: int, start: datetime, end: datetime) -> int:
        return self._connection.execute('CALL hospital.sp_book_appointment(%s,%s,%s,%s,NULL)',
                                        (patient_id, doctor_id, start, end)).fetchone()['p_id']

    def cancel(self, appointment_id: int):
        self._connection.execute('CALL hospital.sp_cancel_appointment(%s)', (appointment_id,))

    def for_patient(self, patient_id: int):
        return self._connection.execute(
            'SELECT * FROM hospital.v_appointments WHERE patient_id=%s ORDER BY starts_at',
            (patient_id,)).fetchall()

    def complete(self, appointment_id: int, notes: str) -> int:
        return self._connection.execute('CALL hospital.sp_complete_appointment(%s,%s,NULL)',
                                        (appointment_id, notes)).fetchone()['p_encounter']


class EncounterRepository:
    def __init__(self, connection: Connection):
        self._connection = connection

    def get(self, encounter_id: int):
        return self._connection.execute('SELECT * FROM hospital.v_encounters WHERE id=%s', (encounter_id,)).fetchone()

    def add_diagnosis(self, encounter_id: int, diagnosis_id: int, primary: bool = False):
        self._connection.execute('CALL hospital.sp_add_diagnosis(%s,%s,%s)',
                                 (encounter_id, diagnosis_id, primary))

    def change_notes(self, encounter_id: int, notes: str, expected_updated_at: datetime):
        self._connection.execute('CALL hospital.sp_update_encounter(%s,%s,%s)',
                                 (encounter_id, notes, expected_updated_at))


class PrescriptionRepository:
    def __init__(self, connection: Connection):
        self._connection = connection

    def create(self, encounter_id: int) -> int:
        return self._connection.execute('CALL hospital.sp_create_prescription(%s,NULL)', (encounter_id,)).fetchone()['p_id']

    def add_item(self, prescription_id: int, medication_id: int, dosage: str, frequency: str, days: int):
        self._connection.execute('CALL hospital.sp_add_prescription_item(%s,%s,%s,%s,%s)',
                                 (prescription_id, medication_id, dosage, frequency, days))

    def items(self, prescription_id: int):
        return self._connection.execute('SELECT * FROM hospital.v_prescription_items WHERE prescription_id=%s',
                                        (prescription_id,)).fetchall()

    def archive(self, prescription_id: int):
        self._connection.execute('CALL hospital.sp_delete_prescription(%s)', (prescription_id,))


class AdmissionRepository:
    def __init__(self, connection: Connection):
        self._connection = connection

    def admit(self, patient_id: int, doctor_id: int, bed_id: int, start: datetime) -> int:
        return self._connection.execute('CALL hospital.sp_admit_patient(%s,%s,%s,%s,NULL)',
                                        (patient_id, doctor_id, bed_id, start)).fetchone()['p_id']

    def discharge(self, admission_id: int, end: datetime):
        self._connection.execute('CALL hospital.sp_discharge_patient(%s,%s)', (admission_id, end))

    def free_beds(self):
        return self._connection.execute('SELECT * FROM hospital.v_free_beds ORDER BY id').fetchall()
