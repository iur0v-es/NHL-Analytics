BEGIN;

DO $$
DECLARE
    v_name TEXT;
    v_relation REGCLASS;
BEGIN
    FOREACH v_name IN ARRAY ARRAY[
        'core.seasons','core.teams','core.team_seasons','core.arenas',
        'core.persons','core.players','core.coaches','core.coach_roles',
        'core.person_versions','core.team_names','core.arena_names',
        'core.team_name_versions','core.arena_name_versions',
        'core.coach_assignments','core.coach_assignment_versions',
        'core.games','core.game_versions','core.game_team_versions',
        'core.roster_snapshots','core.roster_snapshot_players',
        'core.game_player_versions','core.goals','core.goal_versions',
        'core.goal_assist_versions','core.shootout_attempts',
        'core.shootout_attempt_versions','core.game_coach_versions',
        'ingest.data_sources','ingest.ingestion_runs','ingest.raw_snapshots',
        'ingest.team_source_ids','ingest.player_source_ids',
        'ingest.coach_source_ids','ingest.game_source_ids',
        'ingest.arena_source_ids','ingest.goal_source_ids',
        'ingest.shootout_attempt_source_ids','ingest.ingestion_issues',
        'ingest.ingestion_checkpoints','ingest.game_coverage_versions'
    ] LOOP
        v_relation := to_regclass(v_name);
        IF v_relation IS NULL OR NOT EXISTS (
            SELECT 1 FROM pg_class WHERE oid = v_relation AND relkind = 'r'
        ) THEN
            RAISE EXCEPTION 'FAIL: отсутствует таблица %', v_name;
        END IF;
    END LOOP;

    FOREACH v_name IN ARRAY ARRAY[
        'core.v_current_persons','core.v_current_team_names',
        'core.v_current_games','core.v_current_game_teams',
        'core.v_current_game_players','core.v_current_goals',
        'core.v_current_goal_assists','core.v_current_game_coaches',
        'ingest.v_current_game_coverage','core.v_game_results',
        'core.v_goals_enriched','core.v_player_season_scoring',
        'core.v_player_latest_roster_observations','core.v_head_coaches_by_game'
    ] LOOP
        v_relation := to_regclass(v_name);
        IF v_relation IS NULL OR NOT EXISTS (
            SELECT 1 FROM pg_class WHERE oid = v_relation AND relkind = 'v'
        ) THEN
            RAISE EXCEPTION 'FAIL: отсутствует представление %', v_name;
        END IF;
    END LOOP;

    FOREACH v_name IN ARRAY ARRAY[
        'check_game_versions','check_game_team_versions','check_team_seasons',
        'check_game_player_versions','check_side_players',
        'check_goal_links','check_assist_links','check_shootout_links',
        'check_player_event_links','check_game_event_links',
        'check_game_coach_versions','check_side_coaches'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_trigger AS t
            JOIN pg_class AS c ON c.oid = t.tgrelid
            JOIN pg_namespace AS n ON n.oid = c.relnamespace
            WHERE n.nspname = 'core' AND t.tgname = v_name
              AND t.tgdeferrable AND t.tginitdeferred
              AND t.tgenabled IN ('O', 'A')
        ) THEN
            RAISE EXCEPTION 'FAIL: отсутствует или отключён отложенный триггер %', v_name;
        END IF;
    END LOOP;

    RAISE NOTICE 'OK: найдены 40 таблиц, 14 представлений и 12 отложенных триггеров';
END;
$$;

DO $$
DECLARE
    v_source BIGINT;
    v_run BIGINT;
    v_raw_ids BIGINT[] := ARRAY[]::BIGINT[];
    v_raw BIGINT;
    v_home BIGINT;
    v_away BIGINT;
    v_season BIGINT;
    v_game BIGINT;
    v_person BIGINT;
    v_players BIGINT[] := ARRAY[]::BIGINT[];
    v_player BIGINT;
    v_coach BIGINT;
    v_name_record BIGINT;
    v_goal BIGINT;
    v_snapshot BIGINT;
    v_latest_snapshot BIGINT;
    v_n INTEGER;
    v_result RECORD;
    v_t0 TIMESTAMPTZ := '2026-01-01 00:00:00+00';
    v_t1 TIMESTAMPTZ := '2026-01-02 00:00:00+00';
