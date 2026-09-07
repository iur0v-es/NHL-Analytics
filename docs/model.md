# NHL Analytics — таблицы и ограничения

## 1. Матчи, сезоны и команды

| Таблица | Назначение и основные поля | Ключи |
|---|---|---|
| `seasons` | Сезон: `season_id`, `start_year`, `status` | PK `season_id`; UNIQUE `start_year` |
| `teams` | Постоянный идентификатор команды: `team_id` | PK `team_id` |
| `team_seasons` | Участие команды в сезоне: `team_id`, `season_id` | PK `(team_id, season_id)`; FK на `teams`, `seasons` |
| `arenas` | Постоянный идентификатор арены: `arena_id` | PK `arena_id` |
| `games` | Постоянный идентификатор матча: `game_id` | PK `game_id` |
| `game_versions` | Характеристики матча: `game_version_id`, `game_id`, `season_id`, `game_type_code`, `arena_id`, `starts_at`, `status`, `finish_type` | PK `game_version_id`; FK на `games`, `seasons`, `arenas` |
| `game_team_versions` | Сторона матча: `version_id`, `game_id`, `side`, `team_id`, `official_score` | PK `version_id`; FK на `games`, `teams`; логический ключ `(game_id, side)` |

**Ограничения:**

- `game_type_code NOT NULL`, допустимы `regular`, `playoff`.
- `side NOT NULL`, допустимы `home`, `away`.
- В одном временном срезе у матча ровно две стороны с разными командами; каждая команда участвует в соответствующем сезоне.
- `official_score >= 0`; NULL — результат ещё неизвестен.
- `finish_type`: `regulation`, `overtime`, `shootout` или NULL.
- `arena_id`, `starts_at` могут быть NULL до получения подтверждённых данных; для завершённого матча время начала и оба счёта обязательны.

## 2. Люди, составы и участие в матчах

| Таблица | Назначение и основные поля | Ключи |
|---|---|---|
| `persons` | Постоянный идентификатор человека: `person_id` | PK `person_id` |
| `person_versions` | Биография: `version_id`, `person_id`, `name`, `birth_date` | PK `version_id`; FK на `persons` |
| `players` | Роль игрока: `player_id`, `person_id` | PK `player_id`; FK и UNIQUE `person_id` |
| `coaches` | Роль тренера: `coach_id`, `person_id` | PK `coach_id`; FK и UNIQUE `person_id` |
| `roster_snapshots` | Наблюдение состава: `snapshot_id`, `team_id`, `observed_at`, `raw_id` | PK `snapshot_id`; FK на `teams`, `raw_snapshots` |
| `roster_snapshot_players` | Игрок в составе: `snapshot_id`, `player_id`, `jersey_number` | PK `(snapshot_id, player_id)`; FK на `roster_snapshots`, `players` |
| `game_player_versions` | Участник матча: `version_id`, `game_id`, `player_id`, `side`, `jersey_number` | PK `version_id`; FK на `games`, `players`; логический ключ `(game_id, player_id)` |

**Ограничения:**

- `name NOT NULL`; `birth_date` может быть NULL.
- Один человек может одновременно иметь записи в `players` и `coaches`.
- `team_id`, `observed_at`, `raw_id` снимка состава обязательны.
- Один игрок встречается в одном снимке не более одного раза.
- В одном временном срезе игрок представляет только одну сторону матча; эта сторона должна существовать.
- `jersey_number` может быть NULL; известное значение находится в диапазоне 0–99.

## 3. Голы, передачи и буллиты

| Таблица | Назначение и основные поля | Ключи |
|---|---|---|
| `goals` | Постоянный идентификатор гола: `goal_id` | PK `goal_id` |
| `goal_versions` | Гол игрового времени: `version_id`, `goal_id`, `game_id`, `scorer_player_id`, `period_no`, `elapsed_seconds` | PK `version_id`; FK на `goals`, `games`, `players` |
| `goal_assist_versions` | Передача: `version_id`, `goal_id`, `assist_order`, `player_id` | PK `version_id`; FK на `goals`, `players`; логический ключ `(goal_id, assist_order)` |
| `shootout_attempts` | Постоянный идентификатор попытки: `attempt_id` | PK `attempt_id` |
| `shootout_attempt_versions` | Послематчевый буллит: `version_id`, `attempt_id`, `game_id`, `attempt_no`, `shooter_player_id`, `goalie_player_id`, `is_scored` | PK `version_id`; FK на `shootout_attempts`, `games`, `players` |

**Ограничения:**

