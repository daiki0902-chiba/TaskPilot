# TaskPilot SQLite GUI integration — persistence map and transaction plan

## Scope and evidence

This is a read-only inventory of the latest **local reviewed GUI reference**, not a claim that it matches the latest remote repository revision:

- Source: `/workspace/output/TaskPilot_reviewed/TaskPilot_STEP3_6F_4.ps1` (0.9.20.5 reviewed script).
- SHA-256: `ab0c5e2dbc31128563298d70adf51c59d3e081643899575aaba1d0183d47188d`.
- Reusable SQLite baseline: `work/step4c/Modules/TaskPilot.Storage` and schema40001. Existing .NET/PowerShell storage and non-destructive migration should be reused.
- `gui-persistence-calls.tsv` contains **335 AST-discovered callsites**, including readers/writers, direct file access, report publication and backup operations. `map-persistence.ps1` regenerates that inventory without launching the UI or writing user data.
- No application source, database, installed app, or source user-data directory was modified by this analysis. No Python was used.

## Integration architecture

Preserve a separate original GUI and introduce a versioned SQLite GUI entrypoint. The new entrypoint opens one explicit validated SQLite store, loads storage adapters, then constructs the existing controls and attaches events. Its runtime data/export/log/backup roots must be separate from the old `%LOCALAPPDATA%\TaskPilot` tree. Do not leave legacy initialization capable of creating CSV/JSON under the old root.

Keep the existing screen layout, menus, dialogs, calendar, subtasks, planned-work allocation, work logs, completion declarations, notification history and Excel sheets. A read adapter can expose the legacy DTO shapes, but **write integration must use semantic storage operations rather than replace whole database tables from old full-file arrays**.

The legacy shape has ID/Date/Task/Priority/DueDate/Status/Memo, slash dates, task-keyed maps, Japanese recurrence labels and month keys. Map those at a defined boundary to snake_case SQLite DTOs, ISO dates, exact decimal hours and canonical rule types. Carry task `row_version`, aggregate Token and monthly Revision with the edit session. Do not recompute an expected token at save time from the latest DB and use it to authorize stale screen data.

The new GUI must never fall back to CSV/JSON writes if the provider or DB fails. Display a concrete error, keep the old store untouched, and offer an explicit separately tested migration/new-store route.

## All writes and required transaction boundaries

