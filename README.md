# Hospital Database — Variant 4

Навчальний проєкт бази даних лікарні для дисципліни «Сучасні технології баз даних» (варіант 4).

## Що реалізовано

- Облік пацієнтів, лікарів, відділень, спеціальностей, палат і ліжок.
- Запис на прийом, медичні огляди, діагнози, рецепти, лабораторні дослідження та госпіталізації.
- Перевірка цілісності даних і заборона перетину зайнятих часових інтервалів.
- Soft delete для пацієнтів, записів на прийом і рецептів; відстеження автора та часу змін, журнал аудиту.
- Збережені процедури, функції, тригери, представлення (View) та індекси B-tree, GIN і GiST.
- Доступ із Python через Repository + Unit of Work: робота з даними лише через процедури та View.

**Стек:** PostgreSQL 16, Docker Compose, Python 3, psycopg 3. Модель містить 20 таблиць.

## Структура

- `schema/` — ER-схема у DBML (для [dbdiagram.io](https://dbdiagram.io/home)), SVG та PDF.
- `sql/` — схема БД, логіка, початкові дані, права доступу, демонстраційні запити та SQL-перевірки.
- `app/` — репозиторії, Unit of Work і приклад використання.
- `tests/` — 16 інтеграційних тестів.
- `compose.yaml` — запуск PostgreSQL 16 у Docker.

## Запуск (Windows PowerShell)

Потрібні **Docker Desktop** (Linux containers), **Python 3.11+** та вільний порт **5435**.

1. Створити `.env` із шаблону й задати власний `POSTGRES_PASSWORD`:

   ```powershell
   Copy-Item .env.example .env
   ```

2. Запустити базу даних (SQL зі `sql/01_schema.sql`–`04_security.sql` виконається автоматично під час першої ініціалізації):

   ```powershell
   docker compose up -d --wait
   ```

3. Встановити залежності Python і запустити демонстрацію:

   ```powershell
   py -3 -m venv .venv
   .venv\Scripts\python.exe -m pip install -r requirements.txt
   $env:HOSPITAL_DSN = "postgresql://hospital_app:lab_demo_only@127.0.0.1:5435/hospital?connect_timeout=5"
   .venv\Scripts\python.exe -m app.demo
   ```

## Перевірка

Інтеграційні тести:

```powershell
.venv\Scripts\python.exe -m unittest discover -s tests -v
```

SQL-перевірки та демонстраційні запити:

```powershell
cmd /c "docker compose exec -T db psql -U postgres -d hospital -v ON_ERROR_STOP=1 < sql\06_checks.sql"
cmd /c "docker compose exec -T db psql -U hospital_app -d hospital -v ON_ERROR_STOP=1 < sql\05_demo.sql"
```

Для перегляду через pgAdmin: host `127.0.0.1`, port `5435`, database `hospital`, user `postgres`, пароль із `.env`.

> Роль `hospital_app` і пароль `lab_demo_only` призначені лише для навчальної демонстрації. Не використовуйте їх у реальному застосунку. SQL-скрипти ініціалізації автоматично виконуються тільки для нового Docker volume; `docker compose down -v` видаляє збережені дані.
