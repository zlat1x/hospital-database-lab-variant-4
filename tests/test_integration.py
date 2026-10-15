"""Run against a seeded educational database, as hospital_app (never the owner)."""
import os
import unittest
from datetime import date, datetime, timedelta, timezone
from uuid import uuid4
import psycopg
from psycopg.rows import dict_row
from app.unit_of_work import UnitOfWork

DSN = os.environ.get('HOSPITAL_DSN')

@unittest.skipUnless(DSN, 'Set HOSPITAL_DSN to the application role connection string')
class HospitalTests(unittest.TestCase):
    def setUp(self):
        self.tag = uuid4().hex
        self.start = datetime(2030, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=int(self.tag[:8], 16))

    def patient(self, uow):
        return uow.patients.create('TEST-'+self.tag, 'Test', 'Patient', date(2000,1,1))

    def query(self, sql, params=()):
        with psycopg.connect(DSN, row_factory=dict_row) as c:
            return c.execute(sql, params).fetchall()

    def test_01_commit_linked_entities(self):
        with UnitOfWork(DSN,1) as u:
            p=self.patient(u)
            a=u.appointments.book(p,1,self.start,self.start+timedelta(minutes=30))
            u.commit()
        with UnitOfWork(DSN,1) as u:
            self.assertIsNotNone(u.patients.get(p))
            self.assertEqual(u.appointments.for_patient(p)[0]['id'],a)

    def test_02_default_rollback(self):
        with UnitOfWork(DSN,1) as u:
            p=self.patient(u)
        with UnitOfWork(DSN,1) as u:
            self.assertIsNone(u.patients.get(p))
        self.assertEqual(self.query("SELECT * FROM hospital.v_audit WHERE table_name='patient' AND row_id=%s",(p,)),[])

    def test_03_error_rolls_back_patient_and_booking(self):
        with self.assertRaises(psycopg.errors.CheckViolation):
            with UnitOfWork(DSN,1) as u:
                p=self.patient(u)
                u.appointments.book(p,1,self.start,self.start-timedelta(minutes=1))
                u.commit()
        with UnitOfWork(DSN,1) as u:
            self.assertIsNone(u.patients.get(p))

    def test_04_soft_delete_restore_audit(self):
        with UnitOfWork(DSN,1) as u:
            p=self.patient(u)
            old=u.patients.get(p)['updated_at']
            u.patients.archive(p)
            self.assertIsNone(u.patients.get(p))
            u.patients.restore(p)
            self.assertGreater(u.patients.get(p)['updated_at'],old)
            u.commit()
        changes=self.query("SELECT * FROM hospital.v_audit WHERE table_name='patient' AND row_id=%s ORDER BY id",(p,))
        self.assertEqual(len(changes),3)
        self.assertTrue(changes[1]['new_data']['is_deleted'])
        self.assertTrue(all(r['changed_by']==1 for r in changes))

    def test_05_overlap_rejected(self):
        with UnitOfWork(DSN,1) as u:
            p=self.patient(u)
            a=u.appointments.book(p,1,self.start,self.start+timedelta(minutes=30))
            u.commit()
        with self.assertRaises(psycopg.errors.ExclusionViolation):
            with UnitOfWork(DSN,1) as u:
                u.appointments.book(p,1,self.start+timedelta(minutes=10),self.start+timedelta(minutes=40))
        with UnitOfWork(DSN,1) as u:
            u.appointments.cancel(a)
            # Cancelled slot becomes available, and adjacent [start,end) slots are legal.
            u.appointments.book(p,1,self.start,self.start+timedelta(minutes=30))
            u.appointments.book(p,1,self.start+timedelta(minutes=30),self.start+timedelta(minutes=60))

    def test_06_active_patient_cannot_be_deleted(self):
        with self.assertRaises(psycopg.errors.CheckViolation):
            with UnitOfWork(DSN,1) as u:
                p=self.patient(u)
                u.appointments.book(p,1,self.start,self.start+timedelta(minutes=30))
                u.patients.archive(p)

    def test_07_optimistic_concurrency(self):
        with UnitOfWork(DSN,1) as u:
            p=self.patient(u)
            old=u.patients.get(p)['updated_at']
            u.patients.change_phone(p,'111',old)
            u.commit()
        with self.assertRaises(psycopg.errors.SerializationFailure):
            with UnitOfWork(DSN,1) as u:
                u.patients.change_phone(p,'222',old)

    def test_08_completed_appointment_and_prescription(self):
        with UnitOfWork(DSN,2) as u:
            p=self.patient(u)
            a=u.appointments.book(p,1,self.start,self.start+timedelta(minutes=30))
            e=u.appointments.complete(a,'demo clinical notes')
            u.encounters.add_diagnosis(e,1,True)
            rx=u.prescriptions.create(e)
            u.prescriptions.add_item(rx,1,'DEMO','DEMO',1)
            self.assertEqual(len(u.prescriptions.items(rx)),1)
            u.prescriptions.archive(rx)
            self.assertEqual(u.prescriptions.items(rx),[])
            u.patients.archive(p)
            self.assertIsNotNone(u.encounters.get(e))
            self.assertEqual(u.encounters.get(e)['updated_by'],2)

    def test_09_second_primary_diagnosis_rejected(self):
        with self.assertRaises(psycopg.errors.UniqueViolation):
            with UnitOfWork(DSN,1) as u:
                p=self.patient(u)
                a=u.appointments.book(p,1,self.start,self.start+timedelta(minutes=30))
                e=u.appointments.complete(a,'demo')
                u.encounters.add_diagnosis(e,1,True)
                u.encounters.add_diagnosis(e,2,True)

    def test_10_bed_overlap_and_discharge(self):
        with UnitOfWork(DSN,1) as u:
            p=self.patient(u)
            a=u.admissions.admit(p,1,2,self.start)
            u.admissions.discharge(a,self.start+timedelta(days=1))
            u.commit()
        with self.assertRaises(psycopg.errors.ExclusionViolation):
            with UnitOfWork(DSN,1) as u:
                u.admissions.admit(p,1,2,self.start+timedelta(hours=1))

    def test_11_base_tables_are_inaccessible(self):
        for sql in ['SELECT * FROM hospital.patient','DELETE FROM hospital.patient WHERE id=-1',
                    "UPDATE hospital.patient SET phone='x' WHERE id=-1"]:
            with self.subTest(sql=sql),self.assertRaises(psycopg.errors.InsufficientPrivilege):
                self.query(sql)

    def test_12_actor_required(self):
        with self.assertRaises(psycopg.errors.InvalidParameterValue):
            with UnitOfWork(DSN,-1): pass
        with self.assertRaises(psycopg.errors.InvalidParameterValue):
            self.query('CALL hospital.sp_create_patient(%s,%s,%s,%s,%s,NULL)',
                       ('NO-ACTOR-'+self.tag,'Test','Actor',date(2000,1,1),None))

    def test_13_foreign_key_required(self):
        with self.assertRaises(psycopg.errors.ForeignKeyViolation):
            with UnitOfWork(DSN,1) as u:
                p=self.patient(u)
                u.appointments.book(p,-1,self.start,self.start+timedelta(minutes=30))

    def test_14_future_birth_date_rejected(self):
        with self.assertRaises(psycopg.errors.CheckViolation):
            with UnitOfWork(DSN,1) as u:
                u.patients.create('FUTURE-'+self.tag,'Test','Patient',date.today()+timedelta(days=1))

    def test_15_duplicate_medical_record_number_rejected(self):
        with self.assertRaises(psycopg.errors.UniqueViolation):
            with UnitOfWork(DSN,1) as u:
                self.patient(u)
                self.patient(u)

    def test_16_deleted_patient_cannot_book(self):
        with self.assertRaises(psycopg.errors.CheckViolation):
            with UnitOfWork(DSN,1) as u:
                p=self.patient(u)
                u.patients.archive(p)
                u.appointments.book(p,1,self.start,self.start+timedelta(minutes=30))

if __name__=='__main__': unittest.main(verbosity=2)
