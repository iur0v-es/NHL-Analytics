BEGIN;



CREATE TABLE core.roster_snapshots (
    snapshot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    team_id BIGINT NOT NULL
        REFERENCES core.teams (team_id),
    observed_at TIMESTAMPTZ NOT NULL,
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),

    UNIQUE (team_id, raw_id),

    CHECK (isfinite(observed_at))
);



CREATE TABLE core.roster_snapshot_players (
    snapshot_id BIGINT NOT NULL
        REFERENCES core.roster_snapshots (snapshot_id),
    player_id BIGINT NOT NULL
        REFERENCES core.players (player_id),
    jersey_number SMALLINT,

    PRIMARY KEY (snapshot_id, player_id),

    CHECK (jersey_number BETWEEN 0 AND 99)
);



CREATE TABLE core.game_player_versions (
    version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    game_id BIGINT NOT NULL
        REFERENCES core.games (game_id),
    player_id BIGINT NOT NULL
        REFERENCES core.players (player_id),

    side TEXT NOT NULL,
    jersey_number SMALLINT,

    known_from TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    known_to TIMESTAMPTZ NOT NULL DEFAULT 'infinity',
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),
    is_deleted BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (game_id, player_id, known_from),

    CHECK (side IN ('home', 'away')),
    CHECK (jersey_number BETWEEN 0 AND 99),
    CHECK (isfinite(known_from)),
    CHECK (known_from < known_to),

    EXCLUDE USING gist (
        game_id WITH =,
        player_id WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
);



CREATE INDEX roster_snapshots_team_observed_idx
    ON core.roster_snapshots (team_id, observed_at DESC);


CREATE INDEX roster_snapshot_players_player_idx
    ON core.roster_snapshot_players (player_id, snapshot_id);


CREATE INDEX game_player_versions_player_game_idx
    ON core.game_player_versions (player_id, game_id);



CREATE TRIGGER lock_game_player_versions
BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE
ON core.game_player_versions
FOR EACH STATEMENT
EXECUTE FUNCTION core.lock_match_changes();



CREATE FUNCTION core.validate_game_players(
    checked_game_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM core.game_player_versions AS gp
        WHERE gp.game_id = checked_game_id
          AND NOT gp.is_deleted
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
                      WHERE gt.game_id = gp.game_id
                        AND gt.side = gp.side
                        AND NOT gt.is_deleted
                  ),
                  '{}'::TSTZMULTIRANGE
              )
              @> tstzrange(gp.known_from, gp.known_to, '[)')
          )
    ) THEN
        RAISE EXCEPTION
            'Матч %: участие игрока выходит за период существования стороны',
            checked_game_id;
    END IF;
END;
$$;



CREATE FUNCTION core.check_changed_game_players()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM core.validate_game_players(OLD.game_id);
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM core.validate_game_players(NEW.game_id);
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER check_game_player_versions
AFTER INSERT OR UPDATE OR DELETE
ON core.game_player_versions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION core.check_changed_game_players();

CREATE CONSTRAINT TRIGGER check_side_players
AFTER INSERT OR UPDATE OR DELETE
ON core.game_team_versions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION core.check_changed_game_players();

COMMIT;