BEGIN;

CREATE TEMP TABLE coach_test_session (marker INTEGER) ON COMMIT DROP;

CREATE FUNCTION pg_temp.expect_coach_error(
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
    v_head_id BIGINT;
    v_assistant_one_id BIGINT;
    v_assistant_two_id BIGINT;
    v_other_head_id BIGINT;
    v_t0 TIMESTAMPTZ := '2026-01-01 00:00:00+00';
    v_t1 TIMESTAMPTZ := '2026-01-02 00:00:00+00';
BEGIN
    INSERT INTO ingest.data_sources (source_code, base_uri)
    VALUES (
        'coaches_test_' || txid_current(),
        'https://example.invalid'
    ) RETURNING source_id INTO v_source_id;

    INSERT INTO ingest.ingestion_runs (loader_version)
    VALUES ('coaches-test') RETURNING run_id INTO v_run_id;

    INSERT INTO ingest.raw_snapshots (
        source_id, run_id, request_uri,
        http_status, payload_hash, payload_uri
    ) VALUES (
        v_source_id, v_run_id, 'https://example.invalid/coaches',
        200, repeat('0', 64), 'test://coaches.json'
    ) RETURNING raw_id INTO v_raw_id;

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
        game_id, season_id, game_type_code, status, known_from, raw_id
    ) VALUES (
        v_game_id, v_season_id, 'regular', 'scheduled', v_t0, v_raw_id
    );

    INSERT INTO core.game_team_versions (
        game_id, team_id, side, known_from, raw_id
    ) VALUES
        (v_game_id, v_home_id, 'home', v_t0, v_raw_id),
        (v_game_id, v_away_id, 'away', v_t0, v_raw_id);

    INSERT INTO core.persons DEFAULT VALUES
    RETURNING person_id INTO v_person_id;
    INSERT INTO core.coaches (person_id) VALUES (v_person_id)
    RETURNING coach_id INTO v_head_id;

    INSERT INTO core.persons DEFAULT VALUES
    RETURNING person_id INTO v_person_id;
    INSERT INTO core.coaches (person_id) VALUES (v_person_id)
    RETURNING coach_id INTO v_assistant_one_id;

    INSERT INTO core.persons DEFAULT VALUES
    RETURNING person_id INTO v_person_id;
    INSERT INTO core.coaches (person_id) VALUES (v_person_id)
    RETURNING coach_id INTO v_assistant_two_id;

    INSERT INTO core.persons DEFAULT VALUES
    RETURNING person_id INTO v_person_id;
    INSERT INTO core.coaches (person_id) VALUES (v_person_id)
    RETURNING coach_id INTO v_other_head_id;

    INSERT INTO core.game_coach_versions (
        game_id, coach_id, role_code, side, known_from, raw_id
    ) VALUES (
        v_game_id, v_head_id, 'head', 'home', v_t0, v_raw_id
    );

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'OK: главный тренер принят, отсутствие сведений о тренере гостей допустимо';

    INSERT INTO core.game_coach_versions (
        game_id, coach_id, role_code, side, known_from, raw_id
    ) VALUES
        (v_game_id, v_assistant_one_id, 'assistant', 'home', v_t0, v_raw_id),
        (v_game_id, v_assistant_two_id, 'assistant', 'home', v_t0, v_raw_id);

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'OK: несколько помощников одной стороны допустимы';

    PERFORM pg_temp.expect_coach_error(
        format(
            'INSERT INTO core.game_coach_versions (game_id, coach_id, role_code, side, known_from, raw_id) VALUES (%s, %s, ''head'', ''home'', %L, %s)',
            v_game_id, v_other_head_id, v_t0, v_raw_id
        ),
        '23P01', '',
        'второй одновременный главный тренер запрещён'
    );

    PERFORM pg_temp.expect_coach_error(
        format(
            'INSERT INTO core.game_coach_versions (game_id, coach_id, role_code, side, known_from, raw_id) VALUES (%s, %s, ''assistant'', ''away'', %L, %s)',
            v_game_id, v_head_id, v_t0, v_raw_id
        ),
        '23P01', '',
        'представление одним тренером обеих сторон запрещено'
    );

    PERFORM pg_temp.expect_coach_error(
        format(
            'INSERT INTO core.game_coach_versions (game_id, coach_id, role_code, side, known_from, raw_id) VALUES (%s, %s, ''assistant'', ''home'', %L, %s)',
            v_game_id, v_assistant_one_id, v_t1, v_raw_id
        ),
        '23P01', '',
        'пересекающиеся версии участия помощника запрещены'
    );

    PERFORM pg_temp.expect_coach_error(
        format(
            'UPDATE core.game_coach_versions SET known_from = %L WHERE game_id = %s AND coach_id = %s',
            v_t0 - INTERVAL '1 day', v_game_id, v_head_id
        ),
        '23514', 'участие тренера выходит за период',
        'участие тренера раньше существования стороны запрещено'
    );

    UPDATE core.game_team_versions
    SET known_to = v_t1
    WHERE game_id = v_game_id AND side = 'home';

    INSERT INTO core.game_team_versions (
        game_id, team_id, side, official_score, known_from, raw_id
    ) VALUES (
        v_game_id, v_home_id, 'home', 0, v_t1, v_raw_id
    );

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'OK: смежные версии стороны сохраняют связь с тренерами';
END;
$$;

ROLLBACK;
