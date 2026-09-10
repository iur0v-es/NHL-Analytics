BEGIN;

CREATE EXTENSION IF NOT EXISTS btree_gist;


-- Биографии людей

CREATE TABLE core.person_versions (
    version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id BIGINT NOT NULL
        REFERENCES core.persons (person_id),

    name TEXT NOT NULL,
    birth_date DATE,

    known_from TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    known_to TIMESTAMPTZ NOT NULL DEFAULT 'infinity',
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),
    is_deleted BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (person_id, known_from),

    CHECK (btrim(name) <> ''),
    CHECK (birth_date IS NULL OR isfinite(birth_date)),
    CHECK (isfinite(known_from)),
    CHECK (known_from < known_to),

    EXCLUDE USING gist (
        person_id WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
);


-- Постоянные идентификаторы исторических записей названий

CREATE TABLE core.team_names (
    team_name_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);

CREATE TABLE core.arena_names (
    arena_name_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);


-- Названия команд

CREATE TABLE core.team_name_versions (
    version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    team_name_id BIGINT NOT NULL
        REFERENCES core.team_names (team_name_id),
    team_id BIGINT NOT NULL
        REFERENCES core.teams (team_id),

    name TEXT NOT NULL,
    valid_from DATE,
    valid_to DATE,

    known_from TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    known_to TIMESTAMPTZ NOT NULL DEFAULT 'infinity',
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),
    is_deleted BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (team_name_id, known_from),

    CHECK (btrim(name) <> ''),
    CHECK (valid_from IS NULL OR isfinite(valid_from)),
    CHECK (valid_to IS NULL OR valid_to > '-infinity'::DATE),
    CHECK (valid_from < valid_to),
    CHECK (isfinite(known_from)),
    CHECK (known_from < known_to),

    EXCLUDE USING gist (
        team_name_id WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    ),

    EXCLUDE USING gist (
        team_id WITH =,
        daterange(valid_from, valid_to, '[)') WITH &&,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
    WHERE (
        NOT is_deleted
        AND valid_from IS NOT NULL
        AND valid_to IS NOT NULL
    )
);


-- Названия арен

CREATE TABLE core.arena_name_versions (
    version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    arena_name_id BIGINT NOT NULL
        REFERENCES core.arena_names (arena_name_id),
    arena_id BIGINT NOT NULL
        REFERENCES core.arenas (arena_id),

    name TEXT NOT NULL,
    valid_from DATE,
    valid_to DATE,

    known_from TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    known_to TIMESTAMPTZ NOT NULL DEFAULT 'infinity',
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),
    is_deleted BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (arena_name_id, known_from),

    CHECK (btrim(name) <> ''),
    CHECK (valid_from IS NULL OR isfinite(valid_from)),
    CHECK (valid_to IS NULL OR valid_to > '-infinity'::DATE),
    CHECK (valid_from < valid_to),
    CHECK (isfinite(known_from)),
    CHECK (known_from < known_to),

    EXCLUDE USING gist (
        arena_name_id WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    ),

    EXCLUDE USING gist (
        arena_id WITH =,
        daterange(valid_from, valid_to, '[)') WITH &&,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
    WHERE (
        NOT is_deleted
        AND valid_from IS NOT NULL
        AND valid_to IS NOT NULL
    )
);


-- Назначения тренеров

CREATE TABLE core.coach_assignments (
    assignment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);

CREATE TABLE core.coach_assignment_versions (
    version_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    assignment_id BIGINT NOT NULL
        REFERENCES core.coach_assignments (assignment_id),
    coach_id BIGINT NOT NULL
        REFERENCES core.coaches (coach_id),
    team_id BIGINT NOT NULL
        REFERENCES core.teams (team_id),
    role_code TEXT NOT NULL
        REFERENCES core.coach_roles (role_code),

    valid_from DATE,
    valid_to DATE,

    known_from TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    known_to TIMESTAMPTZ NOT NULL DEFAULT 'infinity',
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),
    is_deleted BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (assignment_id, known_from),

    CHECK (valid_from IS NULL OR isfinite(valid_from)),
    CHECK (valid_to IS NULL OR valid_to > '-infinity'::DATE),
    CHECK (valid_from < valid_to),
    CHECK (isfinite(known_from)),
    CHECK (known_from < known_to),

    EXCLUDE USING gist (
        assignment_id WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
);

COMMIT;