-- TaskPilot STEP 4.0A / schema 40001. Developer-only; apply to a NEW empty DB.
-- SQLite >= 3.38.0 with JSON functions; connection must enable foreign_keys.
-- Dates: YYYY-MM-DD; hours_x100: integer hundredths of one hour (not minutes).
-- This script does not read/import/change legacy files or launch TaskPilot.
-- No IF NOT EXISTS: accidental reapplication must fail, never mask schema drift.
PRAGMA foreign_keys = ON;
PRAGMA recursive_triggers = ON;
PRAGMA busy_timeout = 5000;
PRAGMA synchronous = FULL;
BEGIN IMMEDIATE;

CREATE TABLE schema_migrations (
    version INTEGER PRIMARY KEY CHECK (version > 0),
    applied_at_utc TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')) CHECK (length(applied_at_utc) BETWEEN 20 AND 28 AND (length(substr(applied_at_utc,1,10)) = 10 AND substr(applied_at_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(applied_at_utc,1,10),1,4) <> '0000' AND date(substr(applied_at_utc,1,10), '+0 days') IS NOT NULL AND date(substr(applied_at_utc,1,10), '+0 days') = substr(applied_at_utc,1,10)) AND substr(applied_at_utc,11,1) = 'T' AND substr(applied_at_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(applied_at_utc,12,2) <= '23' AND substr(applied_at_utc,-1) = 'Z' AND (length(applied_at_utc) = 20 OR (length(applied_at_utc) BETWEEN 22 AND 28 AND substr(applied_at_utc,20,1) = '.' AND substr(applied_at_utc,21,length(applied_at_utc)-21) NOT GLOB '*[^0-9]*'))),
    description TEXT NOT NULL
) STRICT;

