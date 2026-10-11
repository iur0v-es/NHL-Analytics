"""Import match metadata and result from an archived NHL boxscore."""

import argparse
import hashlib
import json
import os
from datetime import datetime

import psycopg
from psycopg import sql
from psycopg.rows import dict_row
from dotenv import load_dotenv

from fetch_game import BASE_URL, PROJECT_ROOT


def integer(value, label, minimum=0):
    if type(value) is not int or value < minimum:
        raise ValueError(f"Некорректное поле {label}: ожидается целое >= {minimum}")
    return value


def parse_boxscore(data, expected_game_id):
    if not isinstance(data, dict) or data.get("id") != expected_game_id:
        raise ValueError("Не совпадает ID матча")
    season = integer(data.get("season"), "season", 19171918)
    start_year, end_year = divmod(season, 10000)
    if end_year != start_year + 1:
        raise ValueError("Некорректный код сезона")
    game_type = {2: "regular", 3: "playoff"}.get(data.get("gameType"))
    if game_type is None:
        raise ValueError("Поддерживаются только регулярные матчи и плей-офф")
    if data.get("gameScheduleState") not in (None, "OK"):
        raise ValueError("Изменённое расписание требует отдельной обработки")
    states = {"FUT": "scheduled", "PRE": "scheduled", "LIVE": "live",
              "CRIT": "live", "FINAL": "finished", "OFF": "finished"}
    status = states.get(data.get("gameState"))
    if status is None:
        raise ValueError("Неизвестное состояние матча")
    starts_at = data.get("startTimeUTC")
    if starts_at is not None:
        if not isinstance(starts_at, str):
            raise ValueError("Некорректное время начала")
        starts_at = datetime.fromisoformat(starts_at.replace("Z", "+00:00"))
        if starts_at.tzinfo is None:
            raise ValueError("Время начала не содержит часовой пояс")
    finish_type = None
    if status == "finished":
        outcome = data.get("gameOutcome") or {}
        finish_type = {"REG": "regulation", "OT": "overtime", "SO": "shootout"}.get(
            outcome.get("lastPeriodType")
        )
        if starts_at is None or finish_type is None:
            raise ValueError("Для завершённого матча отсутствует время или способ завершения")
        if game_type == "playoff" and finish_type == "shootout":
            raise ValueError("Буллиты в плей-офф не поддерживаются")
    sides = {}
    for side, field in (("home", "homeTeam"), ("away", "awayTeam")):
        team = data.get(field)
        if not isinstance(team, dict):
            raise ValueError(f"Отсутствует команда {side}")
        team_id = integer(team.get("id"), f"{field}.id", 1)
        score = team.get("score")
        if score is not None:
            score = integer(score, f"{field}.score")
            if score > 32767:
                raise ValueError("Счёт выходит за диапазон SMALLINT")
        if status == "finished" and score is None:
            raise ValueError("Отсутствует финальный счёт")
        place = (team.get("placeName") or {}).get("default")
        common = (team.get("commonName") or {}).get("default")
        name = f"{place} {common}" if isinstance(place, str) and isinstance(common, str) else None
        sides[side] = {"external_id": str(team_id), "score": score, "name": name}
    if sides["home"]["external_id"] == sides["away"]["external_id"]:
        raise ValueError("У матча указана одна команда за обе стороны")
    return {
        "start_year": start_year, "game_type_code": game_type,
        "starts_at": starts_at, "status": status, "finish_type": finish_type,
        "sides": sides,
    }


def insert_row(connection, schema, table, values, returning=None):
    query = sql.SQL("INSERT INTO {}.{} ({}) VALUES ({})").format(
        sql.Identifier(schema), sql.Identifier(table),
        sql.SQL(", ").join(map(sql.Identifier, values)),
        sql.SQL(", ").join(sql.Placeholder() for _ in values),
    )
    if returning:
        query += sql.SQL(" RETURNING {}").format(sql.Identifier(returning))
    cursor = connection.execute(query, list(values.values()))
    return cursor.fetchone()[returning] if returning else None


def mapped_id(connection, source_id, external_id, table, key):
    query = sql.SQL("SELECT {} FROM ingest.{} WHERE source_id = %s AND external_id = %s").format(
        sql.Identifier(key), sql.Identifier(f"{table}_source_ids")
    )
    row = connection.execute(query, (source_id, external_id)).fetchone()
    if row:
        return row[key]
    value = connection.execute(
        sql.SQL("INSERT INTO core.{} DEFAULT VALUES RETURNING {}").format(
            sql.Identifier(f"{table}s"), sql.Identifier(key)
        )
    ).fetchone()[key]
    insert_row(connection, "ingest", f"{table}_source_ids",
               {"source_id": source_id, "external_id": external_id, key: value})
    return value