| Operation | Exact local callsites | Required SQLite unit / integration change |
| --- | --- | --- |
| Main toolbar/menu task add | 2334 ReadTasks,2335 ReserveTaskId,2337 BackupData,2338 SaveTasks,2340 SavePlannedDate,2341 SaveWorkPlanFromDialog | Replace the entire chain with Add-TaskPilotTask including PlannedOn/WorkStartOn/EstimatedHours. ID assignment+task+plan+dirty commit together. The menu invokes the same stored button action, so do not add a second independent implementation. |
| Day-popup task add | Show-CalendarDay2592–2599 | Same shared semantic Add helper as toolbar. Refresh day list/calendar only after successful commit. |
| Calendar-cell double-click add | Update-TaskCalendar2692–2699 | Same shared semantic Add helper. This is a third creation route and is easy to miss. |
| Task edit/status/complete | Save-EditedTask2271–2281; callers2351(edit),2360(complete),2617(day edit),2958(context status),2994(grid double-click) | Set-TaskPilotTask with the task version captured at editor open and all supplied plan fields in one transaction. A status-only payload intentionally lacks plan fields: do not clear existing planned/start/estimate. Complete remains separate from optional declared completion hours unless the combined Complete-TaskPilotTask flow is deliberately used. |
| Task delete | Main action2368–2370; right-click delete2968 delegates to it | Remove-TaskPilotTask soft deletion with ExpectedVersion. Preserve children, work logs, declarations, occurrences and evidence. Remove full-array CSV filtering. |
| Recurring auto-generation | Invoke-RecurringGeneration378–408; invoked812 after rule dialog and3228 startup | Keep existing occurrence-date algorithm, then Invoke-TaskPilotRecurringOccurrence for rule/date. Task+ledger in one transaction; optional plan belongs in same unit. Delete direct NextId read384, reservation405 and SaveTasks408. Do not use Memo.Contains as the authority for duplicates. Disabled/deleted rules cannot generate, deleted generated tasks do not erase the ledger. |
| Recurring rule add/edit/delete | Show-RecurringRulesDialog777/791/804 SaveRecurringRules(next) | Use per-rule Save/Remove API with original rule Token. Do not replace the entire rules table from a stale ListBox array. Retain rule soft-deletion and generated ledger. Refresh list and next-occurrence preview after commit. |
| Subtask add/toggle/delete | Show-SubtasksDialog2104/2116/2127; main detail-preview toggle2868 | Use Add/Set/Remove-TaskPilotSubtask with parent version and child-parent matching. Main-preview checkbox is a separate fourth save route. Preserve checkbox reentrancy guards and rollback/reload the checked state on failure. |
| Day work-log add/remove | Show-WorkLogDialog979/988 | Per-entry Add/Remove API with parent ExpectedVersion. Do not delete/reinsert all WorkLogs across unrelated tasks. After a successful write refresh the task version used for subsequent entries in the same open dialog. |
| Completion declaration | Show-ActualHoursDialog1160 | Set-TaskPilotCompletionActual with version captured when the task/dialog was loaded. Date, hours and historical task-name snapshot commit together. DB save success must remain success even if subsequent Excel generation fails. |
| Capacity calendar save | Show-CapacitySettingsDialog1134 | Full calendar aggregate Set with Token captured at1103. Normal weekdays+daily hours+work-on-holidays+overrides commit together. Keep zero override and empty weekday array. UI fields must remain decimal, not string/double reinterpretations. |
| Company closure add/remove | Show-HolidayManagementDialog609/617 | Calendar aggregate read/token and closure modification in one semantic action; retain other calendar fields. Avoid a fresh token masking an older saved calendar dialog. Refresh top capacity, monthly view and recurring preview after commit. |
| Holiday CSV import (manual/network) | Import-JapaneseHolidayCsv539; called591/600 | Preserve CP932 validation and duplicate-day checks. Add holiday set+all date/name rows+calendar1 set selection in one outer transaction, using the calendar Token. A failed selection must not leave an unintended imported set as if applied. Network fetch/file parsing occurs before the short DB transaction. |
| Monthly startup auto-finalize | Invoke-MonthlyAutoFinalize1490 WriteMonthlySnapshots then1491 AddMonthlyAudit | Compute previous month's candidate from one read snapshot, then one Save-TaskPilotMonthlySnapshot(ExpectedRevision0). Schema already inserts event+pointer; do not append a second ad hoc audit. Preserve the warning Source that this is startup reconstruction, not exact historical month-end capture. |
| Monthly manual correction | Show-MonthlySnapshotsDialog1544 +1545 (Backup1543) | One SaveMonthly(ExpectedRevision=the original displayed Revision). Reason required, immutable new revision, trigger-generated audit+pointer atomic. Do not write the complete map or increment a guessed current revision outside the unit. |
| App settings | Show-SettingsDialog153 | Set-TaskPilotSettings with the settings Token obtained before opening the dialog. Commit candidate DTO first, then replace AppSettings globals with committed result. Do not mutate live notification settings before a failed save. |
| Notification open/snooze/dismiss | Popup3160/3172/3190 AddNotificationHistory; SaveNotificationData3060 and3191 | Candidate state+corresponding history and Token commit together through Save-TaskPilotNotifications. Clone live arrays/maps or reload DB state after failure so in-memory acknowledgement/snooze is not false. Preserve both Seen and Snoozed when same key exists. |
| Report rebuild | SaveTasks300, SaveWorkPlan882, WorkLog980/989, Actual1160, Monthly1547, OpenAutoReport1890, toolbar2391, startup3227 | Remove automatic Excel work from low-level saves. Schedule one rebuild only after the whole domain commit, using one consistent DB read snapshot for all three workbooks. Persist/report dirty correctly; never query an intermediate task-without-plan state. |
| Backup/restore | BackupData194; callsites277,407,1486,1543,1940,2278,2337,2369,2595,2695; restore entry2389→1972 | Replace file-copy snapshot semantics with SQLite-aware consistent backup and a verified restore process. Never copy only an open .db while WAL may exist. Transaction rollback is not a replacement for recovery backups. Restore requires closed/disposed connections, pre-restore recovery copy, validation and restart/cache reset. Do not leave the old RestoreSnapshot1937 file-deletion implementation active in the SQLite GUI. |

