import os
from pathlib import Path

import psycopg
from dotenv import load_dotenv


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def main():
    load_dotenv(PROJECT_ROOT / ".env")

    password = os.getenv("POSTGRES_PASSWORD")
    if not password:
        raise RuntimeError("В .env не указан POSTGRES_PASSWORD")

    with psycopg.connect(
        host=os.getenv("POSTGRES_HOST", "127.0.0.1"),
        port=int(os.getenv("POSTGRES_PORT", "5433")),
        dbname=os.getenv("POSTGRES_DB", "nhl"),
        user=os.getenv("POSTGRES_USER", "nhl"),
        password=password,
        connect_timeout=5,
        options="-c default_transaction_read_only=on",
    ) as connection:
        database, user, version = connection.execute(
            """
            SELECT
                current_database(),
                current_user,
                current_setting('server_version')
            """
        ).fetchone()

        table_count = connection.execute(
            """
            SELECT count(*)
            FROM information_schema.tables
            WHERE table_schema IN ('core', 'ingest')
              AND table_type = 'BASE TABLE'
            """
        ).fetchone()[0]

        view_count = connection.execute(
            """
            SELECT count(*)
            FROM information_schema.views
            WHERE table_schema IN ('core', 'ingest')
            """
        ).fetchone()[0]

        print(f"Подключение успешно: база={database}, пользователь={user}")
        print(f"PostgreSQL: {version}")
        print(f"Таблиц: {table_count}")
        print(f"Представлений: {view_count}")

        if table_count < 40 or view_count < 14:
            raise RuntimeError(
                "Не хватает объектов схемы. Проверь выполнение миграций."
            )


if __name__ == "__main__":
    main()