BEGIN;

CREATE FUNCTION core.validate_goal_links(p_goal_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM core.goal_versions AS g
        WHERE g.goal_id = p_goal_id
          AND NOT g.is_deleted
          AND NOT (
              COALESCE(
                  (
                      SELECT range_agg(
                          tstzrange(p.known_from, p.known_to, '[)')
                      )
                      FROM core.game_player_versions AS p
                      WHERE p.game_id = g.game_id
                        AND p.player_id = g.scorer_player_id
                        AND NOT p.is_deleted
                  ),
                  '{}'::TSTZMULTIRANGE
              ) @> tstzrange(g.known_from, g.known_to, '[)')
          )
    ) THEN
        RAISE EXCEPTION 'Гол %: автор не участвует в матче на всём интервале версии', p_goal_id
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM core.goal_assist_versions AS a
        WHERE a.goal_id = p_goal_id
          AND NOT a.is_deleted
          AND NOT (
              COALESCE(
                  (
                      SELECT range_agg(
                          tstzrange(g.known_from, g.known_to, '[)')
                          * tstzrange(s.known_from, s.known_to, '[)')
                          * tstzrange(p.known_from, p.known_to, '[)')
                      )
                      FROM core.goal_versions AS g
                      JOIN core.game_player_versions AS s
                        ON s.game_id = g.game_id
                       AND s.player_id = g.scorer_player_id
                       AND NOT s.is_deleted
                      JOIN core.game_player_versions AS p
                        ON p.game_id = g.game_id
                       AND p.player_id = a.player_id
                       AND p.side = s.side
                       AND NOT p.is_deleted
                      WHERE g.goal_id = a.goal_id
                        AND NOT g.is_deleted
                        AND a.player_id <> g.scorer_player_id
                  ),
                  '{}'::TSTZMULTIRANGE
              ) @> tstzrange(a.known_from, a.known_to, '[)')
          )
    ) THEN
        RAISE EXCEPTION 'Гол %: неверный ассистент, сторона или интервал передачи', p_goal_id
            USING ERRCODE = '23514';
    END IF;
END;
$$;


CREATE FUNCTION core.validate_shootout_links(p_attempt_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM core.shootout_attempt_versions AS a
        WHERE a.attempt_id = p_attempt_id
          AND NOT a.is_deleted
          AND NOT (
              COALESCE(
                  (
                      SELECT range_agg(
                          tstzrange(s.known_from, s.known_to, '[)')
                          * tstzrange(g.known_from, g.known_to, '[)')
                          * CASE
                              WHEN a.goalie_player_id IS NULL THEN
                                  tstzrange(s.known_from, s.known_to, '[)')
                              ELSE
                                  tstzrange(k.known_from, k.known_to, '[)')
                            END
                      )
                      FROM core.game_player_versions AS s
                      JOIN core.game_versions AS g
                        ON g.game_id = s.game_id
                       AND NOT g.is_deleted
                       AND g.game_type_code = 'regular'
                      LEFT JOIN core.game_player_versions AS k
                        ON k.game_id = s.game_id
                       AND k.player_id = a.goalie_player_id
                       AND k.side <> s.side
                       AND NOT k.is_deleted
                      WHERE s.game_id = a.game_id
                        AND s.player_id = a.shooter_player_id
                        AND NOT s.is_deleted
                        AND (
                            a.goalie_player_id IS NULL
                            OR k.version_id IS NOT NULL
                        )
                  ),
                  '{}'::TSTZMULTIRANGE
              ) @> tstzrange(a.known_from, a.known_to, '[)')
          )
    ) THEN
        RAISE EXCEPTION 'Буллит %: неверные участники, тип матча или интервал версии', p_attempt_id
            USING ERRCODE = '23514';
    END IF;
END;
$$;


CREATE FUNCTION core.check_changed_event_links()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_ids BIGINT[] := ARRAY[]::BIGINT[];
    v_id BIGINT;
BEGIN
    IF TG_TABLE_NAME IN ('goal_versions', 'goal_assist_versions') THEN
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
            PERFORM core.validate_goal_links(OLD.goal_id);
        END IF;
        IF TG_OP IN ('INSERT', 'UPDATE') THEN
            PERFORM core.validate_goal_links(NEW.goal_id);
        END IF;

    ELSIF TG_TABLE_NAME = 'shootout_attempt_versions' THEN
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
            PERFORM core.validate_shootout_links(OLD.attempt_id);
        END IF;
        IF TG_OP IN ('INSERT', 'UPDATE') THEN
            PERFORM core.validate_shootout_links(NEW.attempt_id);
        END IF;

    ELSE
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
            v_ids := array_append(v_ids, OLD.game_id);
        END IF;
        IF TG_OP IN ('INSERT', 'UPDATE') THEN
            v_ids := array_append(v_ids, NEW.game_id);
        END IF;

        FOR v_id IN
            SELECT DISTINCT goal_id
            FROM core.goal_versions
            WHERE game_id = ANY(v_ids)
        LOOP
            PERFORM core.validate_goal_links(v_id);
        END LOOP;

        FOR v_id IN
            SELECT DISTINCT attempt_id
            FROM core.shootout_attempt_versions
            WHERE game_id = ANY(v_ids)
        LOOP
            PERFORM core.validate_shootout_links(v_id);
        END LOOP;
    END IF;

    RETURN NULL;
END;
$$;


CREATE TRIGGER lock_goal_versions
BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE
ON core.goal_versions
FOR EACH STATEMENT
EXECUTE FUNCTION core.lock_match_changes();

CREATE TRIGGER lock_goal_assist_versions
BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE
ON core.goal_assist_versions
FOR EACH STATEMENT
EXECUTE FUNCTION core.lock_match_changes();

CREATE TRIGGER lock_shootout_attempt_versions
BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE
ON core.shootout_attempt_versions
FOR EACH STATEMENT
EXECUTE FUNCTION core.lock_match_changes();


CREATE CONSTRAINT TRIGGER check_goal_links
AFTER INSERT OR UPDATE OR DELETE ON core.goal_versions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION core.check_changed_event_links();

CREATE CONSTRAINT TRIGGER check_assist_links
AFTER INSERT OR UPDATE OR DELETE ON core.goal_assist_versions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION core.check_changed_event_links();

CREATE CONSTRAINT TRIGGER check_shootout_links
AFTER INSERT OR UPDATE OR DELETE ON core.shootout_attempt_versions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION core.check_changed_event_links();

CREATE CONSTRAINT TRIGGER check_player_event_links
AFTER INSERT OR UPDATE OR DELETE ON core.game_player_versions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION core.check_changed_event_links();

CREATE CONSTRAINT TRIGGER check_game_event_links
AFTER INSERT OR UPDATE OR DELETE ON core.game_versions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION core.check_changed_event_links();


DO $$
DECLARE
    v_id BIGINT;
BEGIN
    FOR v_id IN SELECT goal_id FROM core.goals LOOP
        PERFORM core.validate_goal_links(v_id);
    END LOOP;
    FOR v_id IN SELECT attempt_id FROM core.shootout_attempts LOOP
        PERFORM core.validate_shootout_links(v_id);
    END LOOP;
END;
$$;

COMMIT;