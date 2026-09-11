BEGIN;



CREATE FUNCTION core.lock_match_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'TRUNCATE' THEN
        RAISE EXCEPTION
            'TRUNCATE запрещён для таблиц связей матчей';
    END IF;

    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION
            'Изменения матчей требуют уровня READ COMMITTED';
    END IF;

    PERFORM pg_advisory_xact_lock(17001, 1);

    RETURN NULL;
END;
$$;

CREATE TRIGGER lock_game_versions
BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE
ON core.game_versions
FOR EACH STATEMENT
EXECUTE FUNCTION core.lock_match_changes();

CREATE TRIGGER lock_game_team_versions
BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE
ON core.game_team_versions
FOR EACH STATEMENT
EXECUTE FUNCTION core.lock_match_changes();

CREATE TRIGGER lock_team_seasons
BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE
ON core.team_seasons
FOR EACH STATEMENT
EXECUTE FUNCTION core.lock_match_changes();



CREATE FUNCTION core.validate_game_history(
    checked_game_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    checked_at TIMESTAMPTZ;
    game_row core.game_versions%ROWTYPE;
    game_exists BOOLEAN;
    side_count BIGINT;
    score_count BIGINT;
BEGIN
    FOR checked_at IN
        SELECT boundary
        FROM (
            SELECT known_from AS boundary
            FROM core.game_versions
            WHERE game_id = checked_game_id

            UNION

            SELECT known_to
            FROM core.game_versions
            WHERE game_id = checked_game_id

            UNION

            SELECT known_from
            FROM core.game_team_versions
            WHERE game_id = checked_game_id

            UNION

            SELECT known_to
            FROM core.game_team_versions
            WHERE game_id = checked_game_id
        ) AS boundaries
        WHERE isfinite(boundary)
        ORDER BY boundary
    LOOP
        SELECT *
        INTO game_row
        FROM core.game_versions
        WHERE game_id = checked_game_id
          AND known_from <= checked_at
          AND checked_at < known_to
          AND NOT is_deleted;

        game_exists := FOUND;

        SELECT
            count(*),
            count(official_score)
        INTO side_count, score_count
        FROM core.game_team_versions
        WHERE game_id = checked_game_id
          AND known_from <= checked_at
          AND checked_at < known_to
          AND NOT is_deleted;

        IF NOT game_exists THEN
            IF side_count > 0 THEN
                RAISE EXCEPTION
                    'Матч %: стороны существуют без версии матча на %',
                    checked_game_id, checked_at;
            END IF;

            CONTINUE;
        END IF;

        IF side_count <> 2 THEN
            RAISE EXCEPTION
                'Матч %: на % требуется две стороны, найдено %',
                checked_game_id, checked_at, side_count;
        END IF;

        IF game_row.status = 'finished' AND score_count <> 2 THEN
            RAISE EXCEPTION
                'Матч %: у завершённого матча неизвестен счёт на %',
                checked_game_id, checked_at;
        END IF;

        IF EXISTS (
            SELECT 1
            FROM core.game_team_versions AS gt
            WHERE gt.game_id = checked_game_id
              AND gt.known_from <= checked_at
              AND checked_at < gt.known_to
              AND NOT gt.is_deleted
              AND NOT EXISTS (
                  SELECT 1
                  FROM core.team_seasons AS ts
                  WHERE ts.team_id = gt.team_id
                    AND ts.season_id = game_row.season_id
              )
        ) THEN
            RAISE EXCEPTION
                'Матч %: команда не участвует в сезоне % на %',
                checked_game_id, game_row.season_id, checked_at;
        END IF;
    END LOOP;
END;
$$;



CREATE FUNCTION core.check_changed_game()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM core.validate_game_history(OLD.game_id);
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM core.validate_game_history(NEW.game_id);
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER check_game_versions
AFTER INSERT OR UPDATE OR DELETE
ON core.game_versions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION core.check_changed_game();

CREATE CONSTRAINT TRIGGER check_game_team_versions
AFTER INSERT OR UPDATE OR DELETE
ON core.game_team_versions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION core.check_changed_game();



CREATE FUNCTION core.check_changed_team_season()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected_seasons BIGINT[] := ARRAY[]::BIGINT[];
    checked_game_id BIGINT;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        affected_seasons :=
            array_append(affected_seasons, OLD.season_id);
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        affected_seasons :=
            array_append(affected_seasons, NEW.season_id);
    END IF;

    FOR checked_game_id IN
        SELECT DISTINCT game_id
        FROM core.game_versions
        WHERE season_id = ANY(affected_seasons)
    LOOP
        PERFORM core.validate_game_history(checked_game_id);
    END LOOP;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER check_team_seasons
AFTER INSERT OR UPDATE OR DELETE
ON core.team_seasons
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION core.check_changed_team_season();



DO $$
DECLARE
    checked_game_id BIGINT;
BEGIN
    FOR checked_game_id IN
        SELECT game_id FROM core.games
    LOOP
        PERFORM core.validate_game_history(checked_game_id);
    END LOOP;
END;
$$;

COMMIT;