CREATE TABLE import_batches (
    batch_id TEXT PRIMARY KEY NOT NULL CHECK (length(batch_id)>0),
    captured_at_utc TEXT NOT NULL CHECK (length(captured_at_utc) BETWEEN 20 AND 28 AND (length(substr(captured_at_utc,1,10)) = 10 AND substr(captured_at_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(captured_at_utc,1,10),1,4) <> '0000' AND date(substr(captured_at_utc,1,10), '+0 days') IS NOT NULL AND date(substr(captured_at_utc,1,10), '+0 days') = substr(captured_at_utc,1,10)) AND substr(captured_at_utc,11,1) = 'T' AND substr(captured_at_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(captured_at_utc,12,2) <= '23' AND substr(captured_at_utc,-1) = 'Z' AND (length(captured_at_utc) = 20 OR (length(captured_at_utc) BETWEEN 22 AND 28 AND substr(captured_at_utc,20,1) = '.' AND substr(captured_at_utc,21,length(captured_at_utc)-21) NOT GLOB '*[^0-9]*'))),
    committed_at_utc TEXT NULL CHECK (committed_at_utc IS NULL OR (length(committed_at_utc) BETWEEN 20 AND 28 AND (length(substr(committed_at_utc,1,10)) = 10 AND substr(committed_at_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(committed_at_utc,1,10),1,4) <> '0000' AND date(substr(committed_at_utc,1,10), '+0 days') IS NOT NULL AND date(substr(committed_at_utc,1,10), '+0 days') = substr(committed_at_utc,1,10)) AND substr(committed_at_utc,11,1) = 'T' AND substr(committed_at_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(committed_at_utc,12,2) <= '23' AND substr(committed_at_utc,-1) = 'Z' AND (length(committed_at_utc) = 20 OR (length(committed_at_utc) BETWEEN 22 AND 28 AND substr(committed_at_utc,20,1) = '.' AND substr(committed_at_utc,21,length(committed_at_utc)-21) NOT GLOB '*[^0-9]*')))),
    source_label TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('staged','validated','committed')),
    manifest_sha256 TEXT NOT NULL CHECK (length(manifest_sha256)=64 AND manifest_sha256 NOT GLOB '*[^0-9a-f]*'),
    CHECK ((state='committed' AND committed_at_utc IS NOT NULL) OR (state<>'committed' AND committed_at_utc IS NULL))
) STRICT;

CREATE TABLE import_source_files (
    source_file_id INTEGER PRIMARY KEY,
    batch_id TEXT NOT NULL REFERENCES import_batches(batch_id) ON DELETE RESTRICT,
    relative_path TEXT NOT NULL CHECK (length(relative_path)>0 AND substr(relative_path,1,1)<>'/' AND instr(relative_path,'..')=0 AND instr(relative_path,char(92))=0),
    sha256 TEXT NOT NULL CHECK (length(sha256)=64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
    byte_count INTEGER NOT NULL CHECK (byte_count>=0),
    raw_bytes BLOB NOT NULL,
    source_modified_at_text TEXT NULL,
    CHECK (length(raw_bytes)=byte_count),
    UNIQUE (batch_id,relative_path)
) STRICT;

CREATE TABLE import_issues (
    issue_id INTEGER PRIMARY KEY,
    source_file_id INTEGER NOT NULL REFERENCES import_source_files(source_file_id) ON DELETE RESTRICT,
    severity TEXT NOT NULL CHECK (severity IN ('warning','error')),
    record_locator TEXT NOT NULL,
    code TEXT NOT NULL,
    message TEXT NOT NULL
) STRICT;

CREATE TABLE legacy_unresolved_records (
    unresolved_id INTEGER PRIMARY KEY,
    source_file_id INTEGER NOT NULL REFERENCES import_source_files(source_file_id) ON DELETE RESTRICT,
    record_locator TEXT NOT NULL,
    entity_kind TEXT NOT NULL,
    legacy_task_id_text TEXT NULL,
    reason TEXT NOT NULL,
    payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
    resolution_state TEXT NOT NULL DEFAULT 'unresolved' CHECK (resolution_state IN ('unresolved','resolved','retained')),
    resolution_note TEXT NULL,
    UNIQUE (source_file_id,record_locator)
) STRICT;

CREATE TABLE holiday_sets (
    holiday_set_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    source_name TEXT NOT NULL,
    imported_at_utc TEXT NOT NULL CHECK (length(imported_at_utc) BETWEEN 20 AND 28 AND (length(substr(imported_at_utc,1,10)) = 10 AND substr(imported_at_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(imported_at_utc,1,10),1,4) <> '0000' AND date(substr(imported_at_utc,1,10), '+0 days') IS NOT NULL AND date(substr(imported_at_utc,1,10), '+0 days') = substr(imported_at_utc,1,10)) AND substr(imported_at_utc,11,1) = 'T' AND substr(imported_at_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(imported_at_utc,12,2) <= '23' AND substr(imported_at_utc,-1) = 'Z' AND (length(imported_at_utc) = 20 OR (length(imported_at_utc) BETWEEN 22 AND 28 AND substr(imported_at_utc,20,1) = '.' AND substr(imported_at_utc,21,length(imported_at_utc)-21) NOT GLOB '*[^0-9]*'))),
    first_date TEXT NOT NULL CHECK (length(first_date) = 10 AND first_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(first_date,1,4) <> '0000' AND date(first_date, '+0 days') IS NOT NULL AND date(first_date, '+0 days') = first_date),
    last_date TEXT NOT NULL CHECK (length(last_date) = 10 AND last_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(last_date,1,4) <> '0000' AND date(last_date, '+0 days') IS NOT NULL AND date(last_date, '+0 days') = last_date),
    source_file_id INTEGER NULL REFERENCES import_source_files(source_file_id) ON DELETE RESTRICT,
    CHECK (first_date<=last_date)
) STRICT;

CREATE TABLE public_holidays (
    holiday_set_id INTEGER NOT NULL REFERENCES holiday_sets(holiday_set_id) ON DELETE RESTRICT,
    holiday_date TEXT NOT NULL CHECK (length(holiday_date) = 10 AND holiday_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(holiday_date,1,4) <> '0000' AND date(holiday_date, '+0 days') IS NOT NULL AND date(holiday_date, '+0 days') = holiday_date),
    name TEXT NOT NULL,
    PRIMARY KEY (holiday_set_id,holiday_date)
) STRICT;

CREATE TABLE capacity_calendars (
    calendar_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL CHECK (length(trim(name))>0),
    daily_hours_x100 INTEGER NOT NULL CHECK (daily_hours_x100 BETWEEN 0 AND 2400),
    work_on_holidays INTEGER NOT NULL CHECK (work_on_holidays IN (0,1)),
    holiday_set_id INTEGER NULL REFERENCES holiday_sets(holiday_set_id) ON DELETE RESTRICT
) STRICT;

CREATE TABLE calendar_weekdays (
    calendar_id INTEGER NOT NULL REFERENCES capacity_calendars(calendar_id) ON DELETE RESTRICT,
    weekday INTEGER NOT NULL CHECK (weekday BETWEEN 0 AND 6),
    PRIMARY KEY (calendar_id,weekday)
) STRICT;

CREATE TABLE company_closures (
    calendar_id INTEGER NOT NULL REFERENCES capacity_calendars(calendar_id) ON DELETE RESTRICT,
    closure_date TEXT NOT NULL CHECK (length(closure_date) = 10 AND closure_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(closure_date,1,4) <> '0000' AND date(closure_date, '+0 days') IS NOT NULL AND date(closure_date, '+0 days') = closure_date),
    PRIMARY KEY (calendar_id,closure_date)
) STRICT;

CREATE TABLE capacity_overrides (
    calendar_id INTEGER NOT NULL REFERENCES capacity_calendars(calendar_id) ON DELETE RESTRICT,
    work_date TEXT NOT NULL CHECK (length(work_date) = 10 AND work_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(work_date,1,4) <> '0000' AND date(work_date, '+0 days') IS NOT NULL AND date(work_date, '+0 days') = work_date),
    hours_x100 INTEGER NOT NULL CHECK (hours_x100 BETWEEN 0 AND 2400),
    PRIMARY KEY (calendar_id,work_date)
) STRICT;

CREATE TABLE tasks (
    task_id INTEGER PRIMARY KEY AUTOINCREMENT CHECK (task_id BETWEEN 1 AND 2147483647),
    registered_on TEXT NOT NULL CHECK (length(registered_on) = 10 AND registered_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(registered_on,1,4) <> '0000' AND date(registered_on, '+0 days') IS NOT NULL AND date(registered_on, '+0 days') = registered_on),
    title TEXT NOT NULL CHECK (length(trim(title))>0),
    priority TEXT NOT NULL CHECK (priority IN ('高','中','低')),
    status TEXT NOT NULL CHECK (status IN ('未着手','対応中','完了')),
    due_on TEXT NULL CHECK (due_on IS NULL OR (length(due_on) = 10 AND due_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(due_on,1,4) <> '0000' AND date(due_on, '+0 days') IS NOT NULL AND date(due_on, '+0 days') = due_on)),
    memo TEXT NOT NULL DEFAULT '',
    is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0,1)),
    is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0,1)),
    deleted_at_utc TEXT NULL CHECK (deleted_at_utc IS NULL OR (length(deleted_at_utc) BETWEEN 20 AND 28 AND (length(substr(deleted_at_utc,1,10)) = 10 AND substr(deleted_at_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(deleted_at_utc,1,10),1,4) <> '0000' AND date(substr(deleted_at_utc,1,10), '+0 days') IS NOT NULL AND date(substr(deleted_at_utc,1,10), '+0 days') = substr(deleted_at_utc,1,10)) AND substr(deleted_at_utc,11,1) = 'T' AND substr(deleted_at_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(deleted_at_utc,12,2) <= '23' AND substr(deleted_at_utc,-1) = 'Z' AND (length(deleted_at_utc) = 20 OR (length(deleted_at_utc) BETWEEN 22 AND 28 AND substr(deleted_at_utc,20,1) = '.' AND substr(deleted_at_utc,21,length(deleted_at_utc)-21) NOT GLOB '*[^0-9]*')))),
    calendar_id INTEGER NOT NULL DEFAULT 1 REFERENCES capacity_calendars(calendar_id) ON DELETE RESTRICT,
    row_version INTEGER NOT NULL DEFAULT 1 CHECK (row_version>=1),
    created_at_utc TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')) CHECK (length(created_at_utc) BETWEEN 20 AND 28 AND (length(substr(created_at_utc,1,10)) = 10 AND substr(created_at_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(created_at_utc,1,10),1,4) <> '0000' AND date(substr(created_at_utc,1,10), '+0 days') IS NOT NULL AND date(substr(created_at_utc,1,10), '+0 days') = substr(created_at_utc,1,10)) AND substr(created_at_utc,11,1) = 'T' AND substr(created_at_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(created_at_utc,12,2) <= '23' AND substr(created_at_utc,-1) = 'Z' AND (length(created_at_utc) = 20 OR (length(created_at_utc) BETWEEN 22 AND 28 AND substr(created_at_utc,20,1) = '.' AND substr(created_at_utc,21,length(created_at_utc)-21) NOT GLOB '*[^0-9]*'))),
    updated_at_utc TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')) CHECK (length(updated_at_utc) BETWEEN 20 AND 28 AND (length(substr(updated_at_utc,1,10)) = 10 AND substr(updated_at_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(updated_at_utc,1,10),1,4) <> '0000' AND date(substr(updated_at_utc,1,10), '+0 days') IS NOT NULL AND date(substr(updated_at_utc,1,10), '+0 days') = substr(updated_at_utc,1,10)) AND substr(updated_at_utc,11,1) = 'T' AND substr(updated_at_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(updated_at_utc,12,2) <= '23' AND substr(updated_at_utc,-1) = 'Z' AND (length(updated_at_utc) = 20 OR (length(updated_at_utc) BETWEEN 22 AND 28 AND substr(updated_at_utc,20,1) = '.' AND substr(updated_at_utc,21,length(updated_at_utc)-21) NOT GLOB '*[^0-9]*'))),
    CHECK ((is_deleted=0 AND deleted_at_utc IS NULL) OR (is_deleted=1 AND deleted_at_utc IS NOT NULL))
) STRICT;

