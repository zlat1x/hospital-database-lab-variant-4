"""python -m app.demo -- safe to repeat; adds a unique synthetic patient each time."""
import os
from uuid import uuid4
from datetime import date, datetime, timedelta, timezone
from .unit_of_work import UnitOfWork


def main():
    dsn = os.environ['HOSPITAL_DSN']
    tag = uuid4().hex[:12]
    # Separate patients can attend the same doctor only at non-overlapping times.
    # Use a unique far-future slot for a demonstration, not a real appointment.
    offset = int(uuid4().hex[:8], 16)
    start = datetime(2030, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=offset)
    with UnitOfWork(dsn, 1) as uow:
        patient = uow.patients.create(f'DEMO-{tag}', 'Навчальний', 'Приклад', date(2000, 1, 1))
        appointment = uow.appointments.book(patient, 1, start, start + timedelta(minutes=30))
        print('Patient:', uow.patients.get(patient))
        print('Appointments:', uow.appointments.for_patient(patient))
        uow.commit()
    # Another logical transaction creates encounter, diagnosis and prescription together.
    with UnitOfWork(dsn, 2) as uow:
        encounter = uow.appointments.complete(appointment, 'DEMO: навчальний огляд')
        uow.encounters.add_diagnosis(encounter, 1, True)
        prescription = uow.prescriptions.create(encounter)
        uow.prescriptions.add_item(prescription, 1, 'DEMO', 'DEMO', 1)
        print('Prescription:', uow.prescriptions.items(prescription))
        uow.commit()
    with UnitOfWork(dsn, 1) as uow:
        uow.patients.archive(patient)
        assert uow.patients.get(patient) is None
        # History remains accessible after patient soft delete.
        assert len(uow.appointments.for_patient(patient)) == 1
        uow.commit()
    print('Committed patient, appointment, encounter and prescription; soft delete verified.')


if __name__ == '__main__':
    main()
