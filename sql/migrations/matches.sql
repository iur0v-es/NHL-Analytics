BEGIN;


CREATE TABLE core.games (
    game_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);



CREATE TABLE core.game_versions (
    game_version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    game_id BIGINT NOT NULL
        REFERENCES core.games (game_id),
    season_id BIGINT NOT NULL
        REFERENCES core.seasons (season_id),
    arena_id BIGINT
        REFERENCES core.arenas (arena_id),

    game_type_code TEXT NOT NULL,
    starts_at TIMESTAMPTZ,
    status TEXT NOT NULL,
    finish_type TEXT,

    known_from TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    known_to TIMESTAMPTZ NOT NULL DEFAULT 'infinity',
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),
    is_deleted BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (game_id, known_from),

    CHECK (game_type_code IN ('regular', 'playoff')),
    CHECK (
        status IN (
            'scheduled',
            'live',
            'finished',
            'postponed',
            'cancelled'
        )
    ),
    CHECK (
        finish_type IN ('regulation', 'overtime', 'shootout')
    ),
    CHECK (starts_at IS NULL OR isfinite(starts_at)),
    CHECK (isfinite(known_from)),
    CHECK (known_from < known_to),

    CHECK (
        status <> 'finished'
        OR (
            starts_at IS NOT NULL
            AND finish_type IS NOT NULL
        )
    ),

    CHECK (
        status = 'finished'
        OR finish_type IS NULL
    ),

    CHECK (
        game_type_code <> 'playoff'
        OR finish_type IS DISTINCT FROM 'shootout'
    ),

    EXCLUDE USING gist (
        game_id WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
);



CREATE TABLE core.game_team_versions (
    version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    game_id BIGINT NOT NULL
        REFERENCES core.games (game_id),
    team_id BIGINT NOT NULL
        REFERENCES core.teams (team_id),

    side TEXT NOT NULL,
    official_score SMALLINT,

    known_from TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    known_to TIMESTAMPTZ NOT NULL DEFAULT 'infinity',
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),
    is_deleted BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (game_id, side, known_from),

    CHECK (side IN ('home', 'away')),
    CHECK (official_score >= 0),
    CHECK (isfinite(known_from)),
    CHECK (known_from < known_to),

    EXCLUDE USING gist (
        game_id WITH =,
        side WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    ),

    EXCLUDE USING gist (
        game_id WITH =,
        team_id WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
    WHERE (NOT is_deleted)
);



CREATE INDEX game_versions_season_type_start_idx
    ON core.game_versions (
        season_id,
        game_type_code,
        starts_at
    )
    WHERE (
        known_to = 'infinity'::TIMESTAMPTZ
        AND NOT is_deleted
    );



CREATE INDEX game_team_versions_team_game_idx
    ON core.game_team_versions (team_id, game_id);

COMMIT;