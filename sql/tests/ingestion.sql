BEGIN;

CREATE TEMP TABLE ingestion_test_session (marker INTEGER) ON COMMIT DROP;

CREATE FUNCTION pg_temp.expect_ingestion_error(
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
    v_source_one BIGINT;
    v_source_two BIGINT;
    v_run_one BIGINT;
    v_run_two BIGINT;
    v_raw BIGINT;
    v_team_one BIGINT;
    v_team_two BIGINT;
    v_game_one BIGINT;
    v_game_two BIGINT;
    v_goal_one BIGINT;
    v_goal_two BIGINT;
    v_cursor TEXT;
    v_status TEXT;
    v_issue_count BIGINT;
    v_coverage_count BIGINT;
    v_t0 TIMESTAMPTZ := '2026-01-01 00:00:00+00';
    v_t1 TIMESTAMPTZ := '2026-01-02 00:00:00+00';
BEGIN
    INSERT INTO ingest.data_sources (source_code, base_uri)
    VALUES ('ingest_test_one_' || txid_current(), 'https://example.invalid')
    RETURNING source_id INTO v_source_one;

    INSERT INTO ingest.data_sources (source_code, base_uri)
    VALUES ('ingest_test_two_' || txid_current(), 'https://example.invalid')
    RETURNING source_id INTO v_source_two;

    INSERT INTO ingest.ingestion_runs (loader_version)
    VALUES ('ingestion-test') RETURNING run_id INTO v_run_one;
    INSERT INTO ingest.ingestion_runs (loader_version)
    VALUES ('ingestion-test') RETURNING run_id INTO v_run_two;

    INSERT INTO ingest.raw_snapshots (
        source_id, run_id, request_uri, http_status, payload_hash, payload_uri
    ) VALUES (
        v_source_one, v_run_one, 'https://example.invalid/game',
        200, repeat('0', 64), 'test://ingestion.json'
    ) RETURNING raw_id INTO v_raw;

    INSERT INTO core.teams DEFAULT VALUES RETURNING team_id INTO v_team_one;
    INSERT INTO core.teams DEFAULT VALUES RETURNING team_id INTO v_team_two;
    INSERT INTO core.games DEFAULT VALUES RETURNING game_id INTO v_game_one;
    INSERT INTO core.games DEFAULT VALUES RETURNING game_id INTO v_game_two;
    INSERT INTO core.goals DEFAULT VALUES RETURNING goal_id INTO v_goal_one;
    INSERT INTO core.goals DEFAULT VALUES RETURNING goal_id INTO v_goal_two;

    INSERT INTO ingest.team_source_ids (source_id, external_id, team_id)
    VALUES
        (v_source_one, 'team-1', v_team_one),
        (v_source_two, 'team-1', v_team_two);

    INSERT INTO ingest.goal_source_ids (source_id, game_id, external_id, goal_id)
    VALUES
        (v_source_one, v_game_one, 'event-1', v_goal_one),
        (v_source_one, v_game_two, 'event-1', v_goal_two);

    RAISE NOTICE 'OK: внешние ID разделены по источникам и матчам';

    PERFORM pg_temp.expect_ingestion_error(
        format(
            'INSERT INTO ingest.team_source_ids (source_id, external_id, team_id) VALUES (%s, ''team-1'', %s)',
            v_source_one, v_team_two
        ),
        '23505', '',
        'повторное соответствие внешнего ID запрещено'
    );

    PERFORM pg_temp.expect_ingestion_error(
        format(
            'INSERT INTO ingest.ingestion_issues (run_id, raw_id, error_code, description) VALUES (%s, %s, ''TEST'', ''Ответ другого запуска'')',
            v_run_two, v_raw
        ),
        '23503', '',
        'ошибка не может ссылаться на ответ другого запуска'
    );

    INSERT INTO ingest.ingestion_issues (
        run_id, raw_id, error_code, description, request_uri
    ) VALUES (
        v_run_one, NULL, 'NETWORK', 'Ответ не получен',
        'https://example.invalid/timeout'
    );

    RAISE NOTICE 'OK: сетевая ошибка без исходного ответа допустима';

    INSERT INTO ingest.ingestion_checkpoints (
        source_id, stream_code, partition_key, cursor_value
    ) VALUES (v_source_one, 'games', '2025', 'before');

    PERFORM pg_temp.expect_ingestion_error(
        format(
            'INSERT INTO ingest.ingestion_checkpoints (source_id, stream_code, partition_key, cursor_value) VALUES (%s, ''games'', ''2025'', ''duplicate'')',
            v_source_one
        ),
        '23505', '',
        'два чекпоинта одной партиции запрещены'
    );

    INSERT INTO ingest.game_coverage_versions (
        game_id, dataset_code, coverage_status, known_from, raw_id
    ) VALUES (v_game_one, 'events', 'partial', v_t0, v_raw);

    PERFORM pg_temp.expect_ingestion_error(
        format(
            'INSERT INTO ingest.game_coverage_versions (game_id, dataset_code, coverage_status, known_from, raw_id) VALUES (%s, ''events'', ''complete'', %L, %s)',
            v_game_one, v_t1, v_raw
        ),
        '23P01', '',
        'пересекающиеся версии полноты запрещены'
    );

    SELECT count(*) INTO v_issue_count
    FROM ingest.ingestion_issues WHERE run_id = v_run_one;

    BEGIN
        UPDATE ingest.ingestion_checkpoints
        SET cursor_value = 'after'
        WHERE source_id = v_source_one
          AND stream_code = 'games' AND partition_key = '2025';

        INSERT INTO ingest.ingestion_issues (
            run_id, error_code, description
        ) VALUES (v_run_one, 'TEMPORARY_TEST', 'Запись должна откатиться');

        RAISE EXCEPTION 'Искусственный сбой' USING ERRCODE = 'ZX001';
    EXCEPTION WHEN SQLSTATE 'ZX001' THEN
        NULL;
    END;

    SELECT cursor_value INTO STRICT v_cursor
    FROM ingest.ingestion_checkpoints
    WHERE source_id = v_source_one
      AND stream_code = 'games' AND partition_key = '2025';

    IF v_cursor IS DISTINCT FROM 'before'
       OR (SELECT count(*) FROM ingest.ingestion_issues
           WHERE run_id = v_run_one) <> v_issue_count THEN
        RAISE EXCEPTION 'FAIL: связанные изменения откатились не полностью';
    END IF;

    RAISE NOTICE 'OK: сбой откатывает чекпоинт вместе с другими изменениями';

    UPDATE ingest.game_coverage_versions
    SET known_to = v_t1
    WHERE game_id = v_game_one AND dataset_code = 'events';

    INSERT INTO ingest.game_coverage_versions (
        game_id, dataset_code, coverage_status, known_from, raw_id
    ) VALUES (v_game_one, 'events', 'complete', v_t1, v_raw);

    SELECT coverage_status INTO STRICT v_status
    FROM ingest.game_coverage_versions
    WHERE game_id = v_game_one AND dataset_code = 'events'
      AND known_from <= v_t0 AND v_t0 < known_to;

    IF v_status IS DISTINCT FROM 'partial' THEN
        RAISE EXCEPTION 'FAIL: прежний статус полноты потерян';
    END IF;

    SELECT coverage_status INTO STRICT v_status
    FROM ingest.game_coverage_versions
    WHERE game_id = v_game_one AND dataset_code = 'events'
      AND known_from <= v_t1 AND v_t1 < known_to;

    SELECT count(*) INTO v_coverage_count
    FROM ingest.game_coverage_versions
    WHERE game_id = v_game_one AND dataset_code = 'events';

    IF v_status IS DISTINCT FROM 'complete' OR v_coverage_count <> 2 THEN
        RAISE EXCEPTION 'FAIL: новая версия полноты не сохранена';
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'OK: исправление полноты сохраняет прежний и новый срезы';
END;
$$;

ROLLBACK;
