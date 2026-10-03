BEGIN;



ALTER TABLE ingest.raw_snapshots
ADD CONSTRAINT raw_snapshots_raw_run_unique
UNIQUE (raw_id, run_id);



CREATE TABLE ingest.ingestion_issues (
    issue_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id BIGINT NOT NULL
        REFERENCES ingest.ingestion_runs (run_id),
    raw_id BIGINT,

    error_code TEXT NOT NULL,
    description TEXT NOT NULL,
    request_uri TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (raw_id, run_id)
        REFERENCES ingest.raw_snapshots (raw_id, run_id),

    CHECK (btrim(error_code) <> ''),
    CHECK (btrim(description) <> ''),
    CHECK (request_uri IS NULL OR btrim(request_uri) <> ''),
    CHECK (isfinite(created_at))
);



CREATE TABLE ingest.ingestion_checkpoints (
    source_id BIGINT NOT NULL
        REFERENCES ingest.data_sources (source_id),
    stream_code TEXT NOT NULL,
    partition_key TEXT NOT NULL,
    cursor_value TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (source_id, stream_code, partition_key),

    CHECK (btrim(stream_code) <> ''),
    CHECK (btrim(partition_key) <> ''),
    CHECK (btrim(cursor_value) <> ''),
    CHECK (isfinite(updated_at))
);



CREATE TABLE ingest.game_coverage_versions (
    coverage_version_id BIGINT
        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    game_id BIGINT NOT NULL
        REFERENCES core.games (game_id),

    dataset_code TEXT NOT NULL,
    coverage_status TEXT NOT NULL,

    known_from TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    known_to TIMESTAMPTZ NOT NULL DEFAULT 'infinity',
    raw_id BIGINT NOT NULL
        REFERENCES ingest.raw_snapshots (raw_id),
    is_deleted BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (game_id, dataset_code, known_from),

    CHECK (
        dataset_code IN (
            'metadata',
            'results',
            'events',
            'roster',
            'player_stats',
            'coaches',
            'shifts'
        )
    ),

    CHECK (
        coverage_status IN (
            'unknown',
            'unavailable',
            'partial',
            'complete',
            'conflict'
        )
    ),

    CHECK (isfinite(known_from)),
    CHECK (known_from < known_to),

    EXCLUDE USING gist (
        game_id WITH =,
        dataset_code WITH =,
        tstzrange(known_from, known_to, '[)') WITH &&
    )
);



CREATE INDEX ingestion_issues_run_created_idx
    ON ingest.ingestion_issues (run_id, created_at);



CREATE INDEX game_coverage_current_status_idx
    ON ingest.game_coverage_versions (
        dataset_code,
        coverage_status,
        game_id
    )
    WHERE (
        known_to = 'infinity'::TIMESTAMPTZ
        AND NOT is_deleted
    );

COMMIT;