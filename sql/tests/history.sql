BEGIN;

DO $$
DECLARE
    test_source_id BIGINT;
    test_run_id BIGINT;
    test_raw_id BIGINT;
    test_person_id BIGINT;
    actual_name TEXT;
BEGIN
    INSERT INTO ingest.data_sources (
        source_code,
        base_uri
    )
    VALUES (
        'history_test_' || txid_current(),
        'https://example.invalid'
    )
    RETURNING source_id INTO test_source_id;

    INSERT INTO ingest.ingestion_runs (loader_version)
    VALUES ('history-test')
    RETURNING run_id INTO test_run_id;

    INSERT INTO ingest.raw_snapshots (
        source_id,
        run_id,
        request_uri,
        http_status,
        payload_hash,
        payload_uri
    )
    VALUES (
        test_source_id,
        test_run_id,
        'https://example.invalid/person',
        200,
        repeat('0', 64),
        'test://person.json'
    )
    RETURNING raw_id INTO test_raw_id;

    INSERT INTO core.persons DEFAULT VALUES
    RETURNING person_id INTO test_person_id;


    INSERT INTO core.person_versions (
        person_id,
        name,
        known_from,
        raw_id
    )
    VALUES (
        test_person_id,
        'Первоначальное имя',
        '2026-01-01 00:00:00+00',
        test_raw_id
    );

    RAISE NOTICE 'OK: первая версия добавлена';


    BEGIN
        INSERT INTO core.person_versions (
            person_id,
            name,
            known_from,
            raw_id
        )
        VALUES (
            test_person_id,
            'Пересекающаяся версия',
            '2026-02-01 00:00:00+00',
            test_raw_id
        );

        RAISE EXCEPTION 'FAIL: пересечение версий разрешено';
    EXCEPTION
        WHEN exclusion_violation THEN
            RAISE NOTICE 'OK: пересечение версий запрещено';
    END;


    UPDATE core.person_versions
    SET known_to = '2026-02-01 00:00:00+00'
    WHERE person_id = test_person_id
      AND known_to = 'infinity'::TIMESTAMPTZ;

    INSERT INTO core.person_versions (
        person_id,
        name,
        known_from,
        raw_id
    )
    VALUES (
        test_person_id,
        'Исправленное имя',
        '2026-02-01 00:00:00+00',
        test_raw_id
    );

    RAISE NOTICE 'OK: исправление сохранено';


    SELECT name INTO STRICT actual_name
    FROM core.person_versions
    WHERE person_id = test_person_id
      AND known_from <= '2026-01-15 00:00:00+00'
      AND '2026-01-15 00:00:00+00' < known_to;

    IF actual_name IS DISTINCT FROM 'Первоначальное имя' THEN
        RAISE EXCEPTION 'FAIL: старая версия потеряна';
    END IF;

    RAISE NOTICE 'OK: старая версия сохранена';


    SELECT name INTO STRICT actual_name
    FROM core.person_versions
    WHERE person_id = test_person_id
      AND known_from <= '2026-02-01 00:00:00+00'
      AND '2026-02-01 00:00:00+00' < known_to;

    IF actual_name IS DISTINCT FROM 'Исправленное имя' THEN
        RAISE EXCEPTION 'FAIL: неверная версия на границе';
    END IF;

    RAISE NOTICE 'OK: граница интервалов работает правильно';
END;
$$;

ROLLBACK;