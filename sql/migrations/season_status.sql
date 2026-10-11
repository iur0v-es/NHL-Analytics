BEGIN;

ALTER TABLE core.seasons DROP CONSTRAINT seasons_status_check;
ALTER TABLE core.seasons ADD CONSTRAINT seasons_status_check
CHECK (status IN ('unknown', 'scheduled', 'active', 'completed', 'cancelled'));
ALTER TABLE core.seasons ALTER COLUMN status SET DEFAULT 'unknown';

COMMIT;
