"""Load completed regular-season/playoff games using the existing five stages.

Progress: data/jobs/season_<season>.json. A success is skipped only if its
receipt still agrees with DB checkpoints, coverage and archived input files.
"""
import argparse
import hashlib
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from psycopg.rows import dict_row
import requests
from dotenv import load_dotenv

from fetch_game import BASE_URL, PROJECT_ROOT, fetch_game, fetch_response
from fetch_events import fetch_events
from import_game import import_game
from import_players import import_players
from import_events import import_events

STATS_URL = 'https://api.nhle.com/stats/rest/en'
STAGES = [('fetch_game', fetch_game), ('import_game', import_game),
          ('import_players', import_players), ('fetch_events', fetch_events),
          ('import_events', import_events)]
PAGE_SIZE = 200


def season_code(value):
    text = str(value)
    if len(text) != 8 or not text.isdigit():
        raise ValueError('Сезон должен иметь вид 20232024')
    start, end = int(text[:4]), int(text[4:])
    if not 2000 <= start <= 9998 or end != start + 1:
        raise ValueError('Нужны соседние годы, начиная с сезона 2000/01')
    return int(text)


def validate_page(payload, season):
    if not isinstance(payload, dict) or type(payload.get('total')) is not int:
        raise ValueError('Список матчей не содержит целое total')
    rows = payload.get('data')
    if payload['total'] < 0 or not isinstance(rows, list):
        raise ValueError('Некорректный список матчей')
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError('Матч должен быть объектом')
        for key in ('id', 'season', 'gameType', 'gameStateId'):
            if type(row.get(key)) is not int:
                raise ValueError(f'Некорректное поле списка матчей: {key}')
        if row['season'] != season or row['id'] <= 0:
            raise ValueError('Получен матч другого сезона или неверный ID')
    return rows, payload['total']


def read_manifest(get_page, season):
    rows, seen, expected = [], set(), None
    while expected is None or len(rows) < expected:
        page, total = validate_page(get_page(len(rows)), season)
        if expected is not None and total != expected:
            raise ValueError('Число матчей изменилось между страницами; повтори запуск')
        expected = total
        if not page and len(rows) < total:
            raise ValueError('Получена пустая страница до конца списка матчей')
        for row in page:
            if row['id'] in seen:
                raise ValueError('Повтор ID между страницами списка матчей')
            seen.add(row['id'])
            rows.append(row)
        if len(rows) > expected:
            raise ValueError('Размер списка превышает total')
    return sorted(rows, key=lambda row: row['id'])


def select_games(rows, game_type):
    types = {'regular': {2}, 'playoff': {3}, 'both': {2, 3}}[game_type]
    selected = [row for row in rows if row['gameType'] in types]
    finished = [row['id'] for row in selected if row['gameStateId'] in (6, 7)]
    return finished, len(selected) - len(finished)


