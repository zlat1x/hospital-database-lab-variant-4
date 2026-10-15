import psycopg
from psycopg.rows import dict_row
from .repositories import (PatientRepository, AppointmentRepository, EncounterRepository,
                           PrescriptionRepository, AdmissionRepository)


class UnitOfWork:
    """One connection, one transaction. Explicit commit; otherwise rollback on exit.

    Use a fresh instance for each business operation. Repositories never commit.
    actor_id is supplied by trusted application logic, not by an unauthenticated user.
    """
    def __init__(self, dsn: str, actor_id: int):
        self._dsn = dsn
        self._actor_id = actor_id
        self._connection = None

    def __enter__(self):
        if self._connection is not None:
            raise RuntimeError('UnitOfWork is already active')
        connection = psycopg.connect(self._dsn, row_factory=dict_row)
        try:
            connection.execute('CALL hospital.sp_set_actor(%s)', (self._actor_id,))
        except BaseException:
            connection.close()
            raise
        self._connection = connection
        self.patients = PatientRepository(connection)
        self.appointments = AppointmentRepository(connection)
        self.encounters = EncounterRepository(connection)
        self.prescriptions = PrescriptionRepository(connection)
        self.admissions = AdmissionRepository(connection)
        return self

    def commit(self):
        if self._connection is None:
            raise RuntimeError('UnitOfWork is not active')
        self._connection.commit()
        # The caller should exit the block after commit; no implicit second unit of work.

    def __exit__(self, exc_type, exc, traceback):
        try:
            self._connection.rollback()  # harmless after commit; default is never auto-commit
        finally:
            self._connection.close()
            self._connection = None
        return False