- Автор гола, ассистенты, исполнитель буллита и известный вратарь должны участвовать в соответствующем матче на выбранном срезе.
- `assist_order IN (1, 2)`; не более двух разных ассистентов при одном голе; автор не является ассистентом.
- Ассистенты представляют сторону автора; вратарь буллита — противоположную сторону исполнителя.
- `period_no > 0`, `elapsed_seconds >= 0`; время считается от начала периода и ограничивается его продолжительностью.
- `attempt_no > 0`; пара `(game_id, attempt_no)` уникальна на одном временном срезе.
- `goalie_player_id` может быть NULL; `is_scored` — обязательное логическое значение.
- Послематчевые буллиты не записываются в `goals`.

## 4. Названия и назначения тренеров

| Таблица | Назначение и основные поля | Ключи |
|---|---|---|
| `team_name_versions` | Название команды: `version_id`, `team_name_id`, `team_id`, `name`, `valid_from`, `valid_to` | PK `version_id`; FK на `teams`; логический ключ `team_name_id` |
| `arena_name_versions` | Название арены: `version_id`, `arena_name_id`, `arena_id`, `name`, `valid_from`, `valid_to` | PK `version_id`; FK на `arenas`; логический ключ `arena_name_id` |
| `coach_roles` | Роль тренера: `role_code`, `name` | PK `role_code` |
| `coach_assignments` | Постоянный идентификатор назначения: `assignment_id` | PK `assignment_id` |
| `coach_assignment_versions` | Назначение: `version_id`, `assignment_id`, `coach_id`, `team_id`, `role_code`, `valid_from`, `valid_to` | PK `version_id`; FK на `coach_assignments`, `coaches`, `teams`, `coach_roles` |
| `game_coach_versions` | Тренер стороны матча: `version_id`, `game_id`, `side`, `role_code`, `coach_id` | PK `version_id`; FK на `games`, `coaches`, `coach_roles`; логический ключ `(game_id, side, role_code, coach_id)` |

**Ограничения:**

- `name NOT NULL`; для названий команд и арен не устанавливается глобальная уникальность.
- В справочнике ролей предусмотрено значение `head` — главный тренер.
- `valid_from < valid_to`, если обе границы известны; интервал `[valid_from, valid_to)`.
- NULL у границы означает неизвестную дату; бесконечная верхняя граница — подтверждённый открытый период.
- На одном срезе подтверждённые интервалы названия одного объекта не пересекаются.
- У стороны матча не более одного тренера в роли `head`; для помощников допустимо несколько тренеров.
- Сторона, указанная в `game_coach_versions`, должна существовать на соответствующем срезе.

## 5. Общие поля и ограничения версий

| Поле | Тип | Ограничение |
|---|---|---|
| `version_id` / `game_version_id` | BIGINT | PK |
| `known_from` | TIMESTAMPTZ | NOT NULL |
| `known_to` | TIMESTAMPTZ | NOT NULL; DEFAULT `infinity`; больше `known_from` |
| `raw_id` | BIGINT | NOT NULL; FK → `raw_snapshots.raw_id` |
| `is_deleted` | BOOLEAN | NOT NULL; DEFAULT false |

- Общие поля относятся ко всем перечисленным таблицам версий; в `game_coverage_versions` первичный ключ называется `coverage_version_id`.
- Для версий с постоянным ID логический ключ — этот ID; для остальных логический ключ указан в таблице. `team_name_id` и `arena_name_id` обозначают постоянные идентификаторы исторических записей названий.
- Первичные ключи и составляющие логического ключа обязательны. Ссылки на матч, человека, команду, роль и сезон обязательны, кроме явно указанных допускающих NULL полей.
- Версии одного логического факта не пересекаются по интервалу `[known_from, known_to)`; сочетание логического ключа и `known_from` уникально.
- Несколько исторических названий одного объекта допустимы, но их подтверждённые периоды действия на одном срезе не пересекаются.
- Связи участников, сторон, голов и передач согласованы на одном временном срезе. Физические FK проверяют постоянные ID, временные связи — отдельные ограничения.
- Удаление объекта не уничтожает его предыдущие версии.

## 6. Источники и учёт загрузки

