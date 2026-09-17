BEGIN;

CREATE TEMP TABLE event_test_session (marker INTEGER) ON COMMIT DROP;

CREATE FUNCTION pg_temp.expect_event_error(
    p_statement TEXT,
    p_expected_state TEXT,
    p_expected_text TEXT,
    p_label TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_rejected BOOLEAN := false;
    v_state TEXT;
    v_message TEXT;
BEGIN
    BEGIN
        EXECUTE p_statement;
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_state = RETURNED_SQLSTATE,
            v_message = MESSAGE_TEXT;

        IF v_state <> p_expected_state
           OR position(p_expected_text IN v_message) = 0 THEN
            RAISE EXCEPTION
                'FAIL [%]: неожиданная ошибка [%] %',
                p_label, v_state, v_message;
        END IF;
        v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'FAIL [%]: ошибочная операция разрешена', p_label;
    END IF;

    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'OK: %', p_label;
END;
$$;

DO $$
DECLARE
    v_source_id BIGINT;
    v_run_id BIGINT;
    v_raw_id BIGINT;
    v_season_id BIGINT;
    v_home_id BIGINT;
    v_away_id BIGINT;
    v_game_id BIGINT;
    v_person_id BIGINT;
    v_scorer_id BIGINT;
    v_assistant_id BIGINT;
    v_opponent_id BIGINT;
    v_outsider_id BIGINT;
    v_goal_id BIGINT;
    v_attempt_id BIGINT;
    v_t0 TIMESTAMPTZ := '2026-01-11 00:00:00+00';
    v_t1 TIMESTAMPTZ := '2026-01-12 00:00:00+00';
BEGIN
    INSERT INTO ingest.data_sources (source_code, base_uri)
    VALUES (
        'events_test_' || txid_current(),
        'https://example.invalid'
    )
    RETURNING source_id INTO v_source_id;

    INSERT INTO ingest.ingestion_runs (loader_version)
    VALUES ('events-test')
    RETURNING run_id INTO v_run_id;

    INSERT INTO ingest.raw_snapshots (
        source_id, run_id, request_uri,
        http_status, payload_hash, payload_uri
    )
    VALUES (
        v_source_id, v_run_id, 'https://example.invalid/game',
        200, repeat('0', 64), 'test://events.json'
    )
    RETURNING raw_id INTO v_raw_id;

    INSERT INTO core.seasons (start_year, status)
    VALUES (2025, 'completed')
    ON CONFLICT (start_year) DO NOTHING;

    SELECT season_id INTO STRICT v_season_id
    FROM core.seasons WHERE start_year = 2025;

    INSERT INTO core.teams DEFAULT VALUES
    RETURNING team_id INTO v_home_id;
    INSERT INTO core.teams DEFAULT VALUES
    RETURNING team_id INTO v_away_id;

    INSERT INTO core.team_seasons (team_id, season_id)
    VALUES (v_home_id, v_season_id), (v_away_id, v_season_id);

    INSERT INTO core.games DEFAULT VALUES
    RETURNING game_id INTO v_game_id;

    INSERT INTO core.game_versions (
        game_id, season_id, game_type_code,
        starts_at, status, finish_type, known_from, raw_id
    )
    VALUES (
        v_game_id, v_season_id, 'regular',
        '2026-01-10 18:00:00+00', 'finished', 'shootout', v_t0, v_raw_id
    );

    INSERT INTO core.game_team_versions (
        game_id, team_id, side, official_score, known_from, raw_id
    )
    VALUES
        (v_game_id, v_home_id, 'home', 3, v_t0, v_raw_id),
        (v_game_id, v_away_id, 'away', 2, v_t0, v_raw_id);

    INSERT INTO core.persons DEFAULT VALUES
    RETURNING person_id INTO v_person_id;
    INSERT INTO core.players (person_id) VALUES (v_person_id)
    RETURNING player_id INTO v_scorer_id;

    INSERT INTO core.persons DEFAULT VALUES
    RETURNING person_id INTO v_person_id;
    INSERT INTO core.players (person_id) VALUES (v_person_id)
    RETURNING player_id INTO v_assistant_id;

    INSERT INTO core.persons DEFAULT VALUES
    RETURNING person_id INTO v_person_id;
    INSERT INTO core.players (person_id) VALUES (v_person_id)
    RETURNING player_id INTO v_opponent_id;

    INSERT INTO core.persons DEFAULT VALUES
    RETURNING person_id INTO v_person_id;
    INSERT INTO core.players (person_id) VALUES (v_person_id)
    RETURNING player_id INTO v_outsider_id;

    INSERT INTO core.game_player_versions (
        game_id, player_id, side, jersey_number, known_from, raw_id
    )
    VALUES
        (v_game_id, v_scorer_id, 'home', 17, v_t0, v_raw_id),
        (v_game_id, v_assistant_id, 'home', 18, v_t0, v_raw_id),
        (v_game_id, v_opponent_id, 'away', 30, v_t0, v_raw_id);

    INSERT INTO core.goals DEFAULT VALUES
    RETURNING goal_id INTO v_goal_id;

    INSERT INTO core.goal_versions (
        goal_id, game_id, scorer_player_id,
        period_no, elapsed_seconds, known_from, raw_id
    )
    VALUES (
        v_goal_id, v_game_id, v_scorer_id, 1, 60, v_t0, v_raw_id
    );

    INSERT INTO core.goal_assist_versions (
        goal_id, player_id, assist_order, known_from, raw_id
    )
    VALUES (v_goal_id, v_assistant_id, 1, v_t0, v_raw_id);

    INSERT INTO core.shootout_attempts DEFAULT VALUES
    RETURNING attempt_id INTO v_attempt_id;

    INSERT INTO core.shootout_attempt_versions (
        attempt_id, game_id, shooter_player_id, goalie_player_id,
        attempt_no, is_scored, known_from, raw_id
    )
    VALUES (
        v_attempt_id, v_game_id, v_scorer_id, v_opponent_id,
        1, true, v_t0, v_raw_id
    );

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'OK: корректные гол, передача и буллит приняты';

    PERFORM pg_temp.expect_event_error(
        format(
            'UPDATE core.goal_versions SET scorer_player_id = %s WHERE goal_id = %s',
            v_outsider_id, v_goal_id
        ),
        '23514', 'автор не участвует',
        'гол постороннего игрока запрещён'
    );

    PERFORM pg_temp.expect_event_error(
        format(
            'UPDATE core.goal_assist_versions SET player_id = %s WHERE goal_id = %s',
            v_opponent_id, v_goal_id
        ),
        '23514', 'неверный ассистент',
        'передача игрока противоположной стороны запрещена'
    );

    PERFORM pg_temp.expect_event_error(
        format(
            'UPDATE core.goal_assist_versions SET player_id = %s WHERE goal_id = %s',
            v_scorer_id, v_goal_id
        ),
        '23514', 'неверный ассистент',
        'передача самому себе запрещена'
    );

    PERFORM pg_temp.expect_event_error(
        format(
            'INSERT INTO core.goal_assist_versions (goal_id, player_id, assist_order, known_from, raw_id) VALUES (%s, %s, 2, %L, %s)',
            v_goal_id, v_assistant_id, v_t0, v_raw_id
        ),
        '23P01', '',
        'повтор одного ассистента под другим номером запрещён'
    );

    PERFORM pg_temp.expect_event_error(
        format(
            'UPDATE core.shootout_attempt_versions SET goalie_player_id = %s WHERE attempt_id = %s',
            v_assistant_id, v_attempt_id
        ),
        '23514', 'неверные участники',
        'вратарь со стороны исполнителя запрещён'
    );

    PERFORM pg_temp.expect_event_error(
        format(
            'DELETE FROM core.game_player_versions WHERE game_id = %s AND player_id = %s',
            v_game_id, v_scorer_id
        ),
        '23514', 'автор не участвует',
        'удаление участия автора существующего гола запрещено'
    );

    PERFORM pg_temp.expect_event_error(
        format(
            'UPDATE core.game_player_versions SET known_to = %L WHERE game_id = %s AND player_id = %s',
            v_t1, v_game_id, v_scorer_id
        ),
        '23514', 'автор не участвует',
        'сокращение истории участия без исправления событий запрещено'
    );

    PERFORM pg_temp.expect_event_error(
        format(
            'UPDATE core.game_versions SET game_type_code = ''playoff'', finish_type = ''overtime'' WHERE game_id = %s',
            v_game_id
        ),
        '23514', 'неверные участники',
        'смена типа матча на плей-офф при наличии буллита запрещена'
    );

    PERFORM pg_temp.expect_event_error(
        format('DELETE FROM core.goal_versions WHERE goal_id = %s', v_goal_id),
        '23514', 'неверный ассистент',
        'удаление гола с сохранением передачи запрещено'
    );

    UPDATE core.game_player_versions
    SET known_to = v_t1
    WHERE game_id = v_game_id AND player_id = v_scorer_id;

    INSERT INTO core.game_player_versions (
        game_id, player_id, side, jersey_number, known_from, raw_id
    )
    VALUES (v_game_id, v_scorer_id, 'home', 19, v_t1, v_raw_id);

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'OK: смежные версии участия сохраняют связи событий';
END;
$$;

ROLLBACK;
