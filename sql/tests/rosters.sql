BEGIN;

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
    v_player_id BIGINT;
    v_snapshot_id BIGINT;
    v_rejected BOOLEAN;
BEGIN


    INSERT INTO ingest.data_sources (source_code, base_uri)
    VALUES (
        'rosters_test_' || txid_current(),
        'https://example.invalid'
    )
    RETURNING source_id INTO v_source_id;

    INSERT INTO ingest.ingestion_runs (loader_version)
    VALUES ('rosters-test')
    RETURNING run_id INTO v_run_id;

    INSERT INTO ingest.raw_snapshots (
        source_id, run_id, request_uri,
        http_status, payload_hash, payload_uri
    )
    VALUES (
        v_source_id,
        v_run_id,
        'https://example.invalid/roster',
        200,
        repeat('0', 64),
        'test://roster.json'
    )
    RETURNING raw_id INTO v_raw_id;



    INSERT INTO core.seasons (start_year, status)
    VALUES (2026, 'active')
    ON CONFLICT (start_year) DO NOTHING;

    SELECT season_id INTO STRICT v_season_id
    FROM core.seasons
    WHERE start_year = 2026;

    INSERT INTO core.teams DEFAULT VALUES
    RETURNING team_id INTO v_home_id;

    INSERT INTO core.teams DEFAULT VALUES
    RETURNING team_id INTO v_away_id;

    INSERT INTO core.team_seasons (team_id, season_id)
    VALUES
        (v_home_id, v_season_id),
        (v_away_id, v_season_id);

    INSERT INTO core.games DEFAULT VALUES
    RETURNING game_id INTO v_game_id;

    INSERT INTO core.game_versions (
        game_id, season_id, game_type_code,
        status, known_from, raw_id
    )
    VALUES (
        v_game_id, v_season_id, 'regular',
        'scheduled', '2026-01-01 00:00:00+00', v_raw_id
    );

    INSERT INTO core.game_team_versions (
        game_id, team_id, side, known_from, raw_id
    )
    VALUES
        (
            v_game_id, v_home_id, 'home',
            '2026-01-01 00:00:00+00', v_raw_id
        ),
        (
            v_game_id, v_away_id, 'away',
            '2026-01-01 00:00:00+00', v_raw_id
        );



    INSERT INTO core.persons DEFAULT VALUES
    RETURNING person_id INTO v_person_id;

    INSERT INTO core.players (person_id)
    VALUES (v_person_id)
    RETURNING player_id INTO v_player_id;

    INSERT INTO core.roster_snapshots (
        team_id, observed_at, raw_id
    )
    VALUES (
        v_home_id, '2026-01-01 00:00:00+00', v_raw_id
    )
    RETURNING snapshot_id INTO v_snapshot_id;

    INSERT INTO core.roster_snapshot_players (
        snapshot_id, player_id, jersey_number
    )
    VALUES (v_snapshot_id, v_player_id, 17);

    INSERT INTO core.game_player_versions (
        game_id, player_id, side, jersey_number,
        known_from, raw_id
    )
    VALUES (
        v_game_id, v_player_id, 'home', 17,
        '2026-01-01 00:00:00+00', v_raw_id
    );

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    RAISE NOTICE 'OK: состав и участие игрока сохранены';



    v_rejected := false;

    BEGIN
        INSERT INTO core.roster_snapshot_players (
            snapshot_id, player_id, jersey_number
        )
        VALUES (v_snapshot_id, v_player_id, 17);
    EXCEPTION
        WHEN unique_violation THEN
            v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'FAIL: дубликат игрока в составе принят';
    END IF;

    RAISE NOTICE 'OK: дубликат игрока в составе запрещён';


    -- Игрок не может одновременно представлять обе стороны

    v_rejected := false;

    BEGIN
        INSERT INTO core.game_player_versions (
            game_id, player_id, side, known_from, raw_id
        )
        VALUES (
            v_game_id, v_player_id, 'away',
            '2026-01-02 00:00:00+00', v_raw_id
        );
    EXCEPTION
        WHEN exclusion_violation THEN
            v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'FAIL: участие за обе стороны разрешено';
    END IF;

    RAISE NOTICE 'OK: участие за обе стороны запрещено';



    v_rejected := false;

    BEGIN
        UPDATE core.game_player_versions
        SET known_from = '2025-12-31 00:00:00+00'
        WHERE game_id = v_game_id
          AND player_id = v_player_id;

        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION
        WHEN raise_exception THEN
            IF position(
                'участие игрока выходит за период' IN SQLERRM
            ) = 0 THEN
                RAISE;
            END IF;

            v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'FAIL: участие без существующей стороны принято';
    END IF;

    SET CONSTRAINTS ALL DEFERRED;

    RAISE NOTICE 'OK: участие без существующей стороны запрещено';



    UPDATE core.game_team_versions
    SET known_to = '2026-01-02 00:00:00+00'
    WHERE game_id = v_game_id
      AND side = 'home'
      AND known_to = 'infinity'::TIMESTAMPTZ;

    INSERT INTO core.game_team_versions (
        game_id, team_id, side, official_score,
        known_from, raw_id
    )
    VALUES (
        v_game_id, v_home_id, 'home', 0,
        '2026-01-02 00:00:00+00', v_raw_id
    );

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    RAISE NOTICE 'OK: смена версии стороны сохраняет связь с игроком';
END;
$$;

ROLLBACK;