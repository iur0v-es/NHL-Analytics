BEGIN;



CREATE TABLE core.goals (
    goal_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);



CREATE TABLE core.goal_versions (
    version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    goal_id BIGINT NOT NULL
        REFERENCES core.goals (goal_id),
    game_id BIGINT NOT NULL
        REFERENCES core.games (game_id),
    scorer_player_id BIGINT NOT NULL
        REFERENCES core.players (player_id),

    period_no SMALLINT NOT NULL,
    elapsed_seconds INTEGER NOT NULL,

    known_from TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    known_to TIMESTAMPTZ NOT NULL DEFAULT 'infinity',
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),
    is_deleted BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (goal_id, known_from),

    CHECK (period_no > 0),
    CHECK (elapsed_seconds >= 0),
    CHECK (isfinite(known_from)),
    CHECK (known_from < known_to),

    EXCLUDE USING gist (
        goal_id WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
);



CREATE TABLE core.goal_assist_versions (
    version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    goal_id BIGINT NOT NULL
        REFERENCES core.goals (goal_id),
    player_id BIGINT NOT NULL
        REFERENCES core.players (player_id),

    assist_order SMALLINT NOT NULL,

    known_from TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    known_to TIMESTAMPTZ NOT NULL DEFAULT 'infinity',
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),
    is_deleted BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (goal_id, assist_order, known_from),

    CHECK (assist_order IN (1, 2)),
    CHECK (isfinite(known_from)),
    CHECK (known_from < known_to),

    EXCLUDE USING gist (
        goal_id WITH =,
        assist_order WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    ),

    EXCLUDE USING gist (
        goal_id WITH =,
        player_id WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
    WHERE (NOT is_deleted)
);



CREATE TABLE core.shootout_attempts (
    attempt_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);



CREATE TABLE core.shootout_attempt_versions (
    version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    attempt_id BIGINT NOT NULL
        REFERENCES core.shootout_attempts (attempt_id),
    game_id BIGINT NOT NULL
        REFERENCES core.games (game_id),
    shooter_player_id BIGINT NOT NULL
        REFERENCES core.players (player_id),
    goalie_player_id BIGINT
        REFERENCES core.players (player_id),

    attempt_no INTEGER NOT NULL,
    is_scored BOOLEAN NOT NULL,

    known_from TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    known_to TIMESTAMPTZ NOT NULL DEFAULT 'infinity',
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),
    is_deleted BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (attempt_id, known_from),

    CHECK (attempt_no > 0),
    CHECK (shooter_player_id <> goalie_player_id),
    CHECK (isfinite(known_from)),
    CHECK (known_from < known_to),

    EXCLUDE USING gist (
        attempt_id WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    ),

    EXCLUDE USING gist (
        game_id WITH =,
        attempt_no WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
    WHERE (NOT is_deleted)
);



CREATE INDEX goal_versions_game_idx
    ON core.goal_versions (game_id);


CREATE INDEX goal_versions_scorer_idx
    ON core.goal_versions (scorer_player_id, game_id);


CREATE INDEX goal_assist_versions_player_idx
    ON core.goal_assist_versions (player_id, goal_id);


CREATE INDEX shootout_attempt_versions_game_idx
    ON core.shootout_attempt_versions (game_id);

COMMIT;