def version_values(current, fields, updates):
    """Preserve already enriched fields such as arena_id."""
    return {field: updates[field] if field in updates else
            (current[field] if current else None) for field in fields}


def sync_version(connection, schema, table, keys, fields, updates, raw_id, timestamp):
    condition = sql.SQL(" AND ").join(
        sql.SQL("{} = %s").format(sql.Identifier(key)) for key in keys
    )
    selected_fields = [*fields, "known_from", "is_deleted"]

    row = connection.execute(
        sql.SQL(
            "SELECT {} FROM {}.{} "
            "WHERE {} AND known_to = 'infinity'::timestamptz"
        ).format(
            sql.SQL(", ").join(
                sql.Identifier(field) for field in selected_fields
            ),
            sql.Identifier(schema),
            sql.Identifier(table),
            condition,
        ),
        list(keys.values()),
    ).fetchone()
    if row and row["is_deleted"]:
        raise ValueError("Автоматическое восстановление удалённого факта требует проверки")
    values = version_values(row, fields, updates)
    if row and all(row[field] == value for field, value in values.items()):
        return False
    if row:
        if timestamp <= row["known_from"]:
            raise ValueError("Время новой версии не позже предыдущей")
        connection.execute(
            sql.SQL("UPDATE {}.{} SET known_to = %s WHERE {} AND known_to = 'infinity'::timestamptz").format(
                sql.Identifier(schema), sql.Identifier(table), condition
            ), [timestamp, *keys.values()],
        )
    insert_row(connection, schema, table,
               {**keys, **values, "known_from": timestamp, "raw_id": raw_id})
    return True


def record_name_observation(connection, team_id, name, raw_id, timestamp):
    if not name:
        return
    exists = connection.execute(
        """SELECT 1 FROM core.team_name_versions
           WHERE team_id = %s AND name = %s AND NOT is_deleted
             AND known_to = 'infinity'::timestamptz""", (team_id, name)
    ).fetchone()
    if not exists:
        record_id = connection.execute(
            "INSERT INTO core.team_names DEFAULT VALUES RETURNING team_name_id"
        ).fetchone()["team_name_id"]
        insert_row(connection, "core", "team_name_versions", {
            "team_name_id": record_id, "team_id": team_id, "name": name,
            "valid_from": None, "valid_to": None,
            "known_from": timestamp, "raw_id": raw_id,
        })


