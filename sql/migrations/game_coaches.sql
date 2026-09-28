BEGIN;



CREATE TABLE core.game_coach_versions (
    version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    game_id BIGINT NOT NULL
        REFERENCES core.games (game_id),
    coach_id BIGINT NOT NULL
        REFERENCES core.coaches (coach_id),
    role_code TEXT NOT NULL
        REFERENCES core.coach_roles (role_code),

    side TEXT NOT NULL,

    known_from TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    known_to TIMESTAMPTZ NOT NULL DEFAULT 'infinity',
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),
    is_deleted BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (game_id, side, role_code, coach_id, known_from),

    CHECK (side IN ('home', 'away')),
    CHECK (isfinite(known_from)),
    CHECK (known_from < known_to),

    -- Версии одного факта не пересекаются
    EXCLUDE USING gist (
        game_id WITH =,
        side WITH =,
        role_code WITH =,
        coach_id WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    ),

    EXCLUDE USING gist (
        game_id WITH =,
        side WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
    WHERE (role_code = 'head' AND NOT is_deleted),

    EXCLUDE USING gist (
        game_id WITH =,
        coach_id WITH =,
        side WITH <>,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
    WHERE (NOT is_deleted)
);


CREATE INDEX game_coach_versions_coach_game_idx
    ON core.game_coach_versions (coach_id, game_id);



CREATE TRIGGER lock_game_coach_versions
BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE
ON core.game_coach_versions
FOR EACH STATEMENT
EXECUTE FUNCTION core.lock_match_changes();



CREATE FUNCTION core.validate_game_coaches(
    checked_game_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM core.game_coach_versions AS c
        WHERE c.game_id = checked_game_id
          AND NOT c.is_deleted
          AND NOT (
              COALESCE(
                  (
                      SELECT range_agg(
                          tstzrange(
                              gt.known_from,
                              gt.known_to,
                              '[)'
                          )
                      )
                      FROM core.game_team_versions AS gt
                      WHERE gt.game_id = c.game_id
                        AND gt.side = c.side
                        AND NOT gt.is_deleted
                  ),
                  '{}'::TSTZMULTIRANGE
              )
              @> tstzrange(c.known_from, c.known_to, '[)')
          )
    ) THEN
        RAISE EXCEPTION
            'Матч %: участие тренера выходит за период существования стороны',
            checked_game_id
            USING ERRCODE = '23514';
    END IF;
END;
$$;



CREATE FUNCTION core.check_changed_game_coaches()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM core.validate_game_coaches(OLD.game_id);
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM core.validate_game_coaches(NEW.game_id);
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER check_game_coach_versions
AFTER INSERT OR UPDATE OR DELETE
ON core.game_coach_versions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION core.check_changed_game_coaches();

CREATE CONSTRAINT TRIGGER check_side_coaches
AFTER INSERT OR UPDATE OR DELETE
ON core.game_team_versions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION core.check_changed_game_coaches();

COMMIT;