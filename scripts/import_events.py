"""Import goals and assists only after reconciliation with a final boxscore."""
import argparse
from collections import Counter
import hashlib
import json
import os
import re

import psycopg
from psycopg import sql
from psycopg.rows import dict_row
from dotenv import load_dotenv

from fetch_game import BASE_URL, PROJECT_ROOT
from import_game import integer, insert_row, parse_boxscore
from import_players import ensure_player, ensure_name


def event_seconds(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+:[0-5]\d", value):
        raise ValueError("Некорректное время события")
    minutes, seconds = map(int, value.split(":"))
    return minutes * 60 + seconds


def validate_shootout_sequence(attempts, winner):
    if not attempts:
        raise ValueError("Отсутствуют попытки серии буллитов")
    counts, goals = Counter(), Counter()
    first_side = attempts[0]['side']
    ended = False
    for index, attempt in enumerate(attempts):
        if ended:
            raise ValueError("В серии есть попытки после определения победителя")
        expected = first_side if index % 2 == 0 else ('away' if first_side == 'home' else 'home')
        if attempt['side'] != expected:
            raise ValueError("Нарушено чередование сторон в серии буллитов")
        side = attempt['side']
        counts[side] += 1
        goals[side] += int(attempt['is_scored'])
        if max(counts['home'], counts['away']) <= 3:
            ended = any(goals[s] > goals[o] + (3 - counts[o])
                        for s, o in (('home','away'),('away','home')))
        else:
            ended = counts['home'] == counts['away'] and goals['home'] != goals['away']
    if not ended:
        raise ValueError("Серия буллитов не завершена")
    actual_winner = 'home' if goals['home'] > goals['away'] else 'away'
    if actual_winner != winner:
        raise ValueError("Победитель серии не совпадает с официальным счётом")


def parse_shootouts(plays, people, side_by_team, winner):
    ordered = []
    ids, positions = set(), set()
    for play in plays:
        if not isinstance(play, dict):
            raise ValueError("Некорректное событие")
        descriptor = play.get('periodDescriptor') or {}
        if descriptor.get('periodType') != 'SO':
            continue
        kind = play.get('typeDescKey')
        details = play.get('details') or {}
        if kind not in ('goal','shot-on-goal','missed-shot'):
            if 'shootingPlayerId' in details or 'scoringPlayerId' in details:
                raise ValueError("Неизвестный тип попытки буллита")
            continue
        if descriptor.get('number') != 5:
            raise ValueError("Неожиданный номер периода серии буллитов")
        eid = integer(play.get('eventId'), 'shootout eventId')
        position = integer(play.get('sortOrder'), 'shootout sortOrder')
        if eid in ids or position in positions:
            raise ValueError("Повтор ID или порядка попытки буллита")
        ids.add(eid); positions.add(position)
        shooter = integer(details.get('scoringPlayerId' if kind == 'goal' else 'shootingPlayerId'), 'shooter', 1)
        team = integer(details.get('eventOwnerTeamId'), 'shootout team', 1)
        if team not in side_by_team or shooter not in people or people[shooter]['side'] != side_by_team[team]:
            raise ValueError("Исполнитель буллита не соответствует стороне")
        goalie = details.get('goalieInNetId')
        if goalie is not None:
            integer(goalie, 'goalie', 1)
            if goalie not in people or people[goalie]['side'] == people[shooter]['side']:
                raise ValueError("Вратарь буллита не представляет противоположную сторону")
        ordered.append((position, {'external_id':str(eid),'shooter':shooter,'goalie':goalie,
                                  'side':side_by_team[team],'is_scored':kind == 'goal'}))
    if winner is None:
        if ordered:
            raise ValueError("Буллиты найдены у матча с другим способом завершения")
        return []
    attempts = [row for _, row in sorted(ordered, key=lambda pair:pair[0])]
    validate_shootout_sequence(attempts, winner)
    for number, attempt in enumerate(attempts, 1):
        attempt['attempt_no'] = number
    return attempts


def parse_events(pbp, boxscore, game_id):
    match = parse_boxscore(pbp, game_id)
    box_match = parse_boxscore(boxscore, game_id)
    if match != box_match:
        for k in ("start_year", "game_type_code", "starts_at", "status", "finish_type"):
            if match[k] != box_match[k]:
                raise ValueError("Play-by-play и boxscore не согласованы")
    for side in ("home", "away"):
        if any(match["sides"][side][k] != box_match["sides"][side][k]
               for k in ("external_id", "score")):
            raise ValueError("Команды или счёт play-by-play и boxscore различаются")
    if match["status"] != "finished":
        raise ValueError("Пока поддерживаются только завершённые матчи")
    if pbp.get("limitedScoring") is not False or boxscore.get("limitedScoring") is not False:
        raise ValueError("Источник не подтверждает подробное покрытие")
    plays = pbp.get("plays")
    roster = pbp.get("rosterSpots")
    if not isinstance(plays, list) or not isinstance(roster, list):
        raise ValueError("Отсутствует plays или rosterSpots")
    side_by_team = {int(t["external_id"]): side for side, t in match["sides"].items()}
    people = {}
    for p in roster:
        pid = integer(p.get("playerId"), "roster playerId", 1)
        team_id = integer(p.get("teamId"), "roster teamId", 1)
        first = (p.get("firstName") or {}).get("default")
        last = (p.get("lastName") or {}).get("default")
        if pid in people or team_id not in side_by_team:
            raise ValueError("Некорректная принадлежность игрока в rosterSpots")
        if not isinstance(first, str) or not first.strip() or not isinstance(last, str) or not last.strip():
            raise ValueError("Отсутствует полное имя игрока в rosterSpots")
        jersey = p.get('sweaterNumber')
        if jersey is not None:
            integer(jersey, 'roster sweaterNumber')
            if jersey > 99:
                raise ValueError('Номер игрока вне диапазона 0–99')
        people[pid] = {"side": side_by_team[team_id], "name": f"{first.strip()} {last.strip()}",
                       "jersey_number": jersey}

    winner = None
    expected_goals = {side:match['sides'][side]['score'] for side in ('home','away')}
    if match['finish_type'] == 'shootout':
        if match['game_type_code'] != 'regular' or abs(expected_goals['home']-expected_goals['away']) != 1:
            raise ValueError('Некорректный официальный счёт матча с буллитами')
        winner = 'home' if expected_goals['home'] > expected_goals['away'] else 'away'
        expected_goals[winner] -= 1
        if expected_goals['home'] != expected_goals['away']:
            raise ValueError('Перед серией буллитов счёт должен быть равным')
    attempts = parse_shootouts(plays, people, side_by_team, winner)
    events, ids, side_goals = [], set(), Counter()
    scoring = {"goals": Counter(), "assists": Counter()}
    for play in plays:
        if not isinstance(play, dict):
            raise ValueError("Некорректное событие")
        if (play.get("periodDescriptor") or {}).get("periodType") == "SO":
            continue
        if play.get("typeDescKey") != "goal":
            continue
        eid = integer(play.get("eventId"), "eventId")
        if eid in ids:
            raise ValueError("Повтор ID гола")
        ids.add(eid)
        period = play.get("periodDescriptor") or {}
        ptype = period.get("periodType")
        number = integer(period.get("number"), "period number", 1)
        if ptype not in ("REG", "OT"):
            raise ValueError("Гол не относится к игровому времени")
        if (ptype == "REG" and number > 3) or (ptype == "OT" and number <= 3):
            raise ValueError("Номер периода не согласован с его типом")
        if match["game_type_code"] == "regular" and ptype == "OT" and number != 4:
            raise ValueError("Неожиданный номер овертайма регулярного матча")
        elapsed = event_seconds(play.get("timeInPeriod"))
        maximum = 300 if ptype == "OT" and match["game_type_code"] == "regular" else 1200
        if elapsed > maximum:
            raise ValueError("Время гола выходит за продолжительность периода")
        details = play.get("details") or {}
        scorer = integer(details.get("scoringPlayerId"), "scoringPlayerId", 1)
        team = integer(details.get("eventOwnerTeamId"), "eventOwnerTeamId", 1)
        if team not in side_by_team or scorer not in people or people[scorer]["side"] != side_by_team[team]:
            raise ValueError("Автор гола не соответствует стороне события")
        assistants = {}
        for order in (1, 2):
            pid = details.get(f"assist{order}PlayerId")
            if pid is None:
                continue
            integer(pid, "assistPlayerId", 1)
            if pid == scorer or pid in assistants.values():
                raise ValueError("Автор совпадает с ассистентом или ассистент повторяется")
            if pid not in people or people[pid]["side"] != people[scorer]["side"]:
                raise ValueError("Ассистент представляет другую сторону")
            assistants[order] = pid
            scoring["assists"][pid] += 1
        scoring["goals"][scorer] += 1
        side_goals[side_by_team[team]] += 1
        events.append({"external_id": str(eid), "scorer": scorer, "assists": assistants,
                       "side": side_by_team[team], "period_no": number, "elapsed_seconds": elapsed})
    if ids & {int(a['external_id']) for a in attempts}:
        raise ValueError('Один ID используется и для гола, и для буллита')
    if any(side_goals[s] != expected_goals[s] for s in ("home", "away")):
        raise ValueError("Число голов не совпадает со счётом матча")

    stats = boxscore.get("playerByGameStats") or {}
    box_counts = {"goals": Counter(), "assists": Counter()}
    listed = set()
    for side, key in (("home", "homeTeam"), ("away", "awayTeam")):
        groups = stats.get(key)
        if not isinstance(groups, dict):
            raise ValueError("Нет статистики игроков в boxscore")
        for group in ("forwards", "defense", "goalies"):
            rows = groups.get(group)
            if not isinstance(rows, list):
                raise ValueError("Неполная статистика игроков в boxscore")
            for player in rows:
                pid = integer(player.get("playerId"), "boxscore playerId", 1)
                if pid in listed:
                    raise ValueError("Игрок повторяется в статистике boxscore")
                listed.add(pid)
                for category in ("goals", "assists"):
                    count = player.get(category)
                    if count is None:
                        if group != "goalies":
                            raise ValueError("Отсутствуют голы/передачи полевого игрока")
                        count = 0
                    integer(count, category)
                    if count:
                        if pid not in people or people[pid]["side"] != side:
                            raise ValueError("Статистика игрока не согласована с составом")
                        box_counts[category][pid] = count
    if scoring != box_counts:
        raise ValueError("Голы/передачи игроков не совпадают с boxscore: обнови оба ответа")
    match["shootouts"] = attempts
    return match, events, people


def archived(connection, source_id, uri):
    raw = connection.execute(
        """SELECT r.raw_id, r.payload_uri, r.payload_hash, r.fetched_at
           FROM ingest.raw_snapshots AS r
           JOIN ingest.ingestion_runs AS ir ON ir.run_id = r.run_id
           WHERE r.source_id = %s AND r.request_uri = %s
             AND r.http_status = 200 AND ir.status = 'success'
           ORDER BY r.fetched_at DESC, r.raw_id DESC LIMIT 1""", (source_id, uri)
    ).fetchone()
    if raw is None:
        raise ValueError(f"Нет успешно сохранённого ответа: {uri}")
    path = (PROJECT_ROOT / raw["payload_uri"]).resolve()
    if not path.is_relative_to((PROJECT_ROOT / "data" / "raw").resolve()):
        raise ValueError("Исходный файл вне data/raw")
    body = path.read_bytes()
    if hashlib.sha256(body).hexdigest() != raw["payload_hash"]:
        raise ValueError("Хеш исходного файла не совпадает")
    return raw, json.loads(body)


def write_version(connection, schema, table, keys, values, raw_id, timestamp, deleted=False):
    condition = sql.SQL(" AND ").join(sql.SQL("{} = %s").format(sql.Identifier(k)) for k in keys)
    fields = list(values)
    current = connection.execute(
        sql.SQL("SELECT {} FROM {}.{} WHERE {} AND known_to = 'infinity'::timestamptz").format(
            sql.SQL(", ").join(map(sql.Identifier, fields + ["known_from", "is_deleted"])),
            sql.Identifier(schema), sql.Identifier(table), condition
        ), list(keys.values())
    ).fetchone()
    if current is None and deleted:
        return False
    if current and current["is_deleted"] == deleted and all(current[k] == v for k, v in values.items()):
        return False
    if current:
        if timestamp <= current["known_from"]:
            raise ValueError("Новая версия должна быть позже прежней")
        connection.execute(
            sql.SQL("UPDATE {}.{} SET known_to = %s WHERE {} AND known_to = 'infinity'::timestamptz").format(
                sql.Identifier(schema), sql.Identifier(table), condition
            ), [timestamp, *keys.values()]
        )
    insert_row(connection, schema, table, {**keys, **values, "known_from": timestamp,
                                         "raw_id": raw_id, "is_deleted": deleted})
    return True


def goal_identity(connection, source_id, game_id, external_id):
    row = connection.execute(
        "SELECT goal_id FROM ingest.goal_source_ids WHERE source_id = %s AND game_id = %s AND external_id = %s",
        (source_id, game_id, external_id)
    ).fetchone()
    if row:
        return row["goal_id"]
    goal_id = connection.execute("INSERT INTO core.goals DEFAULT VALUES RETURNING goal_id").fetchone()["goal_id"]
    insert_row(connection, "ingest", "goal_source_ids",
               {"source_id": source_id, "game_id": game_id, "external_id": external_id, "goal_id": goal_id})
    return goal_id


def tombstone_assist(connection, goal_id, order, raw_id, timestamp):
    current = connection.execute(
        """SELECT player_id FROM core.goal_assist_versions
           WHERE goal_id = %s AND assist_order = %s AND NOT is_deleted
             AND known_to = 'infinity'::timestamptz""", (goal_id, order)
    ).fetchone()
    if current:
        return write_version(connection, "core", "goal_assist_versions",
                             {"goal_id": goal_id, "assist_order": order},
                             {"player_id": current["player_id"]}, raw_id, timestamp, deleted=True)
    return False


def event_participant(connection, source_id, external_id, game_id, person, raw_id, timestamp):
    player_id, person_id = ensure_player(connection, source_id, str(external_id))
    ensure_name(connection, person_id, person['name'], raw_id, timestamp)
    current = connection.execute(
        """SELECT side, is_deleted FROM core.game_player_versions
           WHERE game_id=%s AND player_id=%s AND known_to='infinity'::timestamptz""",
        (game_id,player_id)).fetchone()
    if current:
        if current['is_deleted'] or current['side'] != person['side']:
            raise ValueError(f"Конфликт участия игрока NHL {external_id}")
    else:
        write_version(connection,'core','game_player_versions',
                      {'game_id':game_id,'player_id':player_id},
                      {'side':person['side'],'jersey_number':person['jersey_number']},raw_id,timestamp)
    return player_id


def sync_shootouts(connection, source_id, game_id, attempts, players, raw_id, timestamp):
    desired = {}
    fields = ('game_id','shooter_player_id','goalie_player_id','attempt_no','is_scored')
    for attempt in attempts:
        row = connection.execute(
            """SELECT attempt_id FROM ingest.shootout_attempt_source_ids
               WHERE source_id=%s AND game_id=%s AND external_id=%s""",
            (source_id,game_id,attempt['external_id'])).fetchone()
        if row:
            aid = row['attempt_id']
        else:
            aid = connection.execute('INSERT INTO core.shootout_attempts DEFAULT VALUES RETURNING attempt_id').fetchone()['attempt_id']
            insert_row(connection,'ingest','shootout_attempt_source_ids',
                       {'source_id':source_id,'game_id':game_id,'external_id':attempt['external_id'],'attempt_id':aid})
        desired[aid] = {'game_id':game_id,'shooter_player_id':players[attempt['shooter']],
                        'goalie_player_id':players[attempt['goalie']] if attempt['goalie'] is not None else None,
                        'attempt_no':attempt['attempt_no'],'is_scored':attempt['is_scored']}
    old = connection.execute(
        """SELECT a.attempt_id,a.game_id,a.shooter_player_id,a.goalie_player_id,a.attempt_no,a.is_scored
           FROM core.shootout_attempt_versions AS a
           JOIN ingest.shootout_attempt_source_ids AS m ON m.attempt_id=a.attempt_id
           WHERE m.source_id=%s AND m.game_id=%s AND a.game_id=%s
             AND a.known_to='infinity'::timestamptz AND NOT a.is_deleted""",
        (source_id,game_id,game_id)).fetchall()
    changes = 0
    for row in old:
        aid = row['attempt_id']
        if desired.get(aid) == {k:row[k] for k in fields}:
            continue
        connection.execute(
            """UPDATE core.shootout_attempt_versions SET known_to=%s
               WHERE attempt_id=%s AND known_to='infinity'::timestamptz""", (timestamp,aid))
        changes += 1
        if aid not in desired:
            insert_row(connection,'core','shootout_attempt_versions',
                       {'attempt_id':aid,**{k:row[k] for k in fields},'known_from':timestamp,
                        'raw_id':raw_id,'is_deleted':True})
    for aid, values in desired.items():
        changes += int(write_version(connection,'core','shootout_attempt_versions',
                                     {'attempt_id':aid},values,raw_id,timestamp))
    return changes


def import_events(game_id):
    load_dotenv(PROJECT_ROOT / ".env")
    password = os.getenv("POSTGRES_PASSWORD")
    if not password:
        raise ValueError("В .env не указан POSTGRES_PASSWORD")
    uri = f"{BASE_URL}/gamecenter/{game_id}/play-by-play"
    with psycopg.connect(host=os.getenv("POSTGRES_HOST", "127.0.0.1"),
                        port=int(os.getenv("POSTGRES_PORT", "5433")),
                        dbname=os.getenv("POSTGRES_DB", "nhl"), user=os.getenv("POSTGRES_USER", "nhl"),
                        password=password, autocommit=True, connect_timeout=5, row_factory=dict_row,
                        application_name="nhl_events_import") as connection:
        run_id = insert_row(connection, "ingest", "ingestion_runs", {"loader_version": "events-import-v2"}, "run_id")
        raw_id = None
        try:
            with connection.transaction():
                connection.execute("SELECT pg_advisory_xact_lock(17001, 1)")
                source = connection.execute("SELECT source_id FROM ingest.data_sources WHERE source_code = 'nhl_gamecenter'").fetchone()
                if source is None:
                    raise ValueError("Сначала запусти fetch_game.py и import_game.py")
                source_id = source["source_id"]
                raw, pbp = archived(connection, source_id, uri)
                raw_id = raw["raw_id"]
                box_raw, boxscore = archived(connection, source_id, uri.replace('/play-by-play','/boxscore'))
                match, events, people = parse_events(pbp, boxscore, game_id)
                game = connection.execute(
                    """SELECT g.game_id, g.game_type_code, g.starts_at, g.status, g.finish_type, s.start_year
                       FROM ingest.game_source_ids AS m
                       JOIN core.v_current_games AS g ON g.game_id = m.game_id
                       JOIN core.seasons AS s ON s.season_id = g.season_id
                       WHERE m.source_id = %s AND m.external_id = %s""", (source_id, str(game_id))
                ).fetchone()
                if game is None or any(game[k] != match[k] for k in
                        ('game_type_code','starts_at','status','finish_type','start_year')):
                    raise ValueError("Сначала импортируй актуальные характеристики матча через import_game.py")
                internal_id = game['game_id']
                for side in ('home','away'):
                    rows = connection.execute(
                        """SELECT m.external_id, t.official_score FROM core.v_current_game_teams AS t
                           JOIN ingest.team_source_ids AS m ON m.team_id = t.team_id
                           WHERE t.game_id = %s AND t.side = %s AND m.source_id = %s""",
                        (internal_id, side, source_id)
                    ).fetchall()
                    if not any(r['external_id'] == match['sides'][side]['external_id']
                               and r['official_score'] == match['sides'][side]['score'] for r in rows):
                        raise ValueError("Команды/счёт в БД устарели: выполни import_game.py")
                latest = connection.execute(
                    """SELECT max(r.fetched_at) AS t FROM ingest.raw_snapshots AS r JOIN (
                           SELECT raw_id FROM core.goal_versions WHERE game_id = %s AND known_to = 'infinity'::timestamptz
                           UNION SELECT raw_id FROM core.shootout_attempt_versions
                           WHERE game_id = %s AND known_to = 'infinity'::timestamptz
                           UNION SELECT a.raw_id FROM core.goal_assist_versions AS a
                           JOIN ingest.goal_source_ids AS m ON m.goal_id = a.goal_id
                           WHERE m.game_id = %s AND a.known_to = 'infinity'::timestamptz
                           UNION SELECT raw_id FROM ingest.game_coverage_versions
                           WHERE game_id = %s AND dataset_code = 'events' AND known_to = 'infinity'::timestamptz
                       ) AS used ON used.raw_id = r.raw_id""", (internal_id,internal_id,internal_id,internal_id)
                ).fetchone()['t']
                if latest is not None and latest > raw['fetched_at']:
                    raise ValueError("Нельзя перезаписать события более старым ответом")
                timestamp = connection.execute('SELECT clock_timestamp() AS t').fetchone()['t']
                involved = {e['scorer'] for e in events} | {p for e in events for p in e['assists'].values()}
                involved |= {a['shooter'] for a in match['shootouts']}
                involved |= {a['goalie'] for a in match['shootouts'] if a['goalie'] is not None}
                players = {}
                for external_player in involved:
                    players[external_player] = event_participant(
                        connection,source_id,external_player,internal_id,people[external_player],raw_id,timestamp)
                changes = 0
                present = set()
                for event in events:
                    gid = goal_identity(connection,source_id,internal_id,event['external_id'])
                    present.add(gid)
                    changes += int(write_version(connection,'core','goal_versions',{'goal_id':gid},
                        {'game_id':internal_id,'scorer_player_id':players[event['scorer']],
                         'period_no':event['period_no'],'elapsed_seconds':event['elapsed_seconds']},raw_id,timestamp))
                    desired = {order:players[pid] for order,pid in event['assists'].items()}
                    old = connection.execute(
                        """SELECT assist_order, player_id FROM core.goal_assist_versions
                           WHERE goal_id = %s AND known_to = 'infinity'::timestamptz AND NOT is_deleted""",(gid,)
                    ).fetchall()
                    for row in old:
                        if desired.get(row['assist_order']) != row['player_id']:
                            connection.execute(
                                """UPDATE core.goal_assist_versions SET known_to = %s
                                   WHERE goal_id = %s AND assist_order = %s AND known_to = 'infinity'::timestamptz""",
                                (timestamp,gid,row['assist_order']))
                            if row['assist_order'] not in desired:
                                insert_row(connection,'core','goal_assist_versions',{
                                    'goal_id':gid,'assist_order':row['assist_order'],'player_id':row['player_id'],
                                    'known_from':timestamp,'raw_id':raw_id,'is_deleted':True})
                            changes += 1
                    for order,pid in desired.items():
                        changes += int(write_version(connection,'core','goal_assist_versions',
                            {'goal_id':gid,'assist_order':order},{'player_id':pid},raw_id,timestamp))
                old_goals = connection.execute(
                    """SELECT DISTINCT g.goal_id, g.game_id, g.scorer_player_id, g.period_no, g.elapsed_seconds
                       FROM core.goal_versions AS g JOIN ingest.goal_source_ids AS m ON m.goal_id = g.goal_id
                       WHERE m.source_id = %s AND m.game_id = %s AND g.game_id = %s
                         AND g.known_to = 'infinity'::timestamptz AND NOT g.is_deleted""",
                    (source_id,internal_id,internal_id)).fetchall()
                for old in old_goals:
                    if old['goal_id'] in present:
                        continue
                    for order in (1,2):
                        changes += int(tombstone_assist(connection,old['goal_id'],order,raw_id,timestamp))
                    changes += int(write_version(connection,'core','goal_versions',{'goal_id':old['goal_id']},
                        {k:old[k] for k in ('game_id','scorer_player_id','period_no','elapsed_seconds')},
                        raw_id,timestamp,deleted=True))
                changes += sync_shootouts(connection,source_id,internal_id,match['shootouts'],players,raw_id,timestamp)
                write_version(connection,'ingest','game_coverage_versions',
                              {'game_id':internal_id,'dataset_code':'events'},
                              {'coverage_status':'complete'},raw_id,timestamp)
                connection.execute(
                    """INSERT INTO ingest.ingestion_checkpoints (source_id,stream_code,partition_key,cursor_value)
                       VALUES (%s,'goals_import',%s,%s) ON CONFLICT (source_id,stream_code,partition_key)
                       DO UPDATE SET cursor_value=EXCLUDED.cursor_value,updated_at=clock_timestamp()""",
                    (source_id,str(game_id),str(raw_id)))
                connection.execute("UPDATE ingest.ingestion_runs SET status='success', finished_at=clock_timestamp() WHERE run_id=%s",(run_id,))
            print(f"Импорт событий завершён: game_id={internal_id}, NHL game_id={game_id}")
            print(f"Голов: {len(events)}; передач: {sum(len(e['assists']) for e in events)}")
            print(f"Попыток буллитов: {len(match['shootouts'])}")
            print(f"Изменений истории событий: {changes}")
            print(f"run_id={run_id}, raw_id={raw_id}, boxscore_raw_id={box_raw['raw_id']}")
        except BaseException as error:
            try:
                with connection.transaction():
                    insert_row(connection,'ingest','ingestion_issues',{'run_id':run_id,'raw_id':None,
                        'error_code':type(error).__name__,'description':f"input raw_id={raw_id}: {str(error) or type(error).__name__}",
                        'request_uri':uri})
                    connection.execute("UPDATE ingest.ingestion_runs SET status='failed', finished_at=clock_timestamp() WHERE run_id=%s",(run_id,))
            except Exception:
                print('Не удалось записать ошибку в БД; смотри исходную ошибку ниже.')
            raise


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description='Импорт голов, передач и буллитов из play-by-play')
    parser.add_argument('game_id',type=int)
    args=parser.parse_args()
    if args.game_id<=0:parser.error('game_id должен быть положительным')
    import_events(args.game_id)