def import_game(game_id):
    load_dotenv(PROJECT_ROOT / ".env")
    password = os.getenv("POSTGRES_PASSWORD")
    if not password:
        raise ValueError("В .env не указан POSTGRES_PASSWORD")
    request_uri = f"{BASE_URL}/gamecenter/{game_id}/boxscore"
    with psycopg.connect(
        host=os.getenv("POSTGRES_HOST", "127.0.0.1"),
        port=int(os.getenv("POSTGRES_PORT", "5433")),
        dbname=os.getenv("POSTGRES_DB", "nhl"),
        user=os.getenv("POSTGRES_USER", "nhl"), password=password,
        connect_timeout=5, autocommit=True, row_factory=dict_row,
        application_name="nhl_boxscore_import",
    ) as connection:
        run_id = insert_row(connection, "ingest", "ingestion_runs",
                            {"loader_version": "boxscore-import-v1"}, "run_id")
        raw_id = None
        try:
            with connection.transaction():
                connection.execute("SELECT pg_advisory_xact_lock(17001, 1)")
                raw = connection.execute(
                    """SELECT r.* FROM ingest.raw_snapshots AS r
                       JOIN ingest.data_sources AS s USING (source_id)
                       JOIN ingest.ingestion_runs AS ir ON ir.run_id = r.run_id
                       WHERE s.source_code = 'nhl_gamecenter' AND r.request_uri = %s
                         AND r.http_status = 200 AND ir.status = 'success'
                       ORDER BY r.fetched_at DESC, r.raw_id DESC LIMIT 1""", (request_uri,)
                ).fetchone()
                if raw is None:
                    raise ValueError("Нет успешно сохранённого ответа. Сначала запусти fetch_game.py")
                raw_id = raw["raw_id"]
                path = (PROJECT_ROOT / raw["payload_uri"]).resolve()
                if not path.is_relative_to((PROJECT_ROOT / "data" / "raw").resolve()):
                    raise ValueError("Путь ответа находится вне data/raw")
                body = path.read_bytes()
                if hashlib.sha256(body).hexdigest() != raw["payload_hash"]:
                    raise ValueError("Хеш исходного файла не совпадает")
                match = parse_boxscore(json.loads(body), game_id)
                source_id = raw["source_id"]
                internal_game_id = mapped_id(connection, source_id, str(game_id), "game", "game_id")

                # An old response must not overwrite already imported newer data.
                latest = connection.execute(
                    """SELECT max(r.fetched_at) AS fetched_at FROM ingest.raw_snapshots AS r
                       JOIN (
                           SELECT raw_id FROM core.game_versions
                           WHERE game_id = %s AND known_to = 'infinity'::timestamptz
                           UNION
                           SELECT raw_id FROM core.game_team_versions
                           WHERE game_id = %s AND known_to = 'infinity'::timestamptz
                           UNION
                           SELECT raw_id FROM ingest.game_coverage_versions
                           WHERE game_id = %s AND dataset_code IN ('metadata', 'results')
                             AND known_to = 'infinity'::timestamptz
                       ) AS used ON used.raw_id = r.raw_id""",
                    (internal_game_id, internal_game_id, internal_game_id),
                ).fetchone()["fetched_at"]
                if latest is not None and latest > raw["fetched_at"]:
                    raise ValueError("Ответ старее уже импортированных сведений")

                timestamp = connection.execute("SELECT clock_timestamp() AS t").fetchone()["t"]
                connection.execute(
                    "INSERT INTO core.seasons (start_year, status) VALUES (%s, 'unknown') "
                    "ON CONFLICT (start_year) DO NOTHING", (match["start_year"],)
                )
                season_id = connection.execute(
                    "SELECT season_id FROM core.seasons WHERE start_year = %s", (match["start_year"],)
                ).fetchone()["season_id"]
                changed = sync_version(
                    connection, "core", "game_versions", {"game_id": internal_game_id},
                    ["season_id", "arena_id", "game_type_code", "starts_at", "status", "finish_type"],
                    {"season_id": season_id, **{k: match[k] for k in
                     ("game_type_code", "starts_at", "status", "finish_type")}}, raw_id, timestamp,
                )
                for side, team in match["sides"].items():
                    team_id = mapped_id(connection, source_id, team["external_id"], "team", "team_id")
                    connection.execute(
                        "INSERT INTO core.team_seasons (team_id, season_id) VALUES (%s, %s) "
                        "ON CONFLICT DO NOTHING", (team_id, season_id)
                    )
                    record_name_observation(connection, team_id, team["name"], raw_id, timestamp)
                    changed |= sync_version(
                        connection, "core", "game_team_versions",
                        {"game_id": internal_game_id, "side": side}, ["team_id", "official_score"],
                        {"team_id": team_id, "official_score": team["score"]}, raw_id, timestamp,
                    )
                for dataset, status in (("metadata", "partial"),
                                        ("results", "complete" if match["status"] == "finished" else "partial")):
                    sync_version(connection, "ingest", "game_coverage_versions",
                                 {"game_id": internal_game_id, "dataset_code": dataset},
                                 ["coverage_status"], {"coverage_status": status}, raw_id, timestamp)
                # Per-game checkpoint: failed games cannot be skipped by a season-wide cursor.
                connection.execute(
                    """INSERT INTO ingest.ingestion_checkpoints (
                           source_id, stream_code, partition_key, cursor_value
                       ) VALUES (%s, 'boxscore_import', %s, %s)
                       ON CONFLICT (source_id, stream_code, partition_key)
                       DO UPDATE SET cursor_value = EXCLUDED.cursor_value,
                                     updated_at = clock_timestamp()""",
                    (source_id, str(game_id), str(raw_id)),
                )
                connection.execute(
                    "UPDATE ingest.ingestion_runs SET status = 'success', "
                    "finished_at = clock_timestamp() WHERE run_id = %s", (run_id,)
                )
            print(f"Импорт завершён: NHL game_id={game_id}, внутренний game_id={internal_game_id}")
            print("Матч или результат обновлены" if changed else "Матч и результат уже совпадают: новых версий нет")
            print(f"run_id={run_id}, raw_id={raw_id}")
        except BaseException as error:
            try:
                with connection.transaction():
                    # raw_id belongs to the FETCH run, not this import run.
                    # Keep the FK field NULL; retain the input reference in the description.
                    insert_row(connection, "ingest", "ingestion_issues", {
                        "run_id": run_id, "raw_id": None,
                        "error_code": type(error).__name__,
                        "description": f"input raw_id={raw_id}: {str(error) or type(error).__name__}",
                        "request_uri": request_uri,
                    })
                    connection.execute(
                        "UPDATE ingest.ingestion_runs SET status = 'failed', "
                        "finished_at = clock_timestamp() WHERE run_id = %s", (run_id,)
                    )
            except Exception:
                print("Не удалось записать ошибку в БД; смотри исходную ошибку ниже.")
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Импорт сохранённого boxscore в core")
    parser.add_argument("game_id", type=int)
    args = parser.parse_args()
    if args.game_id <= 0:
        parser.error("game_id должен быть положительным")
    import_game(args.game_id)
