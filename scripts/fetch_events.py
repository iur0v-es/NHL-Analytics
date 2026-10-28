"""Download one NHL play-by-play and archive it; do not modify core tables."""

import argparse
import hashlib
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

import psycopg
import requests
from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parents[1]
BASE_URL = "https://api-web.nhle.com/v1"
RETRY_STATUSES = {429, 500, 502, 503, 504}


def retry_delay(value, fallback):
    """Respect Retry-After; stop this run if the requested wait exceeds 60s."""
    if value is None:
        return fallback
    try:
        delay = float(value)
    except ValueError:
        try:
            date = parsedate_to_datetime(value)
            if date.tzinfo is None:
                date = date.replace(tzinfo=timezone.utc)
            delay = (date - datetime.now(timezone.utc)).total_seconds()
        except (ValueError, TypeError, OverflowError):
            return fallback
    return max(0, delay)


def fetch_response(session, url):
    for attempt in range(4):
        try:
            response = session.get(url, timeout=(10, 30))
        except (requests.ConnectionError, requests.Timeout):
            if attempt == 3:
                raise
            time.sleep(2 ** (attempt + 1))
            continue

        if response.status_code not in RETRY_STATUSES or attempt == 3:
            return response
        delay = retry_delay(response.headers.get("Retry-After"), 2 ** (attempt + 1))
        if delay > 60:
            return response
        response.close()
        time.sleep(delay)
    raise RuntimeError("Unreachable retry state")


def save_payload(project_root, body):
    digest = hashlib.sha256(body).hexdigest()
    directory = project_root / "data" / "raw" / "nhl_gamecenter"
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / f"{digest}.body"
    if target.exists():
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise OSError("Сохранённый файл повреждён: хеш не совпадает")
    else:
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=directory, delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(body)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, target)
            directory_fd = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    return digest, target.relative_to(project_root).as_posix()


def validate_payload(body, game_id):
    data = json.loads(body)
    if not isinstance(data, dict) or data.get("id") != game_id:
        raise ValueError("Ответ не содержит ожидаемый ID матча")
    return data


def fetch_events(game_id):
    load_dotenv(PROJECT_ROOT / ".env")
    password = os.getenv("POSTGRES_PASSWORD")
    if not password:
        raise ValueError("В .env не указан POSTGRES_PASSWORD")

    url = f"{BASE_URL}/gamecenter/{game_id}/play-by-play"
    with psycopg.connect(
        host=os.getenv("POSTGRES_HOST", "127.0.0.1"),
        port=int(os.getenv("POSTGRES_PORT", "5433")),
        dbname=os.getenv("POSTGRES_DB", "nhl"),
        user=os.getenv("POSTGRES_USER", "nhl"),
        password=password,
        connect_timeout=5,
        application_name="nhl_raw_loader",
        autocommit=True,
    ) as connection:
        locked = connection.execute(
            "SELECT pg_try_advisory_lock(17002, 1)"
        ).fetchone()[0]
        if not locked:
            raise RuntimeError("Другой сборщик исходных ответов уже работает")

        connection.execute(
            """INSERT INTO ingest.data_sources (source_code, base_uri)
               VALUES (%s, %s) ON CONFLICT (source_code) DO NOTHING""",
            ("nhl_gamecenter", BASE_URL),
        )
        source_id = connection.execute(
            "SELECT source_id FROM ingest.data_sources WHERE source_code = %s",
            ("nhl_gamecenter",),
        ).fetchone()[0]
        run_id = connection.execute(
            """INSERT INTO ingest.ingestion_runs (loader_version)
               VALUES (%s) RETURNING run_id""",
            ("raw-play-by-play-v1",),
        ).fetchone()[0]

        raw_id = None
        try:
            with requests.Session() as session:
                session.headers.update({"User-Agent": "nhl-analytics/0.1"})
                with fetch_response(session, url) as response:
                    body = response.content
                    fetched_at = datetime.now(timezone.utc)
                    digest, payload_uri = save_payload(PROJECT_ROOT, body)
                    raw_id = connection.execute(
                        """INSERT INTO ingest.raw_snapshots (
                               source_id, run_id, request_uri, fetched_at,
                               http_status, payload_hash, payload_uri
                           ) VALUES (%s, %s, %s, %s, %s, %s, %s)
                           RETURNING raw_id""",
                        (source_id, run_id, url, fetched_at,
                         response.status_code, digest, payload_uri),
                    ).fetchone()[0]
                    response.raise_for_status()
                    validate_payload(body, game_id)

            connection.execute(
                """UPDATE ingest.ingestion_runs
                   SET status = 'success', finished_at = clock_timestamp()
                   WHERE run_id = %s""",
                (run_id,),
            )
            print(f"Исходный ответ сохранён: game_id={game_id}")
            print(f"run_id={run_id}, raw_id={raw_id}")
            print(f"Файл: {payload_uri}")
        except BaseException as error:
            try:
                with connection.transaction():
                    connection.execute(
                        """INSERT INTO ingest.ingestion_issues (
                               run_id, raw_id, error_code, description, request_uri
                           ) VALUES (%s, %s, %s, %s, %s)""",
                        (run_id, raw_id, type(error).__name__,
                         str(error) or type(error).__name__, url),
                    )
                    connection.execute(
                        """UPDATE ingest.ingestion_runs
                           SET status = 'failed', finished_at = clock_timestamp()
                           WHERE run_id = %s""",
                        (run_id,),
                    )
            except Exception:
                print("Не удалось записать ошибку в БД; проверь журнал терминала.",
                      file=sys.stderr)
            raise


def main():
    parser = argparse.ArgumentParser(description="Архивирование play-by-play одного матча НХЛ")
    parser.add_argument("game_id", type=int, help="ID матча в источнике НХЛ")
    arguments = parser.parse_args()
    if arguments.game_id <= 0:
        parser.error("game_id должен быть положительным")
    fetch_events(arguments.game_id)


if __name__ == "__main__":
    main()
