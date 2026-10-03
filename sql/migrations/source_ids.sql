BEGIN;



CREATE TABLE ingest.team_source_ids (
    source_id BIGINT NOT NULL
        REFERENCES ingest.data_sources (source_id),
    external_id TEXT NOT NULL,
    team_id BIGINT NOT NULL
        REFERENCES core.teams (team_id),

    PRIMARY KEY (source_id, external_id),

    CHECK (btrim(external_id) <> '')
);



CREATE TABLE ingest.player_source_ids (
    source_id BIGINT NOT NULL
        REFERENCES ingest.data_sources (source_id),
    external_id TEXT NOT NULL,
    player_id BIGINT NOT NULL
        REFERENCES core.players (player_id),

    PRIMARY KEY (source_id, external_id),

    CHECK (btrim(external_id) <> '')
);



CREATE TABLE ingest.coach_source_ids (
    source_id BIGINT NOT NULL
        REFERENCES ingest.data_sources (source_id),
    external_id TEXT NOT NULL,
    coach_id BIGINT NOT NULL
        REFERENCES core.coaches (coach_id),

    PRIMARY KEY (source_id, external_id),

    CHECK (btrim(external_id) <> '')
);



CREATE TABLE ingest.game_source_ids (
    source_id BIGINT NOT NULL
        REFERENCES ingest.data_sources (source_id),
    external_id TEXT NOT NULL,
    game_id BIGINT NOT NULL
        REFERENCES core.games (game_id),

    PRIMARY KEY (source_id, external_id),

    CHECK (btrim(external_id) <> '')
);



CREATE TABLE ingest.arena_source_ids (
    source_id BIGINT NOT NULL
        REFERENCES ingest.data_sources (source_id),
    external_id TEXT NOT NULL,
    arena_id BIGINT NOT NULL
        REFERENCES core.arenas (arena_id),

    PRIMARY KEY (source_id, external_id),

    CHECK (btrim(external_id) <> '')
);



CREATE TABLE ingest.goal_source_ids (
    source_id BIGINT NOT NULL
        REFERENCES ingest.data_sources (source_id),
    game_id BIGINT NOT NULL
        REFERENCES core.games (game_id),
    external_id TEXT NOT NULL,
    goal_id BIGINT NOT NULL
        REFERENCES core.goals (goal_id),

    PRIMARY KEY (source_id, game_id, external_id),

    CHECK (btrim(external_id) <> '')
);



CREATE TABLE ingest.shootout_attempt_source_ids (
    source_id BIGINT NOT NULL
        REFERENCES ingest.data_sources (source_id),
    game_id BIGINT NOT NULL
        REFERENCES core.games (game_id),
    external_id TEXT NOT NULL,
    attempt_id BIGINT NOT NULL
        REFERENCES core.shootout_attempts (attempt_id),

    PRIMARY KEY (source_id, game_id, external_id),

    CHECK (btrim(external_id) <> '')
);

COMMIT;