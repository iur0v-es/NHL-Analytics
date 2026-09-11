BEGIN;

DO $$
DECLARE
    source_id BIGINT;
    run_id BIGINT;
    raw_id BIGINT;
    season_id BIGINT;
    home_id BIGINT;
    away_id BIGINT;
    match_id BIGINT;
    rejected BOOLEAN;
BEGIN

    INSERT INTO ingest.data_sources (source_code, base_uri)
    VALUES (
        'matches_test_' || txid_current(),
        'https://example.invalid'
    )
    RETURNING data_sources.source_id INTO source_id;

    INSERT INTO ingest.ingestion_runs (loader_version)
    VALUES ('matches-test')
    RETURNING ingestion_runs.run_id INTO run_id;

    INSERT INTO ingest.raw_snapshots (
        source_id, run_id, request_uri,
        http_status, payload_hash, payload_uri
    )
    VALUES (
        source_id,
        run_id,
        'https://example.invalid/game',
        200,
        repeat('0', 64),
        'test://game.json'
    )
    RETURNING raw_snapshots.raw_id INTO raw_id;



    INSERT INTO core.seasons (start_year, status)
    VALUES (2026, 'active')
    ON CONFLICT (start_year)
    DO UPDATE SET start_year = EXCLUDED.start_year
    RETURNING seasons.season_id INTO season_id;

    INSERT INTO core.teams DEFAULT VALUES
    RETURNING team_id INTO home_id;

    INSERT INTO core.teams DEFAULT VALUES
    RETURNING team_id INTO away_id;

    INSERT INTO core.team_seasons (team_id, season_id)
    VALUES
        (home_id, season_id),
        (away_id, season_id);



    INSERT INTO core.games DEFAULT VALUES
    RETURNING game_id INTO match_id;

    INSERT INTO core.game_versions (
        game_id, season_id, game_type_code,
        starts_at, status, finish_type,
        known_from, raw_id
    )
    VALUES (
        match_id,
        season_id,
        'regular',
        '2026-01-10 18:00:00+00',
        'finished',
        'regulation',
        '2026-01-11 00:00:00+00',
        raw_id
    );

    INSERT INTO core.game_team_versions (
        game_id, team_id, side,
        official_score, known_from, raw_id
    )
    VALUES
        (
            match_id, home_id, 'home', 3,
            '2026-01-11 00:00:00+00', raw_id
        ),
        (
            match_id, away_id, 'away', 2,
            '2026-01-11 00:00:00+00', raw_id
        );

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    RAISE NOTICE 'OK: корректный матч принят';



    rejected := false;

    BEGIN
        DELETE FROM core.game_team_versions
        WHERE game_id = match_id
          AND side = 'away';

        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION
        WHEN raise_exception THEN
            IF position('требуется две стороны' IN SQLERRM) = 0 THEN
                RAISE;
            END IF;

            rejected := true;
    END;

    IF NOT rejected THEN
        RAISE EXCEPTION 'FAIL: матч с одной стороной принят';
    END IF;

    SET CONSTRAINTS ALL DEFERRED;

    RAISE NOTICE 'OK: матч с одной стороной отклонён';



    rejected := false;

    BEGIN
        UPDATE core.game_team_versions
        SET official_score = NULL
        WHERE game_id = match_id
          AND side = 'away';

        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION
        WHEN raise_exception THEN
            IF position('неизвестен счёт' IN SQLERRM) = 0 THEN
                RAISE;
            END IF;

            rejected := true;
    END;

    IF NOT rejected THEN
        RAISE EXCEPTION 'FAIL: финальный матч без счёта принят';
    END IF;

    SET CONSTRAINTS ALL DEFERRED;

    RAISE NOTICE 'OK: финальный матч без счёта отклонён';



    rejected := false;

    BEGIN
        DELETE FROM core.team_seasons AS ts
        WHERE ts.team_id = away_id
          AND ts.season_id = (
              SELECT gv.season_id
              FROM core.game_versions AS gv
              WHERE gv.game_id = match_id
                AND NOT gv.is_deleted
                AND gv.known_to = 'infinity'::TIMESTAMPTZ
          );
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION
        WHEN raise_exception THEN
            IF position('не участвует в сезоне' IN SQLERRM) = 0 THEN
                RAISE;
            END IF;

            rejected := true;
    END;

    IF NOT rejected THEN
        RAISE EXCEPTION 'FAIL: команда вне сезона допущена';
    END IF;

    SET CONSTRAINTS ALL DEFERRED;

    RAISE NOTICE 'OK: исключение участвующей команды запрещено';
END;
$$;

ROLLBACK;