### Low-level legacy writers to retire

`Save-Tasks292`, `Save-TextSafely275`, `Reserve-TaskId235`, `Repair-NextTaskId222`, legacy `Initialize-Store159`, legacy `Initialize-TaskPilotStorage15`, `Replace-FileSafely266` for authoritative data, and old `Invoke-RestoreSnapshot1937` must not write to legacy paths in the new GUI. File-safe replacement can remain useful for derived Excel output, logs or new backup manifests, but not as a concealed alternate authoritative store.

`Save-WorkPlanFromDialog884` is called by four task workflows: edit2281, main-add2341, day-add2599, cell-add2699. These calls must be removed or included in the same explicit transaction; fixing only the toolbar path does not integrate all features.

## All reader callsites

Numbers are source lines; multiple views must consume the same DTO contract rather than each implement SQL independently.

| Reader | Callers |
| --- | --- |
| Read-Tasks | initialize173×2, ID repair224×2, generation381/382, month-plan1079, monthly dialog1197, analytics1562×2, task-report1680/1681, completed-report1847/1848, backup-validator1927, list2213, selection2269, edit2272, main-add2334/delete2368, day-popup2572/2592/2613, calendar2649/2692, alerts3091 |
| Read-PlannedDates | save842, Get-PlannedDate849, Excel1387, day-popup2571, calendar2648, alerts3089 |
| Read-WorkPlans | Get-WorkPlan868, save873, month-plan1077, monthly-dialog1181, Excel1385, analytics1561 |
| Read-Subtasks | task-Excel1388, extended-Excel1421, progress2037, dialog2086/2102/2114/2126, preview2148, main toggle2859 |
| Read-WorkLogs | logged total935, month total940, log-dialog970/977/987, task-Excel1389, extended-Excel1417, analytics1560 |
| Read-ActualHours | save915, declaration-dialog1144, monthly-dialog1190, task-Excel1386, monthly candidate1456, analytics1559 |
| Read-CapacitySettings | top-capacity1088, settings-dialog1103, monthly-dialog1181, extended-Excel1425, month candidate1451, analytics1557 |
| Read-CompanyClosures | business-occurrence463, holiday-dialog583/606/617 |
| Read-RecurringRules | generation378, rules-dialog736, next-preview2181 |
| Read-MonthlySnapshots | monthly-dialog1183, auto-finalize1483, edit-dialog1500, analytics1573 |
| Get-CapacityHolidayKeys | top-capacity1089, monthly-dialog1181, extended-Excel1426, monthly candidate1451, analytics1558 |
| Get-VerifiedHolidayCalendar | business-occurrence461 |
| Load-AppSettings / Load-NotificationData | startup3223/3224 |

Deleted normalized records should be absent from normal task/UI queries but retained for recovery/history. Unresolved imported legacy records remain in their evidence/quarantine tables; a read adapter must not fabricate visible parent tasks or remove that evidence when a normal UI list is saved.

## Direct-file bypasses that defeat a reader-only adapter

These locations must be explicitly rewritten; redirecting Read-X alone leaves visible features tied to nonexistent JSON files:

- Holiday management status:552 Test-Path HolidayFile and554 Get-Content/ConvertFrom-Json. Use selected holiday-set metadata and count from SQLite; update after import instead of telling users to reopen the dialog.
- Get-VerifiedHolidayCalendar444/445: reads and existence-checks JapaneseHolidays.json directly. Query the selected holiday set, retain strict first/last-year coverage and minimum-data behavior.
- Get-CapacityHolidayKeys1002/1004: loops JSON paths directly. Replace with actual public-holiday and company-closure rows. Existing function **does not unwrap current Holidays/Dates envelopes**, so current capacity results may ignore those holidays. Fix that defect while preserving finalized stored values.
- Monthly audit display1519/1520: checks MonthlySnapshotAudit.json then reads it. Show normalized monthly revision events **and** migrated legacy_monthly_audit evidence in stable order with source distinction. Do not omit imported history because the JSON file is absent.
- Recurrence384 reads NextId.txt directly. Startup3222 repairs that TXT. Both are obsolete for SQLite AUTOINCREMENT/high-water migration.
- Startup3220/3221 invokes old migration/root initialization and CSV creation. New launcher must replace this entire startup sequence.
- Load/save implementations for settings83/85, recurring314/315/330, closures425/426/437, plans829/830 and857/858, capacity894/895, actual909/910, logs924/925, snapshots1441/1442, audit1473/1474, subtasks2026/2027, notifications3022/3023/3031/3032 contain their own file existence/default branches. Retire them or implement complete adapters; do not create fake JSON files just to satisfy Test-Path.
- Legacy backup validation1901–1927 and restore1937–1967 require the old Snapshot.json/Data layout and physically delete Data files. Those functions are incompatible with an active SQLite store.

Export file checks1838/1840/1843/1890/1895 and bundled ImportExcel checks1867 remain legitimate filesystem operations. Logs243/258 can remain filesystem logs under the new root; they must not accidentally target the old root.

## Report, calculation and frozen-value risks

1. **Mid-unit report generation.** SaveTasks invokes UpdateAutoReports immediately at300, then task-add/edit saves plan metadata later. SaveWorkPlan invokes it again at882. Remove these implicit updates; commit first, capture one read snapshot, then render all workbooks.
2. **Dirty race.** Current persistent report_state has only a Boolean. If report A captures data then another write B occurs, A must not clear B's dirty flag when it finishes. Add a generation/revision token, compare expected snapshot token under a transaction, or serialize all publications with writers. The boolean alone and an in-memory ReportsNeedRefresh flag are insufficient for multiple processes.
3. **Mixed workbook generations.** UpdateAutoReports1860 publishes TaskList, CompletedTask, Dashboard sequentially. Failure on2/3 leaves earlier files newer. Keep global report dirty on any failure and avoid opening a stale file as current; ideally publish all outputs with a generation manifest and maintain per-report status. Do not hold a DB write transaction across Excel I/O or file associations.
4. **Snapshot coherence.** Existing GetMonthlySnapshotData/Excel functions query many read maps separately. Get-TaskPilotReadSnapshot already captures20 normalized tables in a read transaction; use one such result for an entire refresh/render/candidate calculation. It currently does not include legacy_monthly_audit, so history presentation needs a dedicated consistent query/DTO extension.
5. **Finalized rate GUI discrepancy.** Show-MonthlyCapacityDialog1200–1212 copies saved hours/counts but recomputes rate from saved planned/capacity, ignoring a manually finalized PlannedRate; the Excel analytics path correctly uses snapshot.PlannedRate at1601. Display all finalized fields from the saved record, including nullable rate and signed difference, rather than overwriting historical corrections by recalculation.
6. **Nullable rate cannot be edited.** Monthly correction1526–1536 demands every textbox parse as double, so an empty representation of PlannedRate=null cannot round-trip. Allow blank only for nullable rate, use decimal parsing with the chosen locale and exact two-decimal validation, and preserve null as null.
7. **Two distinct actual measures.** Daily work logs and completion declarations remain distinct in the dialogs, reports and analytics; do not sum both into one actual total. Keep the existing explanatory notes.
8. **Two business-calendar policies.** Legacy recurrence business dates use Mon–Fri+public holidays+company closures; capacity planning uses configured weekdays/holiday-working/overrides. Reuse both behaviors intentionally rather than accidentally making an override change recurrence dates.
9. **Startup provenance.** InvokeMonthlyAutoFinalize reconstructs only the previous month from current data and labels that limitation. Preserve this Source; do not market it as exact past month-end data. Migrated revision5 remains revision5, and the next manual edit becomes6.
10. **Performance.** GetTaskMonthAllocation calls GetLoggedHours for each task, and each call reloads all logs. UI/Excel repeat this across months. Pre-index a single snapshot by task/date instead of repeated complete DB round trips. Timer and event callbacks must not trigger overlapping refresh/report jobs.