BEGIN
    INSERT INTO ingest.data_sources (source_code, base_uri)
    VALUES ('views_test_' || txid_current(), 'https://example.invalid')
    RETURNING source_id INTO v_source;

    INSERT INTO ingest.ingestion_runs (loader_version)
    VALUES ('views-test') RETURNING run_id INTO v_run;

    FOR v_n IN 1..3 LOOP
        INSERT INTO ingest.raw_snapshots (
            source_id, run_id, request_uri, http_status, payload_hash, payload_uri
        ) VALUES (
            v_source, v_run, 'https://example.invalid/' || v_n,
            200, repeat('0', 64), 'test://views/' || v_n || '.json'
        ) RETURNING raw_id INTO v_raw;
        v_raw_ids := array_append(v_raw_ids, v_raw);
    END LOOP;

    INSERT INTO core.seasons (start_year, status) VALUES (2018, 'completed')
    ON CONFLICT (start_year) DO NOTHING;
    SELECT season_id INTO STRICT v_season FROM core.seasons WHERE start_year = 2018;

    INSERT INTO core.teams DEFAULT VALUES RETURNING team_id INTO v_home;
    INSERT INTO core.teams DEFAULT VALUES RETURNING team_id INTO v_away;
    INSERT INTO core.team_seasons (team_id, season_id)
    VALUES (v_home, v_season), (v_away, v_season);

    INSERT INTO core.team_names DEFAULT VALUES RETURNING team_name_id INTO v_name_record;
    INSERT INTO core.team_name_versions (
        team_name_id, team_id, name, valid_from, valid_to, known_from, raw_id
    ) VALUES (
        v_name_record, v_home, 'Old Home', '2000-01-01', '2020-01-01', v_t0, v_raw_ids[1]
    );

    INSERT INTO core.team_names DEFAULT VALUES RETURNING team_name_id INTO v_name_record;
    INSERT INTO core.team_name_versions (
        team_name_id, team_id, name, valid_from, valid_to, known_from, raw_id
    ) VALUES (
        v_name_record, v_home, 'New Home', '2020-01-01', 'infinity', v_t0, v_raw_ids[1]
    );

    INSERT INTO core.team_names DEFAULT VALUES RETURNING team_name_id INTO v_name_record;
    INSERT INTO core.team_name_versions (
        team_name_id, team_id, name, valid_from, valid_to, known_from, raw_id
    ) VALUES (
        v_name_record, v_away, 'Away Team', '2000-01-01', 'infinity', v_t0, v_raw_ids[1]
    );

    INSERT INTO core.games DEFAULT VALUES RETURNING game_id INTO v_game;
    INSERT INTO core.game_versions (
        game_id, season_id, game_type_code, starts_at,
        status, finish_type, known_from, raw_id
    ) VALUES (
        v_game, v_season, 'regular', '2019-01-10 18:00:00+00',
        'finished', 'regulation', v_t0, v_raw_ids[1]
    );
    INSERT INTO core.game_team_versions (
        game_id, team_id, side, official_score, known_from, raw_id
    ) VALUES
        (v_game, v_home, 'home', 1, v_t0, v_raw_ids[1]),
        (v_game, v_away, 'away', 0, v_t0, v_raw_ids[1]);

    FOR v_n IN 1..4 LOOP
        INSERT INTO core.persons DEFAULT VALUES RETURNING person_id INTO v_person;
        INSERT INTO core.person_versions (person_id, name, known_from, raw_id)
        VALUES (v_person, 'Player ' || v_n, v_t0, v_raw_ids[1]);
        INSERT INTO core.players (person_id) VALUES (v_person)
        RETURNING player_id INTO v_player;
        v_players := array_append(v_players, v_player);
        INSERT INTO core.game_player_versions (
            game_id, player_id, side, known_from, raw_id
        ) VALUES (
            v_game, v_player, CASE WHEN v_n <= 3 THEN 'home' ELSE 'away' END,
            v_t0, v_raw_ids[1]
        );
    END LOOP;

    INSERT INTO core.persons DEFAULT VALUES RETURNING person_id INTO v_person;
    INSERT INTO core.person_versions (person_id, name, known_from, raw_id)
    VALUES (v_person, 'Test Coach', v_t0, v_raw_ids[1]);
    INSERT INTO core.coaches (person_id) VALUES (v_person)
    RETURNING coach_id INTO v_coach;
    INSERT INTO core.game_coach_versions (
        game_id, coach_id, role_code, side, known_from, raw_id
    ) VALUES (v_game, v_coach, 'head', 'home', v_t0, v_raw_ids[1]);

    INSERT INTO core.goals DEFAULT VALUES RETURNING goal_id INTO v_goal;
    INSERT INTO core.goal_versions (
        goal_id, game_id, scorer_player_id, period_no, elapsed_seconds, known_from, raw_id
    ) VALUES (v_goal, v_game, v_players[1], 1, 60, v_t0, v_raw_ids[1]);
    INSERT INTO core.goal_assist_versions (
        goal_id, player_id, assist_order, known_from, raw_id
    ) VALUES
        (v_goal, v_players[2], 1, v_t0, v_raw_ids[1]),
        (v_goal, v_players[3], 2, v_t0, v_raw_ids[1]);

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    SELECT * INTO STRICT v_result FROM core.v_game_results WHERE game_id = v_game;
    IF v_result.home_score IS DISTINCT FROM 1
       OR v_result.away_score IS DISTINCT FROM 0
       OR v_result.winner_team_id IS DISTINCT FROM v_home
       OR v_result.home_team_name IS DISTINCT FROM 'Old Home'
       OR v_result.away_team_name IS DISTINCT FROM 'Away Team'
       OR v_result.event_coverage IS DISTINCT FROM 'unknown' THEN
        RAISE EXCEPTION 'FAIL: результат, историческое название или неизвестное покрытие неверны';
    END IF;
    RAISE NOTICE 'OK: результат матча и название на дату матча верны';

    SELECT * INTO STRICT v_result FROM core.v_goals_enriched WHERE goal_id = v_goal;
    IF v_result.scorer_name IS DISTINCT FROM 'Player 1'
       OR v_result.team_id IS DISTINCT FROM v_home
       OR v_result.team_name IS DISTINCT FROM 'Old Home' THEN
        RAISE EXCEPTION 'FAIL: неверные сведения об авторе гола';
    END IF;
    RAISE NOTICE 'OK: гол с двумя передачами представлен одной строкой';

    INSERT INTO ingest.game_coverage_versions (
        game_id, dataset_code, coverage_status, known_from, raw_id
    ) VALUES (v_game, 'events', 'partial', v_t0, v_raw_ids[1]);

    SELECT * INTO STRICT v_result FROM core.v_player_season_scoring
    WHERE season_id = v_season AND team_id = v_home
      AND game_type_code = 'regular' AND player_id = v_players[1];
    IF v_result.observed_goals IS DISTINCT FROM 1
       OR v_result.goals IS NOT NULL OR v_result.assists IS NOT NULL
       OR v_result.points IS NOT NULL
       OR v_result.games_with_complete_events IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FAIL: неполные события ошибочно выданы за полную статистику';
    END IF;
    RAISE NOTICE 'OK: при неполных событиях итоговая статистика остаётся NULL';

    UPDATE ingest.game_coverage_versions SET known_to = v_t1
    WHERE game_id = v_game AND dataset_code = 'events';
    INSERT INTO ingest.game_coverage_versions (
        game_id, dataset_code, coverage_status, known_from, raw_id
    ) VALUES (v_game, 'events', 'complete', v_t1, v_raw_ids[2]);

    FOR v_n IN 1..4 LOOP
        SELECT * INTO STRICT v_result FROM core.v_player_season_scoring
        WHERE season_id = v_season AND game_type_code = 'regular'
          AND team_id = CASE WHEN v_n <= 3 THEN v_home ELSE v_away END
          AND player_id = v_players[v_n];
        IF v_result.games_played IS DISTINCT FROM 1
           OR v_result.games_with_complete_events IS DISTINCT FROM 1
           OR v_result.goals IS DISTINCT FROM (CASE WHEN v_n = 1 THEN 1 ELSE 0 END)
           OR v_result.assists IS DISTINCT FROM (CASE WHEN v_n IN (2,3) THEN 1 ELSE 0 END)
           OR v_result.points IS DISTINCT FROM (CASE WHEN v_n <= 3 THEN 1 ELSE 0 END) THEN
            RAISE EXCEPTION 'FAIL: неверная статистика игрока %', v_n;
        END IF;
    END LOOP;
    RAISE NOTICE 'OK: голы и передачи посчитаны без умножения строк, нули подтверждены покрытием';

    INSERT INTO core.roster_snapshots (team_id, observed_at, raw_id)
    VALUES (v_home, v_t0, v_raw_ids[1]) RETURNING snapshot_id INTO v_snapshot;
    INSERT INTO core.roster_snapshot_players (snapshot_id, player_id)
    VALUES (v_snapshot, v_players[1]);
    INSERT INTO core.roster_snapshots (team_id, observed_at, raw_id)
    VALUES (v_home, v_t1, v_raw_ids[2]) RETURNING snapshot_id INTO v_latest_snapshot;
    INSERT INTO core.roster_snapshot_players (snapshot_id, player_id)
    VALUES (v_latest_snapshot, v_players[2]);

    SELECT * INTO STRICT v_result
    FROM core.v_player_latest_roster_observations WHERE team_id = v_home;
    IF v_result.snapshot_id IS DISTINCT FROM v_latest_snapshot
       OR v_result.player_id IS DISTINCT FROM v_players[2] THEN
        RAISE EXCEPTION 'FAIL: возвращён старый состав';
    END IF;
    RAISE NOTICE 'OK: последние составы выбираются по команде, старый игрок не остаётся в составе';

    SELECT * INTO STRICT v_result FROM core.v_head_coaches_by_game
    WHERE game_id = v_game AND side = 'home';
    IF v_result.coach_id IS DISTINCT FROM v_coach
       OR v_result.team_id IS DISTINCT FROM v_home
       OR v_result.coach_name IS DISTINCT FROM 'Test Coach' THEN
        RAISE EXCEPTION 'FAIL: главный тренер определён неверно';
    END IF;
    RAISE NOTICE 'OK: главный тренер связан с правильной стороной';

    UPDATE core.team_name_versions SET valid_from = NULL
    WHERE team_id = v_home AND name = 'Old Home';
    SELECT * INTO STRICT v_result FROM core.v_game_results WHERE game_id = v_game;
    IF v_result.home_team_name IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: неизвестное историческое название заменено догадкой';
    END IF;
    RAISE NOTICE 'OK: при неизвестной истории названия матч остаётся видимым с NULL';

    INSERT INTO core.roster_snapshots (team_id, observed_at, raw_id)
    VALUES (v_home, v_t1 + INTERVAL '1 day', v_raw_ids[3])
    RETURNING snapshot_id INTO v_latest_snapshot;
    SELECT * INTO STRICT v_result FROM core.v_player_latest_roster_observations
    WHERE team_id = v_home;
    IF v_result.snapshot_id IS DISTINCT FROM v_latest_snapshot
       OR v_result.player_id IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: пустой последний состав потерян';
    END IF;
    RAISE NOTICE 'OK: пустой последний состав не подменён старым';

    UPDATE core.game_coach_versions SET is_deleted = true
    WHERE game_id = v_game AND coach_id = v_coach;
    IF EXISTS (SELECT 1 FROM core.v_head_coaches_by_game WHERE game_id = v_game) THEN
        RAISE EXCEPTION 'FAIL: логически удалённый тренер попал в представление';
    END IF;
    RAISE NOTICE 'OK: логически удалённые сведения исключены из представления';

    SET CONSTRAINTS ALL IMMEDIATE;
END;
$$;

ROLLBACK;
