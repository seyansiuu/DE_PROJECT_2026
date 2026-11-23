
BEGIN;
SET LOCAL search_path = netflix, public;
LOCK TABLE netflix.viewing_activity IN ACCESS EXCLUSIVE MODE;

DO $$
BEGIN
    IF to_regclass('netflix.viewing_activity_pre_cp4') IS NOT NULL
       OR to_regclass('netflix.viewing_activity_cp4_new') IS NOT NULL
       OR to_regclass('netflix.viewing_activity_id_registry') IS NOT NULL THEN
        RAISE EXCEPTION 'CP4 migration objects already exist; inspect and recover before retrying';
    END IF;
END $$;

CREATE TABLE netflix.viewing_activity_id_registry (
    view_id INTEGER PRIMARY KEY
);
INSERT INTO netflix.viewing_activity_id_registry(view_id)
SELECT view_id FROM netflix.viewing_activity;

CREATE TABLE netflix.viewing_activity_cp4_new (
    view_id INTEGER NOT NULL,
    profile_id INTEGER NOT NULL REFERENCES netflix.profiles(profile_id),
    title_id INTEGER NOT NULL REFERENCES netflix.titles(title_id),
    episode_id INTEGER REFERENCES netflix.episodes(episode_id),
    started_at TIMESTAMPTZ NOT NULL,
    duration_watched_sec INTEGER NOT NULL CHECK (duration_watched_sec >= 0),
    device_type VARCHAR(30) NOT NULL,
    completed BOOLEAN NOT NULL,
    PRIMARY KEY (view_id, started_at)
) PARTITION BY RANGE (started_at);


DO $$
DECLARE
    lo timestamptz;
    hi timestamptz;
    month_start date;
    month_end date;
    range_end date;
    part_name text;
BEGIN
    SELECT min(started_at), max(started_at)
      INTO lo, hi FROM netflix.viewing_activity;
    IF lo IS NULL THEN
        lo := date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
        hi := lo;
    END IF;
    month_start := date_trunc('month', lo AT TIME ZONE 'UTC')::date;
    range_end := (date_trunc('month', hi AT TIME ZONE 'UTC') + interval '13 months')::date;
    WHILE month_start < range_end LOOP
        part_name := 'viewing_activity_cp4_' || to_char(month_start, 'YYYYMM');
        month_end := (month_start + interval '1 month')::date;
        EXECUTE format(
            'CREATE TABLE netflix.%I PARTITION OF netflix.viewing_activity_cp4_new FOR VALUES FROM (%L::timestamptz) TO (%L::timestamptz)',
            part_name, month_start::text || ' 00:00:00+00', month_end::text || ' 00:00:00+00'
        );
        month_start := month_end;
    END LOOP;
END $$;
CREATE TABLE netflix.viewing_activity_cp4_default
    PARTITION OF netflix.viewing_activity_cp4_new DEFAULT;


CREATE INDEX viewing_activity_cp4_started_idx
    ON netflix.viewing_activity_cp4_new (started_at DESC);
CREATE INDEX viewing_activity_cp4_profile_progress_idx
    ON netflix.viewing_activity_cp4_new
       (profile_id, completed, title_id, started_at DESC);
CREATE INDEX viewing_activity_cp4_device_time_idx
    ON netflix.viewing_activity_cp4_new (device_type, started_at);

INSERT INTO netflix.viewing_activity_cp4_new
    (view_id, profile_id, title_id, episode_id, started_at,
     duration_watched_sec, device_type, completed)
SELECT view_id, profile_id, title_id, episode_id, started_at,
       duration_watched_sec, device_type, completed
FROM netflix.viewing_activity;

-- Validate before cutover; any discrepancy aborts the transaction.
DO $$
DECLARE old_count bigint;
        new_count bigint;
BEGIN
    SELECT count(*) INTO old_count FROM netflix.viewing_activity;
    SELECT count(*) INTO new_count FROM netflix.viewing_activity_cp4_new;
    IF old_count <> new_count THEN
        RAISE EXCEPTION 'CP4 copy row-count mismatch: old %, new %', old_count, new_count;
    END IF;
END $$;

CREATE FUNCTION netflix.reserve_viewing_activity_id()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.view_id <> OLD.view_id THEN
        RAISE EXCEPTION 'view_id is immutable';
    END IF;
    IF TG_OP = 'INSERT' THEN
        INSERT INTO netflix.viewing_activity_id_registry(view_id)
        VALUES (NEW.view_id);
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER viewing_activity_reserve_id
BEFORE INSERT OR UPDATE OF view_id ON netflix.viewing_activity_cp4_new
FOR EACH ROW EXECUTE FUNCTION netflix.reserve_viewing_activity_id();


ALTER TABLE netflix.viewing_activity RENAME TO viewing_activity_pre_cp4;
ALTER TABLE netflix.viewing_activity_cp4_new RENAME TO viewing_activity;
COMMIT;

SET search_path = netflix, public;
EXPLAIN (COSTS OFF)
SELECT count(*)
FROM netflix.viewing_activity
WHERE started_at >= TIMESTAMPTZ '2026-06-30 00:00:00+00'
  AND started_at <  TIMESTAMPTZ '2026-07-01 00:00:00+00';
