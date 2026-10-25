"""Import player identities and confirmed participation from archived boxscore."""

import argparse
import hashlib
import json
import os
import re

import psycopg
from psycopg.rows import dict_row
from dotenv import load_dotenv

from fetch_game import BASE_URL, PROJECT_ROOT
from import_game import integer, insert_row, parse_boxscore, sync_version


def toi_seconds(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+:[0-5]\d", value):
        raise ValueError("Некорректное или отсутствующее время игрока toi")
    minutes, seconds = map(int, value.split(":"))
    return minutes * 60 + seconds


def parse_players(data, game_id):
    match = parse_boxscore(data, game_id)
    if match["status"] != "finished":
        raise ValueError("Этот импортёр пока обрабатывает только завершённые матчи")
    stats = data.get("playerByGameStats")
    if not isinstance(stats, dict):
        raise ValueError("Отсутствует playerByGameStats")
    result = []
    seen = set()
    for side, key in (("home", "homeTeam"), ("away", "awayTeam")):
        groups = stats.get(key)
        if not isinstance(groups, dict):
            raise ValueError(f"Отсутствует статистика стороны {side}")
        participating = 0
        for group in ("forwards", "defense", "goalies"):
            rows = groups.get(group)
            if not isinstance(rows, list):
                raise ValueError(f"Неполный ответ: отсутствует массив {key}.{group}")
            for player in rows:
                if not isinstance(player, dict):
                    raise ValueError("Некорректная запись игрока")
                player_id = integer(player.get("playerId"), "playerId", 1)
                if player_id in seen:
                    raise ValueError("Игрок повторяется в ответе или указан за обе стороны")
                seen.add(player_id)
                name = player.get("name")
                name = name.get("default") if isinstance(name, dict) else None
                if not isinstance(name, str) or not name.strip():
                    raise ValueError("Отсутствует имя игрока")
                jersey = player.get("sweaterNumber")
                if jersey is not None:
                    integer(jersey, "sweaterNumber")
                    if jersey > 99:
                        raise ValueError("Номер игрока вне диапазона 0–99")
                seconds = toi_seconds(player.get("toi"))
                shifts = player.get("shifts")
                if shifts is not None:
                    integer(shifts, "shifts")
                starter = player.get("starter")
                if starter is not None and type(starter) is not bool:
                    raise ValueError("Некорректный признак starter")
                played = seconds > 0 or (shifts is not None and shifts > 0)
                played = played or (group == "goalies" and starter is True)
                participating += int(played)
                result.append({"external_id": str(player_id), "side": side,
                               "name": name.strip(), "jersey_number": jersey,
                               "played": played})
        if participating == 0:
            raise ValueError(f"Нет подтверждённых участников завершённого матча: {side}")
    return match, result


def ensure_player(connection, source_id, external_id):
    row = connection.execute(
        """SELECT p.player_id, p.person_id
           FROM ingest.player_source_ids AS m
           JOIN core.players AS p ON p.player_id = m.player_id
           WHERE m.source_id = %s AND m.external_id = %s""",
        (source_id, external_id),
    ).fetchone()
    if row:
        return row["player_id"], row["person_id"]
    person_id = connection.execute(
        "INSERT INTO core.persons DEFAULT VALUES RETURNING person_id"
    ).fetchone()["person_id"]
    player_id = insert_row(connection, "core", "players", {"person_id": person_id}, "player_id")
    insert_row(connection, "ingest", "player_source_ids",
               {"source_id": source_id, "external_id": external_id, "player_id": player_id})
    return player_id, person_id


def ensure_name(connection, person_id, name, raw_id, timestamp):
    current = connection.execute(
        """SELECT is_deleted FROM core.person_versions
           WHERE person_id = %s AND known_to = 'infinity'::timestamptz""",
        (person_id,),
    ).fetchone()
    if current and current["is_deleted"]:
        raise ValueError("Биография игрока удалена; требуется проверка")
    if current is None:
        insert_row(connection, "core", "person_versions", {
            "person_id": person_id, "name": name, "birth_date": None,
            "known_from": timestamp, "raw_id": raw_id,
        })


def import_players(game_id):
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
        application_name="nhl_player_import",
    ) as connection:
        run_id = insert_row(connection, "ingest", "ingestion_runs",
                            {"loader_version": "boxscore-players-v1"}, "run_id")
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
                    raise ValueError("Нет исходного ответа: сначала выполни fetch_game.py")
                raw_id = raw["raw_id"]
                path = (PROJECT_ROOT / raw["payload_uri"]).resolve()
                if not path.is_relative_to((PROJECT_ROOT / "data" / "raw").resolve()):
                    raise ValueError("Путь ответа находится вне data/raw")
                body = path.read_bytes()
                if hashlib.sha256(body).hexdigest() != raw["payload_hash"]:
                    raise ValueError("Хеш исходного ответа не совпадает")
                match, players = parse_players(json.loads(body), game_id)
                source_id = raw["source_id"]
                current = connection.execute(
                    """SELECT g.game_id, g.game_type_code, g.starts_at, g.status,
                              g.finish_type, s.start_year
                       FROM ingest.game_source_ids AS m
                       JOIN core.v_current_games AS g ON g.game_id = m.game_id
                       JOIN core.seasons AS s ON s.season_id = g.season_id
                       WHERE m.source_id = %s AND m.external_id = %s""",
                    (source_id, str(game_id)),
                ).fetchone()
                if current is None or any(current[k] != match[k] for k in
                        ("game_type_code", "starts_at", "status", "finish_type", "start_year")):
                    raise ValueError("Сначала выполни import_game.py для этого ответа")
                internal_id = current["game_id"]
                for side in ("home", "away"):
                    team = connection.execute(
                        """SELECT t.external_id, gt.official_score
                           FROM core.v_current_game_teams AS gt
                           JOIN ingest.team_source_ids AS t ON t.team_id = gt.team_id
                           WHERE gt.game_id = %s AND gt.side = %s AND t.source_id = %s""",
                        (internal_id, side, source_id),
                    ).fetchall()
                    if not any(t["external_id"] == match["sides"][side]["external_id"]
                               and t["official_score"] == match["sides"][side]["score"] for t in team):
                        raise ValueError("Команды или счёт изменились: сначала выполни import_game.py")
                latest = connection.execute(
                    """SELECT max(r.fetched_at) AS t FROM ingest.raw_snapshots AS r
                       JOIN (
                           SELECT raw_id FROM core.game_player_versions
                           WHERE game_id = %s AND known_to = 'infinity'::timestamptz
                           UNION
                           SELECT raw_id FROM ingest.game_coverage_versions
                           WHERE game_id = %s AND dataset_code = 'roster'
                             AND known_to = 'infinity'::timestamptz
                       ) AS used ON used.raw_id = r.raw_id""", (internal_id, internal_id)
                ).fetchone()["t"]
                if latest is not None and latest > raw["fetched_at"]:
                    raise ValueError("Ответ старее уже импортированного состава матча")
                timestamp = connection.execute("SELECT clock_timestamp() AS t").fetchone()["t"]
                changed = 0
                for player in players:
                    player_id, person_id = ensure_player(connection, source_id, player["external_id"])
                    ensure_name(connection, person_id, player["name"], raw_id, timestamp)
                    if player["played"]:
                        changed += int(sync_version(
                            connection, "core", "game_player_versions",
                            {"game_id": internal_id, "player_id": player_id},
                            ["side", "jersey_number"],
                            {"side": player["side"], "jersey_number": player["jersey_number"]},
                            raw_id, timestamp,
                        ))
                coverage = connection.execute(
                    """SELECT coverage_status FROM ingest.v_current_game_coverage
                       WHERE game_id = %s AND dataset_code = 'roster'""", (internal_id,)
                ).fetchone()
                if coverage is None or coverage["coverage_status"] == "partial":
                    sync_version(connection, "ingest", "game_coverage_versions",
                                 {"game_id": internal_id, "dataset_code": "roster"},
                                 ["coverage_status"], {"coverage_status": "partial"}, raw_id, timestamp)
                connection.execute(
                    """INSERT INTO ingest.ingestion_checkpoints (
                           source_id, stream_code, partition_key, cursor_value
                       ) VALUES (%s, 'boxscore_players', %s, %s)
                       ON CONFLICT (source_id, stream_code, partition_key)
                       DO UPDATE SET cursor_value = EXCLUDED.cursor_value,
                                     updated_at = clock_timestamp()""",
                    (source_id, str(game_id), str(raw_id)),
                )
                connection.execute(
                    "UPDATE ingest.ingestion_runs SET status = 'success', "
                    "finished_at = clock_timestamp() WHERE run_id = %s", (run_id,)
                )
            active = sum(p["played"] for p in players)
            print(f"Импорт игроков завершён: NHL game_id={game_id}, внутренний game_id={internal_id}")
            print(f"Игроков в ответе: {len(players)}; подтверждённых участников: {active}")
            print(f"Новых версий участия: {changed}")
            print(f"run_id={run_id}, raw_id={raw_id}")
        except BaseException as error:
            try:
                with connection.transaction():
                    insert_row(connection, "ingest", "ingestion_issues", {
                        "run_id": run_id, "raw_id": None, "error_code": type(error).__name__,
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
    parser = argparse.ArgumentParser(description="Импорт игроков из сохранённого boxscore")
    parser.add_argument("game_id", type=int)
    args = parser.parse_args()
    if args.game_id <= 0:
        parser.error("game_id должен быть положительным")
    import_players(args.game_id)