CREATE TABLE task_plans (
    task_id INTEGER PRIMARY KEY REFERENCES tasks(task_id) ON DELETE RESTRICT,
    planned_on TEXT NULL CHECK (planned_on IS NULL OR (length(planned_on) = 10 AND planned_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(planned_on,1,4) <> '0000' AND date(planned_on, '+0 days') IS NOT NULL AND date(planned_on, '+0 days') = planned_on)),
    work_start_on TEXT NULL CHECK (work_start_on IS NULL OR (length(work_start_on) = 10 AND work_start_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(work_start_on,1,4) <> '0000' AND date(work_start_on, '+0 days') IS NOT NULL AND date(work_start_on, '+0 days') = work_start_on)),
    estimated_hours_x100 INTEGER NOT NULL DEFAULT 0 CHECK (estimated_hours_x100>=0)
) STRICT;

CREATE TABLE subtasks (
    subtask_id TEXT PRIMARY KEY NOT NULL CHECK (length(subtask_id)>0),
    parent_task_id INTEGER NOT NULL REFERENCES tasks(task_id) ON DELETE RESTRICT,
    title TEXT NOT NULL CHECK (length(trim(title))>0),
    is_done INTEGER NOT NULL CHECK (is_done IN (0,1)),
    sort_order INTEGER NOT NULL CHECK (sort_order>=0)
) STRICT;

CREATE TABLE work_logs (
    entry_id TEXT PRIMARY KEY NOT NULL CHECK (length(entry_id)>0),
    task_id INTEGER NOT NULL REFERENCES tasks(task_id) ON DELETE RESTRICT,
    work_date TEXT NOT NULL CHECK (length(work_date) = 10 AND work_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(work_date,1,4) <> '0000' AND date(work_date, '+0 days') IS NOT NULL AND date(work_date, '+0 days') = work_date),
    hours_x100 INTEGER NOT NULL CHECK (hours_x100 BETWEEN 1 AND 2400),
    memo TEXT NOT NULL DEFAULT '',
    sort_order INTEGER NOT NULL CHECK (sort_order>=0)
) STRICT;

CREATE TABLE completion_actuals (
    task_id INTEGER PRIMARY KEY REFERENCES tasks(task_id) ON DELETE RESTRICT,
    completed_on TEXT NOT NULL CHECK (length(completed_on) = 10 AND completed_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(completed_on,1,4) <> '0000' AND date(completed_on, '+0 days') IS NOT NULL AND date(completed_on, '+0 days') = completed_on),
    actual_hours_x100 INTEGER NOT NULL CHECK (actual_hours_x100>=0),
    task_name_snapshot TEXT NOT NULL
) STRICT;

