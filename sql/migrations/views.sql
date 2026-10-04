BEGIN;

CREATE VIEW core.v_current_persons AS
SELECT person_id, name, birth_date
FROM core.person_versions
WHERE known_to = 'infinity'::TIMESTAMPTZ AND NOT is_deleted;

CREATE VIEW core.v_current_team_names AS
SELECT team_name_id, team_id, name, valid_from, valid_to
FROM core.team_name_versions
WHERE known_to = 'infinity'::TIMESTAMPTZ AND NOT is_deleted;

CREATE VIEW core.v_current_games AS
SELECT game_version_id, game_id, season_id, arena_id,
       game_type_code, starts_at, status, finish_type
FROM core.game_versions
WHERE known_to = 'infinity'::TIMESTAMPTZ AND NOT is_deleted;

CREATE VIEW core.v_current_game_teams AS
SELECT game_id, team_id, side, official_score
FROM core.game_team_versions
WHERE known_to = 'infinity'::TIMESTAMPTZ AND NOT is_deleted;

CREATE VIEW core.v_current_game_players AS
SELECT game_id, player_id, side, jersey_number
FROM core.game_player_versions
WHERE known_to = 'infinity'::TIMESTAMPTZ AND NOT is_deleted;

CREATE VIEW core.v_current_goals AS
SELECT goal_id, game_id, scorer_player_id, period_no, elapsed_seconds
FROM core.goal_versions
WHERE known_to = 'infinity'::TIMESTAMPTZ AND NOT is_deleted;

CREATE VIEW core.v_current_goal_assists AS
SELECT goal_id, player_id, assist_order
FROM core.goal_assist_versions
WHERE known_to = 'infinity'::TIMESTAMPTZ AND NOT is_deleted;

CREATE VIEW core.v_current_game_coaches AS
SELECT game_id, side, role_code, coach_id
FROM core.game_coach_versions
WHERE known_to = 'infinity'::TIMESTAMPTZ AND NOT is_deleted;

CREATE VIEW ingest.v_current_game_coverage AS
SELECT game_id, dataset_code, coverage_status
FROM ingest.game_coverage_versions
WHERE known_to = 'infinity'::TIMESTAMPTZ AND NOT is_deleted;



CREATE VIEW core.v_game_results AS
SELECT
    g.game_id,
    g.season_id,
    s.start_year,
    g.game_type_code,
    g.starts_at,
    g.status,
    g.finish_type,
    h.team_id AS home_team_id,
    hn.name AS home_team_name,
    a.team_id AS away_team_id,
    an.name AS away_team_name,
    h.official_score AS home_score,
    a.official_score AS away_score,
    CASE
        WHEN g.status = 'finished' AND h.official_score > a.official_score
            THEN h.team_id
        WHEN g.status = 'finished' AND a.official_score > h.official_score
            THEN a.team_id
        ELSE NULL
    END AS winner_team_id,
    COALESCE(rc.coverage_status, 'unknown') AS result_coverage,
    COALESCE(ec.coverage_status, 'unknown') AS event_coverage
FROM core.v_current_games AS g
JOIN core.seasons AS s ON s.season_id = g.season_id
JOIN core.v_current_game_teams AS h
  ON h.game_id = g.game_id AND h.side = 'home'
JOIN core.v_current_game_teams AS a
  ON a.game_id = g.game_id AND a.side = 'away'
LEFT JOIN core.v_current_team_names AS hn
  ON hn.team_id = h.team_id
 AND hn.valid_from <= (g.starts_at AT TIME ZONE 'UTC')::DATE
 AND (g.starts_at AT TIME ZONE 'UTC')::DATE < hn.valid_to
LEFT JOIN core.v_current_team_names AS an
  ON an.team_id = a.team_id
 AND an.valid_from <= (g.starts_at AT TIME ZONE 'UTC')::DATE
 AND (g.starts_at AT TIME ZONE 'UTC')::DATE < an.valid_to
LEFT JOIN ingest.v_current_game_coverage AS rc
  ON rc.game_id = g.game_id AND rc.dataset_code = 'results'
LEFT JOIN ingest.v_current_game_coverage AS ec
  ON ec.game_id = g.game_id AND ec.dataset_code = 'events';