def atomic_write(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def read_state(path, season):
    if not path.exists():
        return {'format_version': 1, 'season': season, 'games': {}}
    state = json.loads(path.read_text(encoding='utf-8'))
    if (not isinstance(state, dict) or state.get('format_version') != 1
            or state.get('season') != season or not isinstance(state.get('games'), dict)):
        raise ValueError('Некорректный файл прогресса: проверь его перед продолжением')
    if any(not isinstance(value, dict) for value in state['games'].values()):
        raise ValueError('Некорректные записи в файле прогресса')
    return state


def save_state(path, state):
    atomic_write(path, (json.dumps(state, ensure_ascii=False, indent=2) + '\n').encode())


def valid_raw(raw, root):
    if not raw:
        return False
    path = (root / raw['payload_uri']).resolve()
    if not path.is_relative_to((root / 'data' / 'raw').resolve()):
        return False
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest() == raw['payload_hash']
    except OSError:
        return False


def receipt(connection, game_id, root=PROJECT_ROOT):
    raws = []
    for endpoint in ('boxscore', 'play-by-play'):
        raw = connection.execute(
            """SELECT r.raw_id, r.source_id, r.payload_uri, r.payload_hash
               FROM ingest.raw_snapshots r
               JOIN ingest.data_sources s USING (source_id)
               JOIN ingest.ingestion_runs ir ON ir.run_id = r.run_id
               WHERE s.source_code = 'nhl_gamecenter' AND r.request_uri = %s
                 AND r.http_status = 200 AND ir.status = 'success'
               ORDER BY r.fetched_at DESC, r.raw_id DESC LIMIT 1""",
            (f'{BASE_URL}/gamecenter/{game_id}/{endpoint}',)).fetchone()
        if not valid_raw(raw, root):
            return None
        raws.append(raw)
    box, events = raws
    checkpoints = connection.execute(
        """SELECT stream_code, cursor_value FROM ingest.ingestion_checkpoints
           WHERE source_id = %s AND partition_key = %s
             AND stream_code IN ('boxscore_import', 'boxscore_players', 'goals_import')""",
        (box['source_id'], str(game_id))).fetchall()
    actual = {row['stream_code']: row['cursor_value'] for row in checkpoints}
    expected = {'boxscore_import': str(box['raw_id']),
                'boxscore_players': str(box['raw_id']), 'goals_import': str(events['raw_id'])}
    if actual != expected:
        return None
    good = connection.execute(
        """SELECT EXISTS (
               SELECT 1 FROM ingest.game_source_ids m
               JOIN core.game_versions g ON g.game_id = m.game_id
               WHERE m.source_id = %s AND m.external_id = %s
                 AND g.known_to = 'infinity'::timestamptz AND NOT g.is_deleted
                 AND g.status = 'finished'
                 AND (SELECT count(*) FROM ingest.game_coverage_versions c
                      WHERE c.game_id = m.game_id
                        AND c.dataset_code IN ('results', 'events')
                        AND c.known_to = 'infinity'::timestamptz
                        AND NOT c.is_deleted AND c.coverage_status = 'complete') = 2
           ) AS good""", (box['source_id'], str(game_id))).fetchone()['good']
    return {'boxscore_raw_id': box['raw_id'], 'events_raw_id': events['raw_id']} if good else None


def run_games(game_ids, state, limit, refresh, verify, run_stage, persist, issue,
              stages=STAGES):
    counts = {'success': 0, 'failed': 0, 'skipped': 0}
    for game_id in game_ids:
        key = str(game_id)
        old = state['games'].get(key, {})
        if not refresh and old.get('status') == 'success':
            proof = verify(game_id)
            if proof is not None and proof == old.get('receipt'):
                counts['skipped'] += 1
                continue
        if limit is not None and counts['success'] + counts['failed'] >= limit:
            break
        entry = {'status': 'running', 'stage': 'start',
                 'updated_at': datetime.now(timezone.utc).isoformat()}
        state['games'][key] = entry
        persist()
        print(f'\n=== NHL game_id={game_id} ===', flush=True)
        try:
            for name, function in stages:
                entry['stage'] = name
                persist()
                run_stage(name, function, game_id)
            proof = verify(game_id)
            if proof is None:
                raise ValueError('Контрольные точки или покрытие матча не подтверждены')
        except Exception as error:
            entry.update(status='failed', error=f'{type(error).__name__}: {error}')
            counts['failed'] += 1
            persist()
            issue(game_id, entry['stage'], error)
            print(f"Ошибка game_id={game_id}, этап {entry['stage']}: {error}", file=sys.stderr)
        else:
            entry.update(status='success', receipt=proof, stage='done')
            counts['success'] += 1
            persist()
    return counts


def fetch_manifest(connection, run_id, season, pause):
    connection.execute(
        "INSERT INTO ingest.data_sources (source_code, base_uri) VALUES ('nhl_stats', %s) "
        "ON CONFLICT (source_code) DO NOTHING", (STATS_URL,))
    source_id = connection.execute(
        "SELECT source_id FROM ingest.data_sources WHERE source_code = 'nhl_stats'"
    ).fetchone()['source_id']
    with requests.Session() as session:
        session.headers.update({'User-Agent': 'nhl-analytics/0.1'})

        def get_page(start):
            url = requests.Request('GET', f'{STATS_URL}/game', params={
                'cayenneExp': f'season={season}', 'start': start, 'limit': PAGE_SIZE,
                'sort': json.dumps([{'property': 'id', 'direction': 'ASC'}]),
            }).prepare().url
            time.sleep(pause)
            with fetch_response(session, url) as response:
                body = response.content
                digest = hashlib.sha256(body).hexdigest()
                path = PROJECT_ROOT / 'data' / 'raw' / 'nhl_stats' / f'{digest}.body'
                if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                    raise OSError('Повреждён архив списка матчей')
                if not path.exists():
                    atomic_write(path, body)
                connection.execute(
                    """INSERT INTO ingest.raw_snapshots (source_id, run_id, request_uri,
                           fetched_at, http_status, payload_hash, payload_uri)
                       VALUES (%s, %s, %s, %s, %s, %s, %s)""",
                    (source_id, run_id, url, datetime.now(timezone.utc), response.status_code,
                     digest, path.relative_to(PROJECT_ROOT).as_posix()))
                response.raise_for_status()
                return json.loads(body)
        return read_manifest(get_page, season)


def main():
    parser = argparse.ArgumentParser(description='Последовательная загрузка завершённых матчей сезона')
    parser.add_argument('season', type=season_code, help='Например, 20232024')
    size = parser.add_mutually_exclusive_group()
    size.add_argument('--limit', type=int, help='Число матчей за запуск; по умолчанию 3')
    size.add_argument('--all', action='store_true', help='Обработать все оставшиеся матчи')
    parser.add_argument('--refresh', action='store_true', help='Повторно получить уже загруженные матчи')
    parser.add_argument('--game-type', choices=['regular', 'playoff', 'both'], default='both')
    parser.add_argument('--pause', type=float, default=1, help='Пауза перед сетевым этапом, секунд')
    args = parser.parse_args()
    if (args.limit is not None and args.limit < 1) or not 0 <= args.pause <= 60:
        parser.error('--limit должен быть положительным; --pause должен быть от 0 до 60')
    limit = None if args.all else (args.limit if args.limit is not None else 3)
    state_path = PROJECT_ROOT / 'data' / 'jobs' / f'season_{args.season}.json'
    load_dotenv(PROJECT_ROOT / '.env')
    password = os.getenv('POSTGRES_PASSWORD')
    if not password:
        raise ValueError('В .env не указан POSTGRES_PASSWORD')
    with psycopg.connect(host=os.getenv('POSTGRES_HOST', '127.0.0.1'),
                         port=int(os.getenv('POSTGRES_PORT', '5433')),
                         dbname=os.getenv('POSTGRES_DB', 'nhl'), user=os.getenv('POSTGRES_USER', 'nhl'),
                         password=password, connect_timeout=5, autocommit=True,
                         row_factory=dict_row, application_name='nhl_season_loader') as connection:
        if not connection.execute('SELECT pg_try_advisory_lock(17003, 1) AS locked').fetchone()['locked']:
            raise RuntimeError('Другой пакетный загрузчик уже работает')
        state = read_state(state_path, args.season)
        run_id = connection.execute(
            "INSERT INTO ingest.ingestion_runs (loader_version) VALUES ('season-pipeline-v1') "
            "RETURNING run_id").fetchone()['run_id']

        def issue(game_id, stage, error):
            connection.execute(
                """INSERT INTO ingest.ingestion_issues (run_id, error_code, description)
                   VALUES (%s, %s, %s)""",
                (run_id, type(error).__name__[:100], f'game_id={game_id}; stage={stage}; {error}'))

        def run_stage(name, function, game_id):
            if name.startswith('fetch_'):
                time.sleep(args.pause)
            function(game_id)

        def finish(status):
            connection.execute(
                'UPDATE ingest.ingestion_runs SET status = %s, finished_at = clock_timestamp() '
                'WHERE run_id = %s', (status, run_id))

        try:
            rows = fetch_manifest(connection, run_id, args.season, args.pause)
            game_ids, unfinished = select_games(rows, args.game_type)
            print(f'Завершённых матчей в выбранной части сезона: {len(game_ids)}; '
                  f'не завершены: {unfinished}', flush=True)
            counts = run_games(game_ids, state, limit, args.refresh,
                               lambda game: receipt(connection, game), run_stage,
                               lambda: save_state(state_path, state), issue)
            finish('partial' if counts['failed'] and counts['success'] else
                   'failed' if counts['failed'] else 'success')
        except BaseException as error:
            try:
                issue(None, 'season', error)
                finish('failed')
            except Exception:
                print('Не удалось записать ошибку пакетной загрузки в БД', file=sys.stderr)
            raise
        good = sum(state['games'].get(str(game), {}).get('status') == 'success' for game in game_ids)
        print(f"\nЗа запуск: успешно {counts['success']}; ошибок {counts['failed']}; "
              f"проверено и пропущено {counts['skipped']}")
        print(f'Успешные записи в журнале сезона: {good}/{len(game_ids)}; '
              f'ещё не отмечены успешными: {len(game_ids) - good}')
        print(f'Прогресс: {state_path.relative_to(PROJECT_ROOT)}; run_id={run_id}')
        return 1 if counts['failed'] else 0


if __name__ == '__main__':
    sys.exit(main())