CREATE TABLE recurring_rules (
    rule_id TEXT PRIMARY KEY NOT NULL CHECK (length(rule_id)>0),
    name TEXT NOT NULL CHECK (length(trim(name))>0),
    rule_type TEXT NOT NULL CHECK (rule_type IN ('daily','weekly','monthly_day','monthly_weekday','monthly_business_day','monthly_last_business_day')),
    weekday INTEGER NULL CHECK (weekday BETWEEN 0 AND 6),
    day_of_month INTEGER NULL CHECK (day_of_month BETWEEN 1 AND 31),
    nth INTEGER NULL CHECK (nth BETWEEN 1 AND 31),
    starts_on TEXT NOT NULL CHECK (length(starts_on) = 10 AND starts_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(starts_on,1,4) <> '0000' AND date(starts_on, '+0 days') IS NOT NULL AND date(starts_on, '+0 days') = starts_on),
    enabled INTEGER NOT NULL CHECK (enabled IN (0,1)),
    note TEXT NOT NULL DEFAULT '',
    calendar_id INTEGER NOT NULL DEFAULT 1 REFERENCES capacity_calendars(calendar_id) ON DELETE RESTRICT,
    business_day_policy TEXT NOT NULL DEFAULT 'legacy_mon_fri_holidays_closures' CHECK (business_day_policy='legacy_mon_fri_holidays_closures'),
    is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0,1)),
    sort_order INTEGER NOT NULL CHECK (sort_order>=0),
    CHECK ((rule_type='daily' AND weekday IS NULL AND day_of_month IS NULL AND nth IS NULL) OR (rule_type='weekly' AND weekday IS NOT NULL AND day_of_month IS NULL AND nth IS NULL) OR (rule_type='monthly_day' AND weekday IS NULL AND day_of_month IS NOT NULL AND nth IS NULL) OR (rule_type='monthly_weekday' AND weekday IS NOT NULL AND day_of_month IS NULL AND nth IS NOT NULL AND nth<=5) OR (rule_type='monthly_business_day' AND weekday IS NULL AND day_of_month IS NULL AND nth IS NOT NULL) OR (rule_type='monthly_last_business_day' AND weekday IS NULL AND day_of_month IS NULL AND nth IS NULL))
) STRICT;