CREATE VIEW core.v_goals_enriched AS
SELECT
    g.goal_id,
    g.game_id,
    m.season_id,
    m.start_year,
    m.game_type_code,
    m.starts_at,
    g.period_no,
    g.elapsed_seconds,
    g.scorer_player_id,
    p.name AS scorer_name,
    gp.side,
    CASE gp.side
        WHEN 'home' THEN m.home_team_id
        WHEN 'away' THEN m.away_team_id
    END AS team_id,
    CASE gp.side
        WHEN 'home' THEN m.home_team_name
        WHEN 'away' THEN m.away_team_name
    END AS team_name,
    m.event_coverage
FROM core.v_current_goals AS g
JOIN core.v_game_results AS m ON m.game_id = g.game_id
JOIN core.v_current_game_players AS gp
  ON gp.game_id = g.game_id AND gp.player_id = g.scorer_player_id
JOIN core.players AS pl ON pl.player_id = g.scorer_player_id
LEFT JOIN core.v_current_persons AS p ON p.person_id = pl.person_id;



CREATE VIEW core.v_player_season_scoring AS
WITH goals_per_game AS (
    SELECT game_id, scorer_player_id AS player_id, count(*) AS goals
    FROM core.v_current_goals
    GROUP BY game_id, scorer_player_id
), assists_per_game AS (
    SELECT g.game_id, a.player_id, count(*) AS assists
    FROM core.v_current_goal_assists AS a
    JOIN core.v_current_goals AS g ON g.goal_id = a.goal_id
    GROUP BY g.game_id, a.player_id
), totals AS (
    SELECT
        m.season_id,
        m.start_year,
        m.game_type_code,
        CASE gp.side
            WHEN 'home' THEN m.home_team_id
            WHEN 'away' THEN m.away_team_id
        END AS team_id,
        gp.player_id,
        count(*) AS games_played,
        count(*) FILTER (WHERE m.event_coverage = 'complete')
            AS games_with_complete_events,
        sum(COALESCE(g.goals, 0)) AS observed_goals,
        sum(COALESCE(a.assists, 0)) AS observed_assists,
        CASE WHEN bool_and(m.event_coverage = 'complete')
            THEN sum(COALESCE(g.goals, 0)) END AS goals,
        CASE WHEN bool_and(m.event_coverage = 'complete')
            THEN sum(COALESCE(a.assists, 0)) END AS assists
    FROM core.v_current_game_players AS gp
    JOIN core.v_game_results AS m ON m.game_id = gp.game_id
    LEFT JOIN goals_per_game AS g
      ON g.game_id = gp.game_id AND g.player_id = gp.player_id
    LEFT JOIN assists_per_game AS a
      ON a.game_id = gp.game_id AND a.player_id = gp.player_id
    WHERE m.status = 'finished'
    GROUP BY m.season_id, m.start_year, m.game_type_code,
             CASE gp.side
                 WHEN 'home' THEN m.home_team_id
                 WHEN 'away' THEN m.away_team_id
             END,
             gp.player_id
)
SELECT t.*, p.name AS player_name, t.goals + t.assists AS points
FROM totals AS t
JOIN core.players AS pl ON pl.player_id = t.player_id
LEFT JOIN core.v_current_persons AS p ON p.person_id = pl.person_id;


CREATE VIEW core.v_player_latest_roster_observations AS
WITH latest AS (
    SELECT DISTINCT ON (r.team_id)
        r.snapshot_id, r.team_id, r.observed_at
    FROM core.roster_snapshots AS r
    JOIN ingest.raw_snapshots AS raw ON raw.raw_id = r.raw_id
    JOIN ingest.data_sources AS ds ON ds.source_id = raw.source_id
    ORDER BY r.team_id, r.observed_at DESC, ds.priority, r.snapshot_id DESC
)
SELECT l.team_id, l.snapshot_id, l.observed_at,
       rp.player_id, p.name AS player_name, rp.jersey_number
FROM latest AS l
LEFT JOIN core.roster_snapshot_players AS rp ON rp.snapshot_id = l.snapshot_id
LEFT JOIN core.players AS pl ON pl.player_id = rp.player_id
LEFT JOIN core.v_current_persons AS p ON p.person_id = pl.person_id;


CREATE VIEW core.v_head_coaches_by_game AS
SELECT c.game_id, c.side, gt.team_id, c.coach_id, p.name AS coach_name
FROM core.v_current_game_coaches AS c
JOIN core.v_current_game_teams AS gt
  ON gt.game_id = c.game_id AND gt.side = c.side
JOIN core.coaches AS co ON co.coach_id = c.coach_id
LEFT JOIN core.v_current_persons AS p ON p.person_id = co.person_id
WHERE c.role_code = 'head';

COMMIT;
