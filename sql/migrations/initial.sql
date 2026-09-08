BEGIN;

CREATE SCHEMA core;
CREATE SCHEMA ingest;


-- Источники и загрузки

CREATE TABLE ingest.data_sources (
    source_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_code TEXT NOT NULL UNIQUE,
    base_uri TEXT NOT NULL,
    priority INTEGER NOT NULL DEFAULT 100,

    CHECK (btrim(source_code) <> ''),
    CHECK (btrim(base_uri) <> ''),
    CHECK (priority >= 0)
);

CREATE TABLE ingest.ingestion_runs (
    run_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'running',
    loader_version TEXT NOT NULL,

    CHECK (btrim(loader_version) <> ''),
    CHECK (status IN ('running', 'success', 'partial', 'failed')),
    CHECK (finished_at IS NULL OR finished_at >= started_at),
    CHECK (
        (status = 'running' AND finished_at IS NULL)
        OR
        (status <> 'running' AND finished_at IS NOT NULL)
    )
);

CREATE TABLE ingest.raw_snapshots (
    raw_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_id BIGINT NOT NULL
        REFERENCES ingest.data_sources (source_id),
    run_id BIGINT NOT NULL
        REFERENCES ingest.ingestion_runs (run_id),
    request_uri TEXT NOT NULL,
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    http_status SMALLINT NOT NULL,
    payload_hash TEXT NOT NULL,
    payload_uri TEXT NOT NULL,

    CHECK (btrim(request_uri) <> ''),
    CHECK (http_status BETWEEN 100 AND 599),
    CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
    CHECK (btrim(payload_uri) <> '')
);


-- Основные сущности

CREATE TABLE core.seasons (
    season_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    start_year SMALLINT NOT NULL UNIQUE,
    status TEXT NOT NULL,

    CHECK (start_year >= 1917),
    CHECK (status IN ('scheduled', 'active', 'completed', 'cancelled'))
);

CREATE TABLE core.teams (
    team_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);

CREATE TABLE core.team_seasons (
    team_id BIGINT NOT NULL REFERENCES core.teams (team_id),
    season_id BIGINT NOT NULL REFERENCES core.seasons (season_id),

    PRIMARY KEY (team_id, season_id)
);

CREATE TABLE core.arenas (
    arena_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);

CREATE TABLE core.persons (
    person_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);

CREATE TABLE core.players (
    player_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id BIGINT NOT NULL UNIQUE
        REFERENCES core.persons (person_id)
);

CREATE TABLE core.coaches (
    coach_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id BIGINT NOT NULL UNIQUE
        REFERENCES core.persons (person_id)
);

CREATE TABLE core.coach_roles (
    role_code TEXT PRIMARY KEY,
    name TEXT NOT NULL,

    CHECK (btrim(role_code) <> ''),
    CHECK (btrim(name) <> '')
);

INSERT INTO core.coach_roles (role_code, name)
VALUES
    ('head', 'Главный тренер'),
    ('assistant', 'Помощник главного тренера'),
    ('goalie', 'Тренер вратарей');

COMMIT;