CREATE TABLE recurring_occurrences (
    rule_id TEXT NOT NULL REFERENCES recurring_rules(rule_id) ON DELETE RESTRICT,
    occurrence_date TEXT NOT NULL CHECK (length(occurrence_date) = 10 AND occurrence_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(occurrence_date,1,4) <> '0000' AND date(occurrence_date, '+0 days') IS NOT NULL AND date(occurrence_date, '+0 days') = occurrence_date),
    task_id INTEGER NOT NULL UNIQUE REFERENCES tasks(task_id) ON DELETE RESTRICT,
    generated_at_utc TEXT NULL CHECK (generated_at_utc IS NULL OR (length(generated_at_utc) BETWEEN 20 AND 28 AND (length(substr(generated_at_utc,1,10)) = 10 AND substr(generated_at_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(generated_at_utc,1,10),1,4) <> '0000' AND date(substr(generated_at_utc,1,10), '+0 days') IS NOT NULL AND date(substr(generated_at_utc,1,10), '+0 days') = substr(generated_at_utc,1,10)) AND substr(generated_at_utc,11,1) = 'T' AND substr(generated_at_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(generated_at_utc,12,2) <= '23' AND substr(generated_at_utc,-1) = 'Z' AND (length(generated_at_utc) = 20 OR (length(generated_at_utc) BETWEEN 22 AND 28 AND substr(generated_at_utc,20,1) = '.' AND substr(generated_at_utc,21,length(generated_at_utc)-21) NOT GLOB '*[^0-9]*')))),
    legacy_marker_text TEXT NULL,
    PRIMARY KEY (rule_id,occurrence_date),
    CHECK (generated_at_utc IS NOT NULL OR legacy_marker_text IS NOT NULL)
) STRICT;

CREATE TABLE app_settings (
    singleton_id INTEGER PRIMARY KEY CHECK (singleton_id=1),
    notify_on_startup INTEGER NOT NULL CHECK (notify_on_startup IN (0,1)),
    notify_days INTEGER NOT NULL CHECK (notify_days BETWEEN 0 AND 30),
    daily_notify_enabled INTEGER NOT NULL CHECK (daily_notify_enabled IN (0,1)),
    daily_notify_time TEXT NOT NULL CHECK (length(daily_notify_time)=5 AND daily_notify_time GLOB '[0-2][0-9]:[0-5][0-9]' AND substr(daily_notify_time,1,2)<='23')
) STRICT;

CREATE TABLE notification_state (
    alert_key TEXT PRIMARY KEY NOT NULL CHECK (length(alert_key)>0),
    is_seen INTEGER NOT NULL CHECK (is_seen IN (0,1)),
    snoozed_until_utc TEXT NULL CHECK (snoozed_until_utc IS NULL OR (length(snoozed_until_utc) BETWEEN 20 AND 28 AND (length(substr(snoozed_until_utc,1,10)) = 10 AND substr(snoozed_until_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(snoozed_until_utc,1,10),1,4) <> '0000' AND date(substr(snoozed_until_utc,1,10), '+0 days') IS NOT NULL AND date(substr(snoozed_until_utc,1,10), '+0 days') = substr(snoozed_until_utc,1,10)) AND substr(snoozed_until_utc,11,1) = 'T' AND substr(snoozed_until_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(snoozed_until_utc,12,2) <= '23' AND substr(snoozed_until_utc,-1) = 'Z' AND (length(snoozed_until_utc) = 20 OR (length(snoozed_until_utc) BETWEEN 22 AND 28 AND substr(snoozed_until_utc,20,1) = '.' AND substr(snoozed_until_utc,21,length(snoozed_until_utc)-21) NOT GLOB '*[^0-9]*'))))
) STRICT;

CREATE TABLE notification_history (
    event_id INTEGER PRIMARY KEY,
    occurred_at_local_text TEXT NOT NULL,
    occurred_at_utc TEXT NULL CHECK (occurred_at_utc IS NULL OR (length(occurred_at_utc) BETWEEN 20 AND 28 AND (length(substr(occurred_at_utc,1,10)) = 10 AND substr(occurred_at_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(occurred_at_utc,1,10),1,4) <> '0000' AND date(substr(occurred_at_utc,1,10), '+0 days') IS NOT NULL AND date(substr(occurred_at_utc,1,10), '+0 days') = substr(occurred_at_utc,1,10)) AND substr(occurred_at_utc,11,1) = 'T' AND substr(occurred_at_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(occurred_at_utc,12,2) <= '23' AND substr(occurred_at_utc,-1) = 'Z' AND (length(occurred_at_utc) = 20 OR (length(occurred_at_utc) BETWEEN 22 AND 28 AND substr(occurred_at_utc,20,1) = '.' AND substr(occurred_at_utc,21,length(occurred_at_utc)-21) NOT GLOB '*[^0-9]*')))),
    timezone_id TEXT NULL,
    action TEXT NOT NULL,
    legacy_task_id_text TEXT NOT NULL,
    task_id INTEGER NULL REFERENCES tasks(task_id) ON DELETE RESTRICT,
    task_name_snapshot TEXT NOT NULL,
    category TEXT NOT NULL,
    sort_order INTEGER NOT NULL CHECK (sort_order>=0)
) STRICT;

CREATE TABLE monthly_snapshots (
    calendar_id INTEGER NOT NULL REFERENCES capacity_calendars(calendar_id) ON DELETE RESTRICT,
    month_key TEXT NOT NULL CHECK (length(month_key)=7 AND month_key GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]' AND substr(month_key,1,4) <> '0000' AND substr(month_key,6,2) BETWEEN '01' AND '12'),
    current_revision INTEGER NOT NULL CHECK (current_revision>=1),
    PRIMARY KEY (calendar_id,month_key),
    FOREIGN KEY (calendar_id,month_key,current_revision) REFERENCES monthly_snapshot_revisions(calendar_id,month_key,revision) DEFERRABLE INITIALLY DEFERRED
) STRICT;

CREATE TABLE monthly_snapshot_revisions (
    calendar_id INTEGER NOT NULL,
    month_key TEXT NOT NULL CHECK (length(month_key)=7 AND month_key GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]' AND substr(month_key,1,4) <> '0000' AND substr(month_key,6,2) BETWEEN '01' AND '12'),
    revision INTEGER NOT NULL CHECK (revision>=1),
    capacity_hours_x100 INTEGER NOT NULL CHECK (capacity_hours_x100>=0),
    workdays INTEGER NOT NULL CHECK (workdays>=0),
    planned_hours_x100 INTEGER NOT NULL CHECK (planned_hours_x100>=0),
    planned_rate_x100 INTEGER NULL CHECK (planned_rate_x100>=0),
    logged_hours_x100 INTEGER NOT NULL CHECK (logged_hours_x100>=0),
    completed_actual_hours_x100 INTEGER NOT NULL CHECK (completed_actual_hours_x100>=0),
    completed_count INTEGER NOT NULL CHECK (completed_count>=0),
    difference_hours_x100 INTEGER NOT NULL,
    finalized_at_utc TEXT NOT NULL CHECK (length(finalized_at_utc) BETWEEN 20 AND 28 AND (length(substr(finalized_at_utc,1,10)) = 10 AND substr(finalized_at_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(finalized_at_utc,1,10),1,4) <> '0000' AND date(substr(finalized_at_utc,1,10), '+0 days') IS NOT NULL AND date(substr(finalized_at_utc,1,10), '+0 days') = substr(finalized_at_utc,1,10)) AND substr(finalized_at_utc,11,1) = 'T' AND substr(finalized_at_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(finalized_at_utc,12,2) <= '23' AND substr(finalized_at_utc,-1) = 'Z' AND (length(finalized_at_utc) = 20 OR (length(finalized_at_utc) BETWEEN 22 AND 28 AND substr(finalized_at_utc,20,1) = '.' AND substr(finalized_at_utc,21,length(finalized_at_utc)-21) NOT GLOB '*[^0-9]*'))),
    source TEXT NOT NULL,
    reason TEXT NOT NULL CHECK (length(trim(reason))>0),
    source_file_id INTEGER NULL REFERENCES import_source_files(source_file_id) ON DELETE RESTRICT,
    PRIMARY KEY (calendar_id,month_key,revision),
    FOREIGN KEY (calendar_id,month_key) REFERENCES monthly_snapshots(calendar_id,month_key) DEFERRABLE INITIALLY DEFERRED
) STRICT;

CREATE TABLE monthly_revision_events (
    calendar_id INTEGER NOT NULL,
    month_key TEXT NOT NULL,
    revision INTEGER NOT NULL,
    before_revision INTEGER NULL,
    reason TEXT NOT NULL,
    changed_at_utc TEXT NOT NULL CHECK (length(changed_at_utc) BETWEEN 20 AND 28 AND (length(substr(changed_at_utc,1,10)) = 10 AND substr(changed_at_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(changed_at_utc,1,10),1,4) <> '0000' AND date(substr(changed_at_utc,1,10), '+0 days') IS NOT NULL AND date(substr(changed_at_utc,1,10), '+0 days') = substr(changed_at_utc,1,10)) AND substr(changed_at_utc,11,1) = 'T' AND substr(changed_at_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(changed_at_utc,12,2) <= '23' AND substr(changed_at_utc,-1) = 'Z' AND (length(changed_at_utc) = 20 OR (length(changed_at_utc) BETWEEN 22 AND 28 AND substr(changed_at_utc,20,1) = '.' AND substr(changed_at_utc,21,length(changed_at_utc)-21) NOT GLOB '*[^0-9]*'))),
    PRIMARY KEY (calendar_id,month_key,revision),
    FOREIGN KEY (calendar_id,month_key,revision) REFERENCES monthly_snapshot_revisions(calendar_id,month_key,revision) ON DELETE RESTRICT,
    FOREIGN KEY (calendar_id,month_key,before_revision) REFERENCES monthly_snapshot_revisions(calendar_id,month_key,revision) ON DELETE RESTRICT
) STRICT;

CREATE TABLE legacy_monthly_audit (
    audit_id INTEGER PRIMARY KEY,
    source_file_id INTEGER NOT NULL REFERENCES import_source_files(source_file_id) ON DELETE RESTRICT,
    source_ordinal INTEGER NOT NULL CHECK (source_ordinal>=0),
    month_text TEXT NOT NULL,
    at_text TEXT NOT NULL,
    reason TEXT NOT NULL,
    before_json TEXT NULL CHECK (before_json IS NULL OR json_valid(before_json)),
    after_json TEXT NOT NULL CHECK (json_valid(after_json)),
    UNIQUE (source_file_id,source_ordinal)
) STRICT;

CREATE TABLE report_state (
    singleton_id INTEGER PRIMARY KEY CHECK (singleton_id=1),
    is_dirty INTEGER NOT NULL CHECK (is_dirty IN (0,1)),
    last_generated_at_utc TEXT NULL CHECK (last_generated_at_utc IS NULL OR (length(last_generated_at_utc) BETWEEN 20 AND 28 AND (length(substr(last_generated_at_utc,1,10)) = 10 AND substr(last_generated_at_utc,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(substr(last_generated_at_utc,1,10),1,4) <> '0000' AND date(substr(last_generated_at_utc,1,10), '+0 days') IS NOT NULL AND date(substr(last_generated_at_utc,1,10), '+0 days') = substr(last_generated_at_utc,1,10)) AND substr(last_generated_at_utc,11,1) = 'T' AND substr(last_generated_at_utc,12,8) GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(last_generated_at_utc,12,2) <= '23' AND substr(last_generated_at_utc,-1) = 'Z' AND (length(last_generated_at_utc) = 20 OR (length(last_generated_at_utc) BETWEEN 22 AND 28 AND substr(last_generated_at_utc,20,1) = '.' AND substr(last_generated_at_utc,21,length(last_generated_at_utc)-21) NOT GLOB '*[^0-9]*')))),
    last_error TEXT NULL
) STRICT;


-- Disallow physical task/rule removal. API changes is_deleted in one transaction.
CREATE TRIGGER tasks_no_physical_delete BEFORE DELETE ON tasks
BEGIN SELECT RAISE(ABORT,'Use soft deletion; retain related task history'); END;
CREATE TRIGGER recurring_rules_no_physical_delete BEFORE DELETE ON recurring_rules
BEGIN SELECT RAISE(ABORT,'Use soft deletion; retain occurrence history'); END;
CREATE TRIGGER recurring_occurrences_no_delete BEFORE DELETE ON recurring_occurrences
BEGIN SELECT RAISE(ABORT,'Occurrence history is append-only'); END;
CREATE TRIGGER recurring_occurrences_no_update BEFORE UPDATE ON recurring_occurrences
BEGIN SELECT RAISE(ABORT,'Occurrence history is append-only'); END;

-- Existing imports may begin at a higher revision; subsequent revisions are consecutive.
CREATE TRIGGER monthly_revision_sequence BEFORE INSERT ON monthly_snapshot_revisions
WHEN EXISTS (SELECT 1 FROM monthly_snapshot_revisions WHERE calendar_id=NEW.calendar_id AND month_key=NEW.month_key)
AND NEW.revision <> (SELECT MAX(revision)+1 FROM monthly_snapshot_revisions WHERE calendar_id=NEW.calendar_id AND month_key=NEW.month_key)
BEGIN SELECT RAISE(ABORT,'Monthly revisions must be consecutive'); END;
CREATE TRIGGER monthly_revision_no_update BEFORE UPDATE ON monthly_snapshot_revisions
BEGIN SELECT RAISE(ABORT,'Monthly revisions are immutable; append a correction'); END;
CREATE TRIGGER monthly_revision_no_delete BEFORE DELETE ON monthly_snapshot_revisions
BEGIN SELECT RAISE(ABORT,'Monthly revisions are immutable'); END;
CREATE TRIGGER monthly_event_no_update BEFORE UPDATE ON monthly_revision_events
BEGIN SELECT RAISE(ABORT,'Monthly audit events are immutable'); END;
CREATE TRIGGER monthly_event_no_delete BEFORE DELETE ON monthly_revision_events
BEGIN SELECT RAISE(ABORT,'Monthly audit events are immutable'); END;
CREATE TRIGGER monthly_pointer_no_delete BEFORE DELETE ON monthly_snapshots
BEGIN SELECT RAISE(ABORT,'Monthly finalized records must be retained'); END;
CREATE TRIGGER monthly_pointer_insert_guard BEFORE INSERT ON monthly_snapshots
WHEN EXISTS (SELECT 1 FROM monthly_snapshot_revisions WHERE calendar_id=NEW.calendar_id AND month_key=NEW.month_key)
AND NEW.current_revision IS NOT (SELECT MAX(revision) FROM monthly_snapshot_revisions WHERE calendar_id=NEW.calendar_id AND month_key=NEW.month_key)
BEGIN SELECT RAISE(ABORT,'Monthly pointer must begin at latest imported revision'); END;
CREATE TRIGGER monthly_pointer_guard BEFORE UPDATE ON monthly_snapshots
WHEN NEW.calendar_id<>OLD.calendar_id OR NEW.month_key<>OLD.month_key
OR NEW.current_revision IS NOT (SELECT MAX(revision) FROM monthly_snapshot_revisions WHERE calendar_id=NEW.calendar_id AND month_key=NEW.month_key)
BEGIN SELECT RAISE(ABORT,'Monthly pointer must reference latest revision'); END;
CREATE TRIGGER monthly_revision_recorded AFTER INSERT ON monthly_snapshot_revisions
BEGIN
    INSERT INTO monthly_revision_events(calendar_id,month_key,revision,before_revision,reason,changed_at_utc)
    VALUES (NEW.calendar_id,NEW.month_key,NEW.revision,
        (SELECT MAX(revision) FROM monthly_snapshot_revisions WHERE calendar_id=NEW.calendar_id AND month_key=NEW.month_key AND revision<NEW.revision),
        NEW.reason,NEW.finalized_at_utc);
    UPDATE monthly_snapshots SET current_revision=NEW.revision
    WHERE calendar_id=NEW.calendar_id AND month_key=NEW.month_key;
END;
CREATE TRIGGER legacy_audit_no_update BEFORE UPDATE ON legacy_monthly_audit
BEGIN SELECT RAISE(ABORT,'Legacy audit evidence is immutable'); END;
CREATE TRIGGER legacy_audit_no_delete BEFORE DELETE ON legacy_monthly_audit
BEGIN SELECT RAISE(ABORT,'Legacy audit evidence is immutable'); END;
CREATE TRIGGER import_source_no_update BEFORE UPDATE ON import_source_files
BEGIN SELECT RAISE(ABORT,'Captured source bytes are immutable'); END;
CREATE TRIGGER import_source_no_delete BEFORE DELETE ON import_source_files
BEGIN SELECT RAISE(ABORT,'Captured source bytes must be retained'); END;

-- Dirty flags are committed with domain changes. Report generation runs after commit.

CREATE TRIGGER tasks_no_replace BEFORE INSERT ON tasks
WHEN EXISTS (SELECT 1 FROM tasks WHERE task_id=NEW.task_id)
BEGIN SELECT RAISE(ABORT,'Existing identity or immutable evidence cannot be replaced'); END;

CREATE TRIGGER recurring_rules_no_replace BEFORE INSERT ON recurring_rules
WHEN EXISTS (SELECT 1 FROM recurring_rules WHERE rule_id=NEW.rule_id)
BEGIN SELECT RAISE(ABORT,'Existing identity or immutable evidence cannot be replaced'); END;

CREATE TRIGGER recurring_occurrences_no_replace BEFORE INSERT ON recurring_occurrences
WHEN EXISTS (SELECT 1 FROM recurring_occurrences WHERE (rule_id=NEW.rule_id AND occurrence_date=NEW.occurrence_date) OR task_id=NEW.task_id)
BEGIN SELECT RAISE(ABORT,'Existing identity or immutable evidence cannot be replaced'); END;

CREATE TRIGGER monthly_snapshots_no_replace BEFORE INSERT ON monthly_snapshots
WHEN EXISTS (SELECT 1 FROM monthly_snapshots WHERE calendar_id=NEW.calendar_id AND month_key=NEW.month_key)
BEGIN SELECT RAISE(ABORT,'Existing identity or immutable evidence cannot be replaced'); END;

CREATE TRIGGER monthly_revision_events_no_replace BEFORE INSERT ON monthly_revision_events
WHEN EXISTS (SELECT 1 FROM monthly_revision_events WHERE calendar_id=NEW.calendar_id AND month_key=NEW.month_key AND revision=NEW.revision)
BEGIN SELECT RAISE(ABORT,'Existing identity or immutable evidence cannot be replaced'); END;

CREATE TRIGGER import_source_files_no_replace BEFORE INSERT ON import_source_files
WHEN EXISTS (SELECT 1 FROM import_source_files WHERE source_file_id=NEW.source_file_id OR (batch_id=NEW.batch_id AND relative_path=NEW.relative_path))
BEGIN SELECT RAISE(ABORT,'Existing identity or immutable evidence cannot be replaced'); END;

CREATE TRIGGER legacy_monthly_audit_no_replace BEFORE INSERT ON legacy_monthly_audit
WHEN EXISTS (SELECT 1 FROM legacy_monthly_audit WHERE audit_id=NEW.audit_id OR (source_file_id=NEW.source_file_id AND source_ordinal=NEW.source_ordinal))
BEGIN SELECT RAISE(ABORT,'Existing identity or immutable evidence cannot be replaced'); END;

CREATE TRIGGER tasks_report_dirty_insert AFTER INSERT ON tasks
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER tasks_report_dirty_update AFTER UPDATE ON tasks
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER tasks_report_dirty_delete AFTER DELETE ON tasks
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER task_plans_report_dirty_insert AFTER INSERT ON task_plans
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER task_plans_report_dirty_update AFTER UPDATE ON task_plans
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER task_plans_report_dirty_delete AFTER DELETE ON task_plans
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER subtasks_report_dirty_insert AFTER INSERT ON subtasks
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER subtasks_report_dirty_update AFTER UPDATE ON subtasks
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER subtasks_report_dirty_delete AFTER DELETE ON subtasks
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER work_logs_report_dirty_insert AFTER INSERT ON work_logs
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER work_logs_report_dirty_update AFTER UPDATE ON work_logs
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER work_logs_report_dirty_delete AFTER DELETE ON work_logs
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER completion_actuals_report_dirty_insert AFTER INSERT ON completion_actuals
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER completion_actuals_report_dirty_update AFTER UPDATE ON completion_actuals
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER completion_actuals_report_dirty_delete AFTER DELETE ON completion_actuals
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER recurring_rules_report_dirty_insert AFTER INSERT ON recurring_rules
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER recurring_rules_report_dirty_update AFTER UPDATE ON recurring_rules
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER recurring_rules_report_dirty_delete AFTER DELETE ON recurring_rules
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER recurring_occurrences_report_dirty_insert AFTER INSERT ON recurring_occurrences
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER recurring_occurrences_report_dirty_update AFTER UPDATE ON recurring_occurrences
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER recurring_occurrences_report_dirty_delete AFTER DELETE ON recurring_occurrences
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER capacity_calendars_report_dirty_insert AFTER INSERT ON capacity_calendars
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER capacity_calendars_report_dirty_update AFTER UPDATE ON capacity_calendars
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER capacity_calendars_report_dirty_delete AFTER DELETE ON capacity_calendars
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER calendar_weekdays_report_dirty_insert AFTER INSERT ON calendar_weekdays
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER calendar_weekdays_report_dirty_update AFTER UPDATE ON calendar_weekdays
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER calendar_weekdays_report_dirty_delete AFTER DELETE ON calendar_weekdays
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER company_closures_report_dirty_insert AFTER INSERT ON company_closures
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER company_closures_report_dirty_update AFTER UPDATE ON company_closures
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER company_closures_report_dirty_delete AFTER DELETE ON company_closures
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER capacity_overrides_report_dirty_insert AFTER INSERT ON capacity_overrides
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER capacity_overrides_report_dirty_update AFTER UPDATE ON capacity_overrides
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER capacity_overrides_report_dirty_delete AFTER DELETE ON capacity_overrides
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER holiday_sets_report_dirty_insert AFTER INSERT ON holiday_sets
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER holiday_sets_report_dirty_update AFTER UPDATE ON holiday_sets
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER holiday_sets_report_dirty_delete AFTER DELETE ON holiday_sets
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER public_holidays_report_dirty_insert AFTER INSERT ON public_holidays
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER public_holidays_report_dirty_update AFTER UPDATE ON public_holidays
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER public_holidays_report_dirty_delete AFTER DELETE ON public_holidays
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER monthly_snapshot_revisions_report_dirty_insert AFTER INSERT ON monthly_snapshot_revisions
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER monthly_snapshot_revisions_report_dirty_update AFTER UPDATE ON monthly_snapshot_revisions
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;

CREATE TRIGGER monthly_snapshot_revisions_report_dirty_delete AFTER DELETE ON monthly_snapshot_revisions
BEGIN UPDATE report_state SET is_dirty=1 WHERE singleton_id=1; END;


CREATE INDEX ix_tasks_active_due ON tasks(is_deleted,is_archived,status,due_on);
CREATE INDEX ix_task_plans_planned ON task_plans(planned_on);
CREATE INDEX ix_subtasks_parent_order ON subtasks(parent_task_id,sort_order,subtask_id);
CREATE INDEX ix_work_logs_date_task ON work_logs(work_date,task_id);
CREATE INDEX ix_completion_actuals_date ON completion_actuals(completed_on);
CREATE INDEX ix_recurring_rules_enabled ON recurring_rules(is_deleted,enabled);
CREATE INDEX ix_notification_history_order ON notification_history(sort_order,event_id);
CREATE INDEX ix_import_issues_source ON import_issues(source_file_id,severity);
CREATE INDEX ix_unresolved_task ON legacy_unresolved_records(legacy_task_id_text);

CREATE VIEW current_monthly_snapshots AS
SELECT r.* FROM monthly_snapshots AS s
JOIN monthly_snapshot_revisions AS r USING (calendar_id,month_key)
WHERE r.revision=s.current_revision;
CREATE VIEW active_tasks AS SELECT * FROM tasks WHERE is_deleted=0 AND is_archived=0;

INSERT INTO capacity_calendars(calendar_id,name,daily_hours_x100,work_on_holidays) VALUES (1,'既定の稼働条件',800,0);
INSERT INTO calendar_weekdays(calendar_id,weekday) VALUES (1,1),(1,2),(1,3),(1,4),(1,5);
INSERT INTO app_settings(singleton_id,notify_on_startup,notify_days,daily_notify_enabled,daily_notify_time) VALUES (1,1,3,0,'09:00');
INSERT INTO report_state(singleton_id,is_dirty) VALUES (1,1);
INSERT INTO schema_migrations(version,description) VALUES (40001,'STEP 4.0A schema only; no legacy import');
PRAGMA user_version = 40001;
PRAGMA application_id = 1414547788;
COMMIT;