| Таблица | Назначение и основные поля | Ключи |
|---|---|---|
| `data_sources` | Источник: `source_id`, `source_code`, `base_uri`, `priority` | PK `source_id`; UNIQUE `source_code` |
| `ingestion_runs` | Запуск: `run_id`, `started_at`, `finished_at`, `status`, `loader_version` | PK `run_id` |
| `raw_snapshots` | Исходный ответ: `raw_id`, `source_id`, `run_id`, `request_uri`, `fetched_at`, `http_status`, `payload_hash`, `payload_uri` | PK `raw_id`; FK на `data_sources`, `ingestion_runs` |
| `ingestion_issues` | Ошибка: `issue_id`, `run_id`, `raw_id`, `error_code`, `description`, `created_at` | PK `issue_id`; FK на `ingestion_runs`, `raw_snapshots` |
| `ingestion_checkpoints` | Прогресс: `source_id`, `stream_code`, `partition_key`, `cursor_value`, `updated_at` | PK `(source_id, stream_code, partition_key)`; FK на `data_sources` |
| `game_coverage_versions` | Полнота данных матча: `coverage_version_id`, `game_id`, `dataset_code`, `coverage_status` и общие поля версий | PK `coverage_version_id`; FK на `games`; логический ключ `(game_id, dataset_code)` |

**Ограничения:**

- `source_code`, `base_uri`, `priority` обязательны; меньшее значение `priority` означает более высокий приоритет.
- `status IN ('running', 'success', 'partial', 'failed')`.
- `finished_at >= started_at`, если время завершения известно; для завершённого запуска оно обязательно.
- У исходного ответа обязательны источник, запуск, адрес запроса, время получения, хеш и ссылка на сохранённое содержимое.
- `http_status` находится в диапазоне 100–599; транспортная ошибка без ответа фиксируется в `ingestion_issues`.
- `ingestion_issues.raw_id` может быть NULL; если ответ указан, его `run_id` совпадает с запуском ошибки.
- `dataset_code`: `metadata`, `results`, `events`, `roster`, `player_stats`, `coaches`, `shifts`.
- `coverage_status`: `unknown`, `unavailable`, `partial`, `complete`, `conflict`.

## 7. Внешние идентификаторы

| Таблица | Поля | Ключи |
|---|---|---|
| `team_source_ids` | `source_id`, `external_id`, `team_id` | PK `(source_id, external_id)`; FK на `data_sources`, `teams` |
| `player_source_ids` | `source_id`, `external_id`, `player_id` | PK `(source_id, external_id)`; FK на `data_sources`, `players` |
| `coach_source_ids` | `source_id`, `external_id`, `coach_id` | PK `(source_id, external_id)`; FK на `data_sources`, `coaches` |
| `game_source_ids` | `source_id`, `external_id`, `game_id` | PK `(source_id, external_id)`; FK на `data_sources`, `games` |
| `arena_source_ids` | `source_id`, `external_id`, `arena_id` | PK `(source_id, external_id)`; FK на `data_sources`, `arenas` |

**Ограничения:** все поля обязательны; `external_id` имеет тип TEXT. Один внешний идентификатор в пределах источника соответствует одному внутреннему объекту.

## 8. Признаки и прогнозы

| Таблица | Назначение и основные поля | Ключи |
|---|---|---|
| `feature_definitions` | Определение признака: `feature_code`, `description`, `unit` | PK `feature_code` |
| `feature_snapshots` | Снимок признаков: `snapshot_id`, `game_id`, `cutoff_at`, `built_at`, `feature_set_version`, `mode` | PK `snapshot_id`; FK на `games`; UNIQUE `(game_id, cutoff_at, feature_set_version, mode)` |
| `feature_values` | Значение признака: `snapshot_id`, `feature_code`, `value_float` | PK `(snapshot_id, feature_code)`; FK на `feature_snapshots`, `feature_definitions` |
| `model_versions` | Версия модели: `model_version_id`, `trained_at`, `training_cutoff`, `code_hash`, `artifact_uri` | PK `model_version_id` |
| `predictions` | Прогноз: `prediction_id`, `snapshot_id`, `model_version_id`, `created_at`, `target_definition` | PK `prediction_id`; FK на `feature_snapshots`, `model_versions`; UNIQUE `(snapshot_id, model_version_id, target_definition)` |
| `prediction_outcomes` | Вероятность исхода: `prediction_id`, `outcome_code`, `probability` | PK `(prediction_id, outcome_code)`; FK на `predictions` |

**Ограничения:**

- `feature_code` включает версию определения признака; описание обязательно, единица измерения может быть NULL.
- Все поля снимка признаков обязательны; `cutoff_at <= built_at`.
- `mode IN ('reconstructed', 'strict_asof')`.
- `value_float` может быть NULL при неизвестном значении.
- `training_cutoff <= trained_at`; ссылка на модель и хеш кода обязательны.
- У прогноза обязательны снимок, модель, дата создания и определение цели; `created_at` не раньше построения снимка и обучения модели.
- `outcome_code`: `home`, `away`, при трёх исходах также `draw`.
- `probability NOT NULL`, `0 <= probability <= 1`; сумма вероятностей одного прогноза равна 1 с допустимой числовой погрешностью.
- Допустимый набор из двух или трёх исходов определяется `target_definition`.
