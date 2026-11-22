#requires -Version 5.1
[CmdletBinding()]param([string]$TestProviderAssembly)
# Executes generated application algorithms and SQLite adapters, without starting
# Windows Forms. Export-Excel records DTOs only; Excel files and Windows GUI remain 未検証.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$project=Split-Path -Parent $PSScriptRoot
$modulePath=Join-Path $project 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1'
$null=Import-Module $modulePath -Force
foreach($name in @('Common','Tasks','Domains','Operations')){. (Join-Path $project ('Adapters/TaskPilot.Gui'+$name+'.ps1'))}
$TaskFile='TaskList.csv';$ArchiveFile='CompletedTask.csv';$script:AutoReportsReady=$false
$script:passed=0;$script:failed=0;$script:checks=0
$providerArgs=@{};if($TestProviderAssembly){$providerArgs.TestProviderAssembly=$TestProviderAssembly}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilotGuiIntegration_'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($testRoot)
function Assert-Integration([bool]$Ok,[string]$Message){$script:checks++;if(-not$Ok){throw $Message}}
function Reject-Integration([scriptblock]$Action,[string]$Message){$rejected=$false;try{$null=&$Action}catch{$rejected=$true};Assert-Integration $rejected $Message}
function Assert-Hours($Actual,[decimal]$Expected,[string]$Message){Assert-Integration ([math]::Abs([double]$Actual-[double]$Expected)-lt0.00000001) ($Message+' (actual='+$Actual+', expected='+$Expected+')')}
function Parse-IntegrationSource([string]$Path){
    $tokens=$null;$errors=$null;$parsed=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ('PowerShell parser errors in '+$Path+': '+($errors|Out-String))}
    return $parsed
}
function Get-IntegrationFunctions($Ast){@($Ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]},$true))}
function Get-IntegrationCommands($Ast,[string]$Name){@($Ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-eq$Name},$true))}
function Get-IntegrationOwner($Node){
    for($parent=$Node.Parent;$null-ne$parent;$parent=$parent.Parent){if($parent-is[Management.Automation.Language.FunctionDefinitionAst]){return $parent.Name}}
    return '<application>'
}
function Get-IntegrationUiSignatures($Ast,$Overridden){
    foreach($node in $Ast.FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]},$true)){
        $owner=Get-IntegrationOwner $node
        if($Overridden.Contains($owner)){continue}
        if($node.Left-isnot[Management.Automation.Language.MemberExpressionAst]-or$node.Left.Member.Value-cne'Text'){continue}
        if($node.Right-isnot[Management.Automation.Language.CommandExpressionAst]-or$node.Right.Expression-isnot[Management.Automation.Language.StringConstantExpressionAst]){continue}
        # Only the application version/title is intentionally replaced.
        if($owner-eq'<application>'-and$node.Left.Extent.Text-ceq'$form.Text'){continue}
        $owner+'|'+$node.Left.Extent.Text+'|'+$node.Right.Expression.Value
    }
    foreach($node in $Ast.FindAll({param($n)$n-is[Management.Automation.Language.InvokeMemberExpressionAst]-and$n.Member.Value-like'Add_*'},$true)){
        $owner=Get-IntegrationOwner $node
        if(-not$Overridden.Contains($owner)){$owner+'|'+$node.Expression.Extent.Text+'|'+$node.Member.Value}
    }
}
function Invoke-IntegrationCase([string]$Name,[scriptblock]$Action,[switch]$Database){
    $store=$null
    try{
        if($Database){
            $script:database=Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.db')
            $null=New-TaskPilotDatabase -DatabasePath $script:database @providerArgs
            $store=Open-TaskPilotStore -DatabasePath $script:database @providerArgs
            Initialize-TPGuiContext -Store $store -ModulePath $modulePath
        }
        &$Action;$script:passed++;Write-Output ('PASS: '+$Name)
    }catch{$script:failed++;Write-Output ('FAIL: '+$Name+' : '+$_.Exception.Message);Write-Output $_.ScriptStackTrace}
    finally{if($null-ne$store){Close-TaskPilotStore $store}}
}
$sourceAst=Parse-IntegrationSource (Join-Path $project 'TaskPilot.ps1')
$referencePath=Join-Path $project 'reference/TaskPilot_STEP3_6F_4.ps1'
$referenceAst=Parse-IntegrationSource $referencePath
$sourceDefinitions=@(Get-IntegrationFunctions $sourceAst)
$sourceFunctions=@{};foreach($definition in $sourceDefinitions){$sourceFunctions[$definition.Name]=$definition}
$overridden=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($name in @('Initialize-TaskPilotStorage','Initialize-Store','Test-BackupFolder','Invoke-RestoreSnapshot')){$null=$overridden.Add($name)}
$adapterFunctions=@{}
foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $project 'Adapters') -Filter '*.ps1')){
    foreach($definition in @(Get-IntegrationFunctions (Parse-IntegrationSource $file.FullName))){$null=$overridden.Add($definition.Name);$adapterFunctions[$definition.Name]=$definition}
}
# Only actual definitions from the generated entry point are evaluated. No GUI
# top-level code or reference persistence implementation is ever dot-sourced.
$algorithmNames=@('Get-ValidDueDate','Get-LatestRecurringDate','Get-BusinessOccurrence','Get-NextRecurringDate','Get-PlannedDate','Get-WorkPlan','Get-LoggedHours','Get-MonthLoggedHours','Get-DayCapacity','Get-MonthCapacity','Get-TaskMonthAllocation','Get-RemainingMonthCapacity','Get-MonthPlanTotal','ConvertTo-SafeExcelRows','Get-TaskExcelRows','Add-ExtendedExcelSheets','Get-MonthlySnapshotData','Add-AnalyticsExcelSheets','Write-CompletedReport')
foreach($name in $algorithmNames){if(-not$sourceFunctions.ContainsKey($name)){throw ('Generated algorithm missing: '+$name)};. ([scriptblock]::Create($sourceFunctions[$name].Extent.Text))}
# Exercise the real monthly display calculation with simple label/progress DTOs.
# Creating its Form is the only part deliberately omitted on the Linux test host.
$refreshAssignments=@($sourceFunctions['Show-MonthlyCapacityDialog'].FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and$n.Left.Extent.Text-ceq'$refresh'},$true))
if($refreshAssignments.Count-ne1){throw 'Generated monthly display refresh block is missing or ambiguous.'}
$script:monthlyRefresh=$refreshAssignments[0].Right.Expression.ScriptBlock.GetScriptBlock()
# Deliberately retain non-midnight time and milliseconds on Get-Date constructors.
# The generated algorithms must normalize month/day boundaries themselves.
function Get-Date {
    param([int]$Year=2026,[int]$Month=11,[int]$Day=18,[int]$Hour=12,[int]$Minute=34,[int]$Second=56,[string]$Format)
    $value=([datetime]::new($Year,$Month,$Day,$Hour,$Minute,$Second)).AddMilliseconds(789)
    if($PSBoundParameters.ContainsKey('Format')){return $value.ToString($Format,[cultureinfo]::InvariantCulture)}
    return $value
}
function Backup-Data {Assert-Integration ($null-eq$script:TPGuiStore.Transaction) 'GUI backup must precede the write transaction.'}
function Write-ActionLog {param($Action,$Detail)}
function Refresh-List {}
function Export-Excel {
    [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject,[string]$Path,[string]$WorksheetName,[switch]$AutoSize,[switch]$BoldTopRow)
    process{
        if(-not$script:excelRows.ContainsKey($WorksheetName)){$script:excelRows[$WorksheetName]=New-Object 'Collections.Generic.List[object]'}
        $script:excelRows[$WorksheetName].Add($InputObject)
    }
}
function Open-ExcelPackage {param([string]$Path);throw 'TEST_ONLY_EXCEL_DTO_BOUNDARY'}
function Get-IntegrationTask([long]$Id){@(Read-Tasks $TaskFile;Read-Tasks $ArchiveFile)|Where-Object {[long]$_.ID-eq$Id}|Select-Object -First 1}
function Add-IntegrationTask([string]$Title,[string]$Status,[string]$Start,[string]$Due,[decimal]$Hours,[string]$Planned=''){
    Save-TPGuiTaskAggregate $null ([pscustomobject]@{Task=$Title;Priority='中';Status=$Status;DueDate=$Due;Memo="日本語 'quoted'`r`n@memo";WorkStartDate=$Start;EstimatedHours=$Hours;PlannedDate=$Planned})
}
function Initialize-IntegrationFixture {
    $cfg=Read-CapacitySettings;$cfg.Weekdays=@(1,2,3,4,5);$cfg.DailyHours=[decimal]'8.01';$cfg.WorkOnHolidays=$false
    $cfg.Overrides=@{'2026-11-01'=[decimal]'0.01';'2026-11-03'=[decimal]'2.01';'2026-11-05'=[decimal]0;'2026-11-07'=[decimal]'1.01'}
    Save-CapacitySettings $cfg
    Add-CompanyClosure '2026-11-04'
    $entries=@([pscustomobject]@{holiday_date='2025-01-01';name='coverage start'};[pscustomobject]@{holiday_date='2027-12-31';name='coverage end'})
    foreach($month in 1..12){$entries+=[pscustomobject]@{holiday_date=('2026-{0:00}-03'-f$month);name='monthly fixture'}}
    $entries+=[pscustomobject]@{holiday_date='2026-11-23';name='勤労感謝の日'}
    $holiday=Add-TaskPilotHolidaySet -Store $script:TPGuiStore -Data ([pscustomobject]@{name='synthetic calendar';source_name='integration fixture';first_date='2025-01-01';last_date='2027-12-31';holidays=$entries})
    $calendar=Get-TaskPilotCalendar -Store $script:TPGuiStore;$calendar.Data.holiday_set_id=[long]$holiday.holiday_set_id
    $null=Set-TaskPilotCalendar -Store $script:TPGuiStore -Data $calendar.Data -ExpectedToken $calendar.Token
    $script:ids=@{}
    $script:ids.Boundary=Add-IntegrationTask '=SUM(1,2)' '対応中' '2026/10/30' '2026/11/02' ([decimal]'16.06') '2026/11/02'
    $script:ids.FirstDay=Add-IntegrationTask '月初の0.01時間' '未着手' '2026/11/01' '2026/11/01' ([decimal]'0.01') '2026/11/01'
    $script:ids.Completed=Add-IntegrationTask '完了・現在' '完了' '2026/11/02' '2026/11/02' ([decimal]'9.99')
    $script:ids.Exhausted=Add-IntegrationTask '予定超過' '対応中' '2026/11/02' '2026/11/02' ([decimal]'0.01')
    $script:ids.Archived=Add-IntegrationTask '完了・保管' '完了' '2026/11/02' '2026/11/02' ([decimal]'2.01')
    $script:ids.Future=Add-IntegrationTask '翌月' '未着手' '2026/12/01' '2026/12/01' ([decimal]'0.01')
    $task=Get-IntegrationTask $script:ids.Archived
    $null=Set-TaskPilotTask -Store $script:TPGuiStore -TaskId $script:ids.Archived -ExpectedVersion $task.TPRowVersion -Archived $true
    foreach($spec in @(@($script:ids.Completed,'2026-11-18',[decimal]'0.01'),@($script:ids.Archived,'2026-11-19',[decimal]'1.23'))){
        $task=Get-IntegrationTask $spec[0]
        Save-ActualHours ([string]$task.ID) ([datetime]$spec[1]) $spec[2] ([string]$task.Task) -ExpectedVersion $task.TPRowVersion
    }
    $null=@(Read-WorkLogs)
    $logs=@(
        [pscustomobject]@{EntryId='boundary-oct';TaskId=[string]$script:ids.Boundary;WorkDate='2026/10/30';Hours=[decimal]'0.01';Memo='前月'}
        [pscustomobject]@{EntryId='boundary-nov';TaskId=[string]$script:ids.Boundary;WorkDate='2026/11/02';Hours=[decimal]'0.02';Memo='当月'}
        [pscustomobject]@{EntryId='completed-nov';TaskId=[string]$script:ids.Completed;WorkDate='2026/11/18';Hours=[decimal]'0.02';Memo='途中進捗'}
        [pscustomobject]@{EntryId='exhausted-nov';TaskId=[string]$script:ids.Exhausted;WorkDate='2026/11/18';Hours=[decimal]'0.02';Memo='予定超過'}
        [pscustomobject]@{EntryId='archived-nov';TaskId=[string]$script:ids.Archived;WorkDate='2026/11/19';Hours=[decimal]'0.01';Memo='保管済み'}
    )
    Save-WorkLogs $logs -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'work_logs')
    $null=@(Read-Subtasks)
    Save-Subtasks @([pscustomobject]@{Id='child-a';ParentId=[string]$script:ids.Boundary;Title='未完了';Done=$false};[pscustomobject]@{Id='child-b';ParentId=[string]$script:ids.Boundary;Title='完了';Done=$true}) -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'subtasks')
}
try{
    Invoke-IntegrationCase 'Generated source preserves GUI functions, buttons, menus, captions and event bindings' {
        Assert-Integration ((Get-FileHash -LiteralPath $referencePath).Hash.ToLowerInvariant()-ceq'ab0c5e2dbc31128563298d70adf51c59d3e081643899575aaba1d0183d47188d') 'Recorded STEP3 reference revision changed.'
        $referenceDefinitions=@(Get-IntegrationFunctions $referenceAst)
        Assert-Integration (@($referenceDefinitions|Where-Object {$overridden.Contains($_.Name)}).Count-eq48) 'Expected the original 42 persistence functions and six guarded I/O/error functions to be replaced.'
        foreach($definition in $referenceDefinitions){
            if(-not$overridden.Contains($definition.Name)){Assert-Integration $sourceFunctions.ContainsKey($definition.Name) ('GUI function removed: '+$definition.Name)}
            elseif($definition.Name-notin@('Initialize-TaskPilotStorage','Initialize-Store','Test-BackupFolder','Invoke-RestoreSnapshot')){Assert-Integration $adapterFunctions.ContainsKey($definition.Name) ('Replacement adapter missing: '+$definition.Name)}
        }
        foreach($name in @('Add-Button','Add-TaskPilotMenu')){
            $original=@(Get-IntegrationCommands $referenceAst $name);$integrated=@(Get-IntegrationCommands $sourceAst $name)
            Assert-Integration ($original.Count-eq$integrated.Count) ($name+' control count changed.')
            for($i=0;$i-lt$original.Count;$i++){
                Assert-Integration ($original[$i].CommandElements[1].Extent.Text-ceq$integrated[$i].CommandElements[1].Extent.Text) ($name+' label/order changed.')
                if($name-eq'Add-TaskPilotMenu'){Assert-Integration ($original[$i].Extent.Text-ceq$integrated[$i].Extent.Text) 'Menu entries changed.'}
            }
        }
        $expected=@(Get-IntegrationUiSignatures $referenceAst $overridden|Group-Object)
        $actual=@{};foreach($group in @(Get-IntegrationUiSignatures $sourceAst $overridden|Group-Object)){$actual[$group.Name]=$group.Count}
        foreach($group in $expected){Assert-Integration ($actual.ContainsKey($group.Name)-and$actual[$group.Name]-ge$group.Count) ('GUI caption/event removed: '+$group.Name)}
        Assert-Integration ($sourceFunctions.ContainsKey('Show-MonthlySnapshotsDialog')-and$adapterFunctions.ContainsKey('Restore-GuiBackup')) 'Monthly management and backup restore must remain available.'
    }
    Invoke-IntegrationCase 'All storage callsites route through SQLite with original dialog concurrency tokens' {
        foreach($name in @('Import-Csv','Export-Csv','Get-Content','Set-Content','Out-File','Save-TextSafely','Save-Tasks','Reserve-TaskId','Save-WorkPlanFromDialog')){Assert-Integration (@(Get-IntegrationCommands $sourceAst $name).Count-eq0) ('Legacy business-file route remains: '+$name)}
        foreach($command in @(Get-IntegrationCommands $sourceAst 'Add-Content')){Assert-Integration ((Get-IntegrationOwner $command)-in@('Write-ActionLog','Write-ErrorLog')) 'Direct appends are permitted only for logs.'}
        $ioCalls=@($sourceAst.FindAll({param($n)$n-is[Management.Automation.Language.InvokeMemberExpressionAst]-and$n.Member.Value-in@('ReadAllText','WriteAllText','ReadAllBytes','WriteAllBytes','AppendAllText','AppendAllLines')},$true))
        Assert-Integration ($ioCalls.Count-eq0) 'Generated entry point directly reads/writes a business file.'
        $creates=@(Get-IntegrationCommands $sourceAst 'Add-TPGuiTaskFromDialog')
        Assert-Integration ($creates.Count-eq3) 'Main form, calendar day and calendar double-click must all use the aggregate add adapter.'
        Assert-Integration ((@($creates|ForEach-Object {Get-IntegrationOwner $_}|Sort-Object)-join'|')-ceq'<application>|Show-CalendarDay|Update-TaskCalendar') 'The three expected creation actions were not preserved.'
        foreach($name in @('Save-Subtasks','Save-WorkLogs')){
            $commands=@(Get-IntegrationCommands $sourceAst $name)
            Assert-Integration ($commands.Count-eq@(Get-IntegrationCommands $referenceAst $name).Count) ($name+' handler count changed.')
            $table=if($name-eq'Save-Subtasks'){'subtasks'}else{'work_logs'}
            foreach($command in $commands){Assert-Integration ($command.Extent.Text-match("-ExpectedSnapshotToken \(Get-TPGuiLastChildSnapshotToken '$table'\)")) ($name+' must preserve the correct explicit token when the last row is removed.')}
        }
        $recurringCalls=@(Get-IntegrationCommands $sourceAst 'Save-RecurringRules')
        Assert-Integration ($recurringCalls.Count-eq3) 'Recurring add, edit and remove handlers must remain available.'
        foreach($command in $recurringCalls){Assert-Integration ($command.Extent.Text-match'-OriginalRules @\(\$rules.ToArray\(\)\)') 'Recurring editor must retain its original list token.'}
        $actualCall=@(Get-IntegrationCommands $sourceAst 'Save-ActualHours')
        Assert-Integration ($actualCall.Count-eq1-and$actualCall[0].Extent.Text-match'-ExpectedVersion \(\[long\]\$task.TPRowVersion\)') 'Actual-hours dialog must use its selected task version.'
        Assert-Integration (@(Get-IntegrationCommands $sourceAst 'Remove-TPGuiSelectedTask').Count-eq1) 'Delete handler must pass its selected task to the adapter.'
        Assert-Integration ($adapterFunctions['Remove-TPGuiSelectedTask'].Extent.Text-match'-ExpectedVersion \(\[long\]\$Task.TPRowVersion\)') 'Delete adapter must retain the selected task version.'
        $sourceText=[IO.File]::ReadAllText((Join-Path $project 'TaskPilot.ps1'))
        Assert-Integration ($sourceText-match'if\(Get-Command Show-Failure -ErrorAction SilentlyContinue\)\{Show-Failure \$_\}'-and$sourceText-match'else\{Write-ErrorLog \$_;\[System.Windows.Forms.MessageBox\]::Show\(\$_.Exception.Message') 'Startup failures before the Show-Failure definition require a direct-message fallback.'
        foreach($name in @('Common','Tasks','Domains','Operations','Startup')){Assert-Integration ($sourceText.Contains(('. (Join-Path $InstallRoot ''Adapters/TaskPilot.Gui{0}.ps1'')'-f$name))) ('Entry point must load the '+$name+' adapter.')}
    }
    Invoke-IntegrationCase 'Actual generated calendar algorithms honor SQLite holidays, closures, overrides and midnight boundaries' -Database {
        Initialize-IntegrationFixture
        $cfg=Read-CapacitySettings;$holidays=Get-CapacityHolidayKeys;$month=[datetime]'2026-11-18T23:59:59'
        Assert-Integration ($holidays.ContainsKey('2026-11-03')-and$holidays.ContainsKey('2026-11-04')-and$holidays.ContainsKey('2026-11-23')) 'Selected public holidays and company closure must come from SQLite.'
        Assert-Hours (Get-DayCapacity ([datetime]'2026-11-23') $cfg $holidays) 0 'Public holiday capacity'
        Assert-Hours (Get-DayCapacity ([datetime]'2026-11-04') $cfg $holidays) 0 'Company closure capacity'
        Assert-Hours (Get-DayCapacity ([datetime]'2026-11-03') $cfg $holidays) ([decimal]'2.01') 'Holiday override takes precedence'
        Assert-Hours (Get-DayCapacity ([datetime]'2026-11-07') $cfg $holidays) ([decimal]'1.01') 'Weekend override takes precedence'
        Assert-Hours (Get-DayCapacity ([datetime]'2026-11-05') $cfg $holidays) 0 'Zero override removes a working day'
        $capacity=Get-MonthCapacity $month $cfg $holidays
        Assert-Hours $capacity.Hours ([decimal]'139.20') 'Month capacity retains hundredth-hour overrides'
        Assert-Integration ($capacity.Workdays-eq20) 'Only positive-capacity dates count as workdays.'
        $remaining=Get-RemainingMonthCapacity $month ([datetime]'2026-11-18T23:59:59') $cfg $holidays
        Assert-Hours $remaining.Hours ([decimal]'64.08') 'Remaining capacity includes the as-of day'
        Assert-Integration ($remaining.Workdays-eq8) 'Remaining working-day count'
        Assert-Hours (Get-RemainingMonthCapacity $month ([datetime]'2026-12-01') $cfg $holidays).Hours 0 'No remaining capacity after month end'
        $cfg.WorkOnHolidays=$true
        Assert-Hours (Get-DayCapacity ([datetime]'2026-11-23') $cfg $holidays) ([decimal]'8.01') 'Holiday-working setting'
        $rule=[pscustomobject]@{Name='営業日';Type='毎月（第N営業日）';StartDate='2026-01-01';Nth=2;Day=31;Weekday='月'}
        $business=Get-BusinessOccurrence $rule $month
        Assert-Integration ($business-eq[datetime]'2026-11-05'-and$business.TimeOfDay.Ticks-eq0) 'Business recurrence excludes public holiday and closure independently of capacity overrides.'
        $rule.Type='毎月（最終営業日）';Assert-Integration ((Get-BusinessOccurrence $rule $month)-eq[datetime]'2026-11-30') 'Last business day calculation'
        $rule.Type='毎月（日付）'
        Assert-Integration ((Get-LatestRecurringDate $rule ([datetime]'2026-02-28'))-eq[datetime]'2026-02-28') 'Monthly recurrence at midnight clamps day 31 to February month end.'
        Assert-Integration ((Get-NextRecurringDate $rule ([datetime]'2026-02-01'))-eq[datetime]'2026-02-28') 'Next recurrence uses midnight month boundaries.'
    }
    Invoke-IntegrationCase 'Actual generated allocation and snapshot calculations retain .01 hours and separate progress from completion totals' -Database {
        Initialize-IntegrationFixture
        $month=[datetime]'2026-11-01';$cfg=Read-CapacitySettings;$holidays=Get-CapacityHolidayKeys;$plans=Read-WorkPlans
        Assert-Hours (Get-LoggedHours ([string]$script:ids.Boundary)) ([decimal]'0.03') 'Task logs across month boundaries'
        Assert-Hours (Get-TaskMonthAllocation (Get-IntegrationTask $script:ids.Boundary) $month $cfg $holidays $plans) ([decimal]'8.02') 'Cross-month allocation uses remaining estimate and weighted capacity'
        Assert-Hours (Get-TaskMonthAllocation (Get-IntegrationTask $script:ids.FirstDay) $month $cfg $holidays $plans) ([decimal]'0.01') 'Month-first midnight task must not disappear'
        foreach($name in @('Completed','Exhausted','Future')){Assert-Hours (Get-TaskMonthAllocation (Get-IntegrationTask $script:ids[$name]) $month $cfg $holidays $plans) 0 ('Excluded allocation: '+$name)}
        Assert-Hours (Get-MonthPlanTotal $month $cfg $holidays) ([decimal]'8.03') 'Monthly open task allocation'
        $logged=Get-MonthLoggedHours $month;Assert-Hours $logged.Hours ([decimal]'0.07') 'Month work-log sum'
        Assert-Integration ($logged.Count-eq4) 'Month log count excludes October.'
        $snapshot=Get-MonthlySnapshotData $month 'integration calculation'
        foreach($spec in @(@('CapacityHours',[decimal]'139.20'),@('PlannedHours',[decimal]'8.03'),@('PlannedRate',[decimal]'5.77'),@('LoggedHours',[decimal]'0.07'),@('CompletedActualHours',[decimal]'1.24'),@('DifferenceHours',[decimal]'-6.79'))){Assert-Hours $snapshot[$spec[0]] $spec[1] ('Snapshot '+$spec[0])}
        Assert-Integration ($snapshot.CompletedCount-eq2-and$snapshot.Workdays-eq20) 'Snapshot includes active and archived completions without counting progress as completions.'
        $map=@{'2026/11'=$snapshot};Write-MonthlySnapshots $map -ChangedMonth '2026/11' -ExpectedRevision 0 -Reason 'integration fixture'
        $saved=(Read-MonthlySnapshots)['2026/11']
        Assert-Integration ($saved.Revision-eq1-and$saved.Month-ceq'2026/11') 'Calculated monthly snapshot persisted.'
        Assert-Hours $saved.PlannedHours ([decimal]'8.03') 'Snapshot SQL-to-GUI hundredth-hour round trip'
        Assert-Integration ([long](Invoke-TPGuiSql "SELECT planned_hours_x100 FROM current_monthly_snapshots WHERE month_key='2026-11'" -Mode Scalar)-eq803) 'Snapshot storage uses exact scaled integers.'
        $cfg=Read-CapacitySettings;$cfg.Weekdays=@();$cfg.Overrides=@{};Save-CapacitySettings $cfg
        Assert-Integration ($null-eq(Get-MonthlySnapshotData $month 'zero capacity').PlannedRate) 'Zero-capacity rate must remain null.'
    }
    Invoke-IntegrationCase 'Actual Excel DTO functions preserve metadata, subtasks, separate actuals and formula-safe text' -Database {
        Initialize-IntegrationFixture
        $rows=@(Get-TaskExcelRows @(Read-Tasks $TaskFile;Read-Tasks $ArchiveFile))
        Assert-Integration ($rows.Count-eq6) 'Excel task rows include active and archive DTOs.'
        $boundary=@($rows|Where-Object {[long]$_.ID-eq$script:ids.Boundary})[0]
        Assert-Integration ($boundary.実施予定日-ceq'2026/11/02'-and$boundary.作業開始日-ceq'2026/10/30'-and$boundary.期限-ceq'2026/11/02') 'Excel DTO calendar metadata'
        Assert-Hours $boundary.予定所要時間_h ([decimal]'16.06') 'Excel DTO estimate'
        Assert-Hours $boundary.作業記録合計_h ([decimal]'0.03') 'Excel DTO progress'
        Assert-Hours $boundary.残り予定工数_h ([decimal]'16.03') 'Excel DTO remaining estimate'
        Assert-Integration ($null-eq$boundary.完了実績_h-and$boundary.完了日-ceq''-and$boundary.サブタスク数-eq2-and$boundary.サブタスク完了数-eq1) 'Excel DTO preserves missing actual and child progress.'
        $completed=@($rows|Where-Object {[long]$_.ID-eq$script:ids.Completed})[0]
        Assert-Hours $completed.完了実績_h ([decimal]'0.01') 'Excel DTO completion actual stays distinct from logs'
        $safe=@($boundary|ConvertTo-SafeExcelRows)[0]
        Assert-Integration ($safe.タスク名-ceq"'=SUM(1,2)"-and$boundary.タスク名-ceq'=SUM(1,2)') 'Formula safety must copy user text without mutating its source.'
        $formula=[pscustomobject]@{A=" `t@formula";B='+1';C='-1';D='plain';Numeric=[decimal]'-0.01';Absent=$null}
        $safe=@($formula|ConvertTo-SafeExcelRows)[0]
        Assert-Integration ($safe.A-ceq("'"+$formula.A)-and$safe.B-ceq"'+1"-and$safe.C-ceq"'-1"-and$safe.D-ceq'plain'-and$safe.Numeric-eq[decimal]'-0.01'-and$null-eq$safe.Absent) 'Formula safety preserves numeric and null DTO fields.'
        $script:excelRows=@{};Write-CompletedReport (Join-Path $testRoot 'dto-only.xlsx')
        Assert-Integration ($script:excelRows['CompletedTask'].Count-eq2) 'Completed report includes active and archived completions exactly once.'
        $script:excelRows=@{};Add-ExtendedExcelSheets (Join-Path $testRoot 'dto-only.xlsx')
        Assert-Integration ($script:excelRows['作業記録'].Count-eq5-and$script:excelRows['サブタスク'].Count-eq2) 'Extended report preserves work logs and child rows.'
        Assert-Hours $script:excelRows['月間稼働'][0].総稼働可能時間_h ([decimal]'139.20') 'Monthly report DTO capacity'
        Assert-Hours $script:excelRows['月間稼働'][0].未完了予定工数_h ([decimal]'8.03') 'Monthly report DTO planned hours'
    }
    Invoke-IntegrationCase 'Actual monthly display and analytics DTOs use saved values and null rates after live data changes' -Database {
        Initialize-IntegrationFixture
        $saved=[ordered]@{Month='2026/10';CapacityHours=[decimal]'111.11';Workdays=17;PlannedHours=[decimal]'22.22';PlannedRate=[decimal]'33.33';LoggedHours=[decimal]'44.44';CompletedActualHours=[decimal]'55.55';CompletedCount=7;DifferenceHours=[decimal]'66.66';FinalizedAt=(Get-Date).ToString('o');Source='stored fixture';Revision=1}
        $nullRate=[ordered]@{Month='2026/09';CapacityHours=[decimal]'12.34';Workdays=3;PlannedHours=[decimal]'1.01';PlannedRate=$null;LoggedHours=[decimal]'2.02';CompletedActualHours=[decimal]'3.03';CompletedCount=1;DifferenceHours=[decimal]'-4.04';FinalizedAt=(Get-Date).ToString('o');Source='stored null fixture';Revision=1}
        $map=@{'2026/10'=$saved;'2026/09'=$nullRate}
        Write-MonthlySnapshots $map -ChangedMonth '2026/10' -ExpectedRevision 0 -Reason 'saved fixture'
        Write-MonthlySnapshots $map -ChangedMonth '2026/09' -ExpectedRevision 0 -Reason 'null fixture'
        $cfg=Read-CapacitySettings;$cfg.DailyHours=[decimal]'1.01';Save-CapacitySettings $cfg
        $script:excelRows=@{};$boundaryReached=$false
        try{Add-AnalyticsExcelSheets (Join-Path $testRoot 'dto-only.xlsx')}catch{if($_.Exception.Message-cne'TEST_ONLY_EXCEL_DTO_BOUNDARY'){throw};$boundaryReached=$true}
        Assert-Integration $boundaryReached 'Actual analytics must reach the explicit DTO/export boundary.'
        Assert-Integration ($script:excelRows['月別分析'].Count-eq12-and$script:excelRows['タスク工数比較'].Count-eq6) 'Analytics DTO sheet dimensions'
        $oct=@($script:excelRows['月別分析']|Where-Object {$_.対象月-ceq'2026/10'})[0]
        foreach($spec in @(@('稼働可能時間_h',[decimal]'111.11'),@('未完了予定工数_h',[decimal]'22.22'),@('予定稼働率_pct',[decimal]'33.33'),@('日別作業記録_h',[decimal]'44.44'),@('完了時申告実績_h',[decimal]'55.55'))){Assert-Hours $oct.($spec[0]) $spec[1] ('Stored analytics '+$spec[0])}
        Assert-Integration ($oct.確定状態-ceq'確定済み'-and$null-eq$oct.当月残り稼働可能時間_h) 'Historical finalized state and current-only capacity'
        $sep=@($script:excelRows['月別分析']|Where-Object {$_.対象月-ceq'2026/09'})[0]
        Assert-Integration ($null-eq$sep.予定稼働率_pct) 'Stored null rate must not be recomputed from nonzero saved capacity.'
        $nov=@($script:excelRows['月別分析']|Where-Object {$_.対象月-ceq'2026/11'})[0]
        Assert-Integration ($nov.確定状態-ceq'未確定（参考）'-and$null-ne$nov.当月残り稼働可能時間_h) 'Current unfixed month uses live calculations.'
        $task=@($script:excelRows['タスク工数比較']|Where-Object {[long]$_.ID-eq$script:ids.Completed})[0]
        Assert-Hours $task.日別作業記録_h ([decimal]'0.02') 'Comparison progress remains separate'
        Assert-Hours $task.完了時申告実績_h ([decimal]'0.01') 'Comparison completion actual remains separate'
        Assert-Hours $task.予定対完了実績差_h ([decimal]'-9.98') 'Comparison difference uses actual minus estimate'
        Assert-Integration (-not[IO.File]::Exists((Join-Path $testRoot 'dto-only.xlsx'))) 'DTO capture must never claim an Excel file was generated.'
        $month=[pscustomobject]@{Text=''};$body=[pscustomobject]@{Text=''};$progress=[pscustomobject]@{Value=0}
        $script:capacityMonth=[datetime]'2026-10-01';&$script:monthlyRefresh
        foreach($text in @('総稼働日数： 17 日','総稼働可能時間： 111.11 時間','月間予定工数： 22.22 時間','月間予定稼働率： 33.3 %','当月作業記録： 44.44 時間','当月完了実績： 55.55 時間（7 件）','保存値を表示')){Assert-Integration ($body.Text.Contains($text)) ('Monthly display must use stored values: '+$text)}
        Assert-Integration ($progress.Value-eq33) 'Monthly progress uses stored rate.'
        $script:capacityMonth=[datetime]'2026-09-01';&$script:monthlyRefresh
        Assert-Integration ($body.Text.Contains('月間予定稼働率： 算出なし')-and$progress.Value-eq0) 'Null saved rate must display without recalculation or a progress-bar error.'
    }
    Invoke-IntegrationCase 'Selected-task versions reject stale delete and actual edits even after unrelated fresh reads' -Database {
        $id=Add-IntegrationTask 'Original completion' '完了' '2026/11/01' '2026/11/02' ([decimal]'0.01')
        $task=Get-IntegrationTask $id;Save-ActualHours ([string]$id) ([datetime]'2026-11-18') ([decimal]'0.01') 'original actual' -ExpectedVersion $task.TPRowVersion
        $old=Get-IntegrationTask $id
        $other=Open-TaskPilotStore -DatabasePath $script:database @providerArgs
        try{$null=Set-TaskPilotTask -Store $other -TaskId $id -ExpectedVersion $old.TPRowVersion -Title 'Concurrent winner'}finally{Close-TaskPilotStore $other}
        $null=@(Read-Tasks $TaskFile);$null=Read-ActualHours
        Reject-Integration {Remove-TPGuiSelectedTask $old} 'Stale selected delete must be rejected.'
        Reject-Integration {Save-ActualHours ([string]$id) ([datetime]'2026-11-19') ([decimal]'9.99') 'stale actual' -ExpectedVersion $old.TPRowVersion} 'Stale actual dialog must be rejected.'
        Assert-Integration ((Get-IntegrationTask $id).Task-ceq'Concurrent winner'-and[long](Invoke-TPGuiSql 'SELECT is_deleted FROM tasks WHERE task_id=1' -Mode Scalar)-eq0) 'Stale actions changed or deleted the committed task.'
        Assert-Hours (Read-ActualHours)[[string]$id].ActualHours ([decimal]'0.01') 'Stale actual did not replace stored hundredth-hour value'
    }
    Invoke-IntegrationCase 'Explicit empty-child tokens cannot erase concurrent additions after another read' -Database {
        $id=Add-IntegrationTask 'Parent' '未着手' '2026/11/01' '2026/11/02' ([decimal]'0.01')
        $null=@(Read-Subtasks);$original=Get-TPGuiLastChildSnapshotToken 'subtasks'
        $other=Open-TaskPilotStore -DatabasePath $script:database @providerArgs
        try{$parent=Get-TaskPilotTask -Store $other -TaskId $id;$null=Add-TaskPilotSubtask -Store $other -TaskId $id -ExpectedVersion $parent.row_version -Title 'Concurrent child'}finally{Close-TaskPilotStore $other}
        $null=@(Read-Subtasks)
        Reject-Integration {Save-Subtasks @() -ExpectedSnapshotToken $original} 'Original empty subtask snapshot must not authorize removal of a concurrent child.'
        Assert-Integration (@(Read-Subtasks).Count-eq1) 'Concurrent child survived stale empty save.'
        $null=@(Read-WorkLogs);$original=Get-TPGuiLastChildSnapshotToken 'work_logs'
        $other=Open-TaskPilotStore -DatabasePath $script:database @providerArgs
        try{$parent=Get-TaskPilotTask -Store $other -TaskId $id;$null=Add-TaskPilotWorkLog -Store $other -TaskId $id -ExpectedVersion $parent.row_version -WorkDate '2026-11-18' -Hours ([decimal]'0.25')}finally{Close-TaskPilotStore $other}
        $null=@(Read-WorkLogs)
        Reject-Integration {Save-WorkLogs @() -ExpectedSnapshotToken $original} 'Original empty work-log snapshot must not authorize removal of a concurrent log.'
        Assert-Integration (@(Read-WorkLogs).Count-eq1) 'Concurrent work log survived stale empty save.'
    }
    Write-Output ('Result: '+$script:passed+' generated-GUI integration cases passed, '+$script:failed+' failed; '+$script:checks+' assertions. Windows GUI and Excel generation 未検証 (DTO capture only).')
    if($script:failed){throw 'Generated GUI integration tests failed.'}
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