## UI cache and optimistic-concurrency contract

- Carry row_version on the task object returned by selection; capture it before New-TaskDialog opens. The status-only context menu and complete action can use the selected version; never retrieve a fresh version immediately before blindly applying stale edited text.
- Capacity/settings/rule editors retain their original Token locally for the lifetime of that dialog. A globally shared "last read token" can change when a timer/other view reads data and therefore authorize a stale write incorrectly.
- Subtask/log/actual operations bump the parent version. On successful mutation refresh parent metadata and the per-dialog expected version before the user makes a second change.
- On conflict, keep entered values available, show a reload/compare choice, and refresh persisted view state. Do not discard unsaved input while claiming a save succeeded.
- Settings153 currently updates script:AppSettings before Save; notification3159/3171/3186 modifies Seen/Snoozed before persistence. Apply committed DTOs to globals only after success, or restore/reload on failure. Checkbox toggles already have busy guards; preserve them during programmatic rollback/reload.
- Notification timer runs every minute even with modal forms. Prevent nested popups/write reentrancy while another modal mutation is active; retain NotificationBusy and use a broader UI mutation guard if needed.

## Safe startup and shutdown sequence

1. Resolve executable/install root, validate supported Windows PowerShell5.1+STA and the pinned managed/native SQLite provider. Create only a new-version runtime root if needed.
2. Require an explicit existing SQLite DB or a separate reviewed new-store/migration choice. Never silently initialize a missing configured DB as an empty app.
3. Acquire a new-store lock (separate from legacy TaskPilot.storage.lock), open/validate SQLite, and load settings/notifications. Keep legacy files untouched and old app independently runnable.
4. Build/attach GUI with SQLite adapters already available before any event-driven read. Use a consistent read snapshot for initial list/calendar/KPIs.
5. Finalize the previous month if not already finalized, run idempotent recurrence generation, then schedule one report refresh after all commits. Show any holiday-rule holds as actionable warnings, not silent missing tasks.
6. Start the notification timer only after the form is ready. Dispose timer/store/lock on shutdown and failed startup. Stop pending workers before disposing the store.

## Acceptance gates for full integration

- AST/static checks show no active legacy NextId writes, CSV/JSON authoritative writes, direct HolidayFile/MonthlyAuditFile reads, or old restore deletion path in the new GUI. Original reference hash stays unchanged.
- Headless service tests exercise the three task-add routes, shared edit/status/complete path, every subtask toggle route, logs/declarations, six recurrence types, holiday set selection, company closures, monthly revision5→6+legacy audit display, settings, snooze/history and all Excel DTOs.
- Failure injection after task mutation but before plan/actual/history confirms full rollback; UI reloads persisted state. Stale dialog tokens/row versions conflict rather than overwrite newer edits.
- Readonly/missing/provider failure never falls back to old files. New DB actions preserve existing-old-root hashes and do not reset migrated identifiers or frozen snapshots.
- Actual Windows PS5.1/STA smoke covers form creation, each dialog save/cancel, 125–200% scaling, calendar navigation+popup, alert timer, Excel absent/locked/retry, backup/restore+restart and new-executable startup on a clean non-admin machine. Linux parser/.NET adapter tests are useful but do not establish Windows GUI behavior or commercial release readiness.
- Report publication and backup/restore need their own verified .NET SQLite mechanisms and Windows tests; neither is completed merely by replacing readers/writers.
