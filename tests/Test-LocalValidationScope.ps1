#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RuntimeAssembly,[Parameter(Mandatory=$true)][string]$OutputRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'Native Windows PowerShell Desktop 5.1 x64 is required. No native local-validation result was produced.'}
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'An existing developer report directory is required.'}
$fixture=Join-Path $output ('LocalValidationScope_'+[guid]::NewGuid().ToString('N'))
$profile=Join-Path $fixture 'SyntheticLocalAppData';$null=[IO.Directory]::CreateDirectory($profile)
$runtimePath=Get-TPBuildFullPath $RuntimeAssembly;Assert-TPBuildNoLinks $runtimePath
$runtimeSha=Get-TPBuildSha $runtimePath;$loaded=[Reflection.Assembly]::LoadFrom($runtimePath)
if(-not[string]::Equals($loaded.Location,$runtimePath,[StringComparison]::OrdinalIgnoreCase)-or(Get-TPBuildSha $loaded.Location)-cne$runtimeSha){throw 'The exact local-validation package runtime assembly is required.'}
foreach($method in @('CreateLocalValidation','OpenExistingLocalValidation')){if($null-eq$loaded.GetType('TaskPilot.Runtime.Sandbox',$true).GetMethod($method)){throw 'The fixed local-validation runtime factory is missing.'}}
$cases=New-Object 'Collections.Generic.List[object]';$checks=0
$script:scopeBroker=$null;$script:scopeStore=$null;$script:scopeModule=$null
$script:scopeEnvironmentId=[guid]::NewGuid().ToString('N')
$script:independentBytes=$null;$script:acceptanceBytes=$null;$script:localBytes=$null
$script:scopeDatabase=$null;$script:scopeTaskId=0;$script:preservedScopes=@{}
function Assert-LocalScope([bool]$Condition,[string]$Detail){$script:checks++;if(-not$Condition){throw $Detail}}
function Reject-LocalScope([scriptblock]$Operation,[string]$Pattern){
    $failure=$null;try{$null=&$Operation}catch{$failure=$_}
    Assert-LocalScope ($null-ne$failure-and$failure.Exception.Message-match$Pattern) ('Expected local scope refusal: '+$Pattern)
}
function Case-LocalScope([string]$CaseId,[string]$Description,[scriptblock]$Operation){
    try{&$Operation;$cases.Add([pscustomobject]@{Id=$CaseId;Name=$Description;Passed=$true});Write-Host ('PASS: '+$CaseId+' '+$Description)}
    catch{$cases.Add([pscustomobject]@{Id=$CaseId;Name=$Description;Passed=$false;Error=$_.Exception.ToString();Stack=$_.ScriptStackTrace});Write-Host ('FAIL: '+$CaseId+' '+$_.Exception.Message)}
}
function Hash-LocalScope([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Snapshot-LocalScope([string]$SnapshotPath){
    $rows=New-Object 'Collections.Generic.List[string]';$rows.Add('DIRECTORY . ACL '+[string](Get-Acl -LiteralPath $SnapshotPath).Sddl)
    foreach($entry in @(Get-ChildItem -LiteralPath $SnapshotPath -Recurse -Force|Sort-Object FullName)){
        if(($entry.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Synthetic snapshots must not traverse links.'}
        $relative=$entry.FullName.Substring($SnapshotPath.Length+1).Replace('\','/');$acl=[string](Get-Acl -LiteralPath $entry.FullName).Sddl
        if($entry.PSIsContainer){$rows.Add('DIRECTORY '+$relative+' ACL '+$acl)}else{$rows.Add('FILE '+$relative+' '+$entry.Length+' '+(Get-TPBuildSha $entry.FullName)+' ACL '+$acl)}
    }
    return [string]::Join("`n",$rows.ToArray())
}
function Close-LocalScopeStore {
    if($null-ne$script:scopeStore-and-not$script:scopeStore.Closed){Close-TaskPilotStore $script:scopeStore}
    $script:scopeStore=$null
}
function Close-LocalScopeModule {
    Close-LocalScopeStore
    if($null-ne$script:scopeModule){Remove-Module $script:scopeModule -Force -ErrorAction SilentlyContinue;$script:scopeModule=$null}
}
function Use-LocalScopeModule($Broker){
    Close-LocalScopeModule
    $script:scopeModule=Import-Module (Join-Path $repo 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force -PassThru
    & $script:scopeModule {param($boundBroker) Set-TaskPilotTestSandbox $boundBroker} $Broker
}
function Local-Sql($Store,[string]$Sql,[hashtable]$Parameters=@{},[string]$Mode='Rows'){
    return & $script:scopeModule {param($s,$q,$p,$m) Invoke-TPSql $s $q -Parameters $p -Mode $m} $Store $Sql $Parameters $Mode
}
# All ordinary and historical data in this suite are invented fixtures. No
# actual profile or existing business directory is supplied as a test target.
# The normal read-only rejection guard may resolve its OS KnownFolder prefix;
# it does not open, list or hash any TaskPilot data at that prefix.
foreach($relative in @('TaskPilot/Data','TaskPilot4/Data','TaskPilot4/Backup','TaskPilot4Logs')){
    $dir=Join-Path $profile $relative;$null=[IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'synthetic-normal.txt'),'SYNTHETIC NORMAL DATA '+$relative)
}
$normalBefore=@{};foreach($leaf in @('TaskPilot','TaskPilot4','TaskPilot4Logs')){$normalBefore[$leaf]=Snapshot-LocalScope (Join-Path $profile $leaf)}
try{
    Case-LocalScope 'L01' 'Existing independent and acceptance factories retain exact paths markers and database tags' {
        foreach($purpose in @('independent','acceptance')){
            $script:scopeBroker=if($purpose-ceq'independent'){[TaskPilot.Runtime.Sandbox]::Create($profile,$script:scopeEnvironmentId)}else{[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$script:scopeEnvironmentId)}
            $leaf=if($purpose-ceq'independent'){'TaskPilotTest'}else{'TaskPilotAcceptance'}
            $heading=if($purpose-ceq'independent'){"TaskPilot independent test environment v2`n"}else{"TaskPilot desktop acceptance synthetic-only environment v1`n"}
            Assert-LocalScope (-not$script:scopeBroker.IsLocalValidation-and$script:scopeBroker.Root-ceq(Join-Path (Join-Path $profile $leaf) $script:scopeEnvironmentId)) 'A preexisting fixed namespace changed.'
            Assert-LocalScope ($script:scopeBroker.ReadAllText($script:scopeBroker.MarkerPath)-ceq($heading+$script:scopeEnvironmentId+"`n")) 'A preexisting marker changed.'
            Use-LocalScopeModule $script:scopeBroker
            $database=Join-Path $script:scopeBroker.Data 'historical-synthetic.db';$null=New-TaskPilotDatabase -DatabasePath $database
            $script:scopeStore=Open-TaskPilotStore -DatabasePath $database
            $description=[string](Local-Sql $script:scopeStore 'SELECT description FROM schema_migrations WHERE version=40001' -Mode Scalar)
            Assert-LocalScope ($description-ceq('TaskPilot independent test environment:'+$script:scopeEnvironmentId)) 'The existing independent/acceptance SQLite tag changed.'
            Close-LocalScopeModule
            if($purpose-ceq'independent'){$script:independentBytes=$script:scopeBroker.ReadAllBytes($database)}else{$script:acceptanceBytes=$script:scopeBroker.ReadAllBytes($database)}
            $script:scopeBroker.Dispose();$script:scopeBroker=$null
            $script:preservedScopes[$leaf]=Snapshot-LocalScope (Join-Path $profile $leaf)
        }
    }
    Case-LocalScope 'L02' 'Local validation has a third fixed namespace marker and purpose-bound memory database' {
        $script:scopeBroker=[TaskPilot.Runtime.Sandbox]::CreateLocalValidation($profile,$script:scopeEnvironmentId)
        Assert-LocalScope ($script:scopeBroker.IsLocalValidation-and$script:scopeBroker.Root-ceq(Join-Path (Join-Path $profile 'TaskPilotLocalValidation') $script:scopeEnvironmentId)) 'The local namespace is not fixed and distinct.'
        Assert-LocalScope ([IO.Path]::GetFileName($script:scopeBroker.MarkerPath)-ceq'.taskpilot-local-validation-environment') 'The local marker filename is not distinct.'
        Assert-LocalScope ($script:scopeBroker.ReadAllText($script:scopeBroker.MarkerPath)-ceq("TaskPilot local validation synthetic-only environment v1`n"+$script:scopeEnvironmentId+"`n")) 'The local purpose marker is incorrect.'
        $preparedLock=$script:scopeBroker.AcquireLock($script:scopeBroker.LockPath);$preparedLock.Dispose()
        foreach($dir in @($script:scopeBroker.Data,$script:scopeBroker.Export,$script:scopeBroker.Backup,$script:scopeBroker.Logs,$script:scopeBroker.Temp,$script:scopeBroker.Input)){
            $path=Join-Path $dir 'local-synthetic.txt';$script:scopeBroker.WriteNew($path,[Text.Encoding]::UTF8.GetBytes('SYNTHETIC LOCAL ONLY'))
            Assert-LocalScope ($script:scopeBroker.ReadAllText($path)-ceq'SYNTHETIC LOCAL ONLY') 'A local persistent output failed to round-trip.'
        }
        $script:scopeBroker.WriteNew((Join-Path $script:scopeBroker.Logs 'local-validation-events.jsonl'),[Text.Encoding]::UTF8.GetBytes('{"FormatVersion":1,"Code":"ACTION"}'+[Environment]::NewLine+'{"FormatVersion":1,"Code":"OPERATION_FAILED"}'))
        Use-LocalScopeModule $script:scopeBroker
        $script:scopeDatabase=Join-Path $script:scopeBroker.Data 'local-synthetic.db';$null=New-TaskPilotDatabase -DatabasePath $script:scopeDatabase
        $script:scopeStore=Open-TaskPilotStore -DatabasePath $script:scopeDatabase
        Assert-LocalScope ([string](Local-Sql $script:scopeStore 'SELECT description FROM schema_migrations WHERE version=40001' -Mode Scalar)-ceq('TaskPilot local validation environment:'+$script:scopeEnvironmentId)) 'The local database lacks its own purpose tag.'
        $databases=@(Local-Sql $script:scopeStore 'PRAGMA database_list')
        Assert-LocalScope ($databases.Count-eq1-and$databases[0].name-ceq'main'-and[string]::IsNullOrEmpty([string]$databases[0].file)) 'Native SQLite opened a durable filename.'
        Assert-LocalScope ([long](Local-Sql $script:scopeStore 'PRAGMA temp_store' -Mode Scalar)-eq2) 'SQLite temporary storage is not memory-only.'
    }
    Case-LocalScope 'L03' 'Task child work-log and exact hour data survive closing and readonly reopening' {
        $task=Add-TaskPilotTask -Store $script:scopeStore -Title 'SYNTHETIC LOCAL TASK' -RegisteredOn '2026-11-23' -EstimatedHours ([decimal]'1.01');$script:scopeTaskId=[long]$task.task_id
        $child=Add-TaskPilotSubtask -Store $script:scopeStore -TaskId $task.task_id -ExpectedVersion $task.row_version -Title 'SYNTHETIC LOCAL CHILD'
        $null=Add-TaskPilotWorkLog -Store $script:scopeStore -TaskId $task.task_id -ExpectedVersion $child.Task.row_version -WorkDate '2026-11-23' -Hours ([decimal]'0.25')
        Close-LocalScopeStore;$script:scopeStore=Open-TaskPilotStore -DatabasePath $script:scopeDatabase
        $task=@(Get-TaskPilotTask -Store $script:scopeStore -TaskId $script:scopeTaskId)[0]
        Assert-LocalScope ($task.title-ceq'SYNTHETIC LOCAL TASK'-and$task.estimated_hours-eq[decimal]'1.01') 'Task or exact hour data was lost.'
        Assert-LocalScope (@(Get-TaskPilotSubtask -Store $script:scopeStore -TaskId $task.task_id).Count-eq1-and@(Get-TaskPilotWorkLog -Store $script:scopeStore -TaskId $task.task_id)[0].hours-eq[decimal]'0.25') 'Child or work log data was lost.'
        Close-LocalScopeStore;$script:scopeStore=Open-TaskPilotStore -DatabasePath $script:scopeDatabase -ReadOnly
        Reject-LocalScope {Add-TaskPilotTask -Store $script:scopeStore -Title 'FORBIDDEN' -RegisteredOn '2026-11-23'} 'read.only'
        Close-LocalScopeStore;$script:scopeStore=Open-TaskPilotStore -DatabasePath $script:scopeDatabase
    }
    Case-LocalScope 'L04' 'A late transaction failure leaves local memory and durable bytes unchanged' {
        $before=Hash-LocalScope ($script:scopeBroker.ReadAllBytes($script:scopeDatabase));$task=@(Get-TaskPilotTask -Store $script:scopeStore -TaskId $script:scopeTaskId)[0]
        Reject-LocalScope {Invoke-TaskPilotTransaction -Store $script:scopeStore -Action {
            param($s)
            $null=Set-TaskPilotTask -Store $s -TaskId $script:scopeTaskId -ExpectedVersion $task.row_version -Title 'MUST ROLL BACK'
            $null=Local-Sql $s "INSERT INTO monthly_snapshots(calendar_id,month_key,current_revision) VALUES(1,'2026-11',999)" -Mode NonQuery
        }} '.'
        $after=@(Get-TaskPilotTask -Store $script:scopeStore -TaskId $script:scopeTaskId)[0]
        Assert-LocalScope ($after.title-ceq$task.title-and$after.row_version-eq$task.row_version-and(Hash-LocalScope ($script:scopeBroker.ReadAllBytes($script:scopeDatabase)))-ceq$before) 'A failed transaction changed task state or durable bytes.'
        Close-LocalScopeModule
    }
    Case-LocalScope 'L05' 'Normal independent and acceptance paths are refused before data reads' {
        $script:scopeBroker.Dispose();$script:scopeBroker=$null
        foreach($forbidden in @((Join-Path $profile 'TaskPilot4/Data/synthetic-normal.txt'),(Join-Path (Join-Path (Join-Path $profile 'TaskPilotTest') $script:scopeEnvironmentId) 'Data/historical-synthetic.db'),(Join-Path (Join-Path (Join-Path $profile 'TaskPilotAcceptance') $script:scopeEnvironmentId) 'Data/historical-synthetic.db'))){
            $script:scopeBroker=[TaskPilot.Runtime.Sandbox]::CreateLocalValidation($profile,$script:scopeEnvironmentId)
            Reject-LocalScope {$script:scopeBroker.ReadAllBytes($forbidden)} 'outside this test environment'
            Assert-LocalScope $script:scopeBroker.IsFaulted 'Cross-scope access did not fault the broker.'
            $script:scopeBroker.Dispose();$script:scopeBroker=$null
        }
        $script:scopeBroker=[TaskPilot.Runtime.Sandbox]::CreateLocalValidation($profile,$script:scopeEnvironmentId)
    }
    Case-LocalScope 'L06' 'Same-ID independent and acceptance images copied to local scope are refused without retagging' {
        Use-LocalScopeModule $script:scopeBroker
        foreach($kind in @('independent','acceptance')){
            $bytes=if($kind-ceq'independent'){$script:independentBytes}else{$script:acceptanceBytes}
            $path=Join-Path $script:scopeBroker.Data ('foreign-'+$kind+'.db');$script:scopeBroker.WriteNew($path,$bytes);$before=Hash-LocalScope $bytes
            Reject-LocalScope {Open-TaskPilotStore -DatabasePath $path} 'does not belong to this local validation environment'
            Assert-LocalScope ((Hash-LocalScope ($script:scopeBroker.ReadAllBytes($path)))-ceq$before) 'A rejected foreign database was retagged or rewritten.'
        }
        $script:localBytes=$script:scopeBroker.ReadAllBytes($script:scopeDatabase);Close-LocalScopeModule
        $script:scopeBroker.Dispose();$script:scopeBroker=$null
    }
    Case-LocalScope 'L07' 'Local images cannot be adopted by old purposes or opened as normal data' {
        $reverseProfile=Join-Path $fixture 'SyntheticReverseProfile';$null=[IO.Directory]::CreateDirectory($reverseProfile)
        foreach($kind in @('independent','acceptance')){
            $scope=if($kind-ceq'independent'){[TaskPilot.Runtime.Sandbox]::Create($reverseProfile,$script:scopeEnvironmentId)}else{[TaskPilot.Runtime.Sandbox]::CreateAcceptance($reverseProfile,$script:scopeEnvironmentId)}
            try{
                $path=Join-Path $scope.Data 'foreign-local.db';$scope.WriteNew($path,$script:localBytes);$before=Hash-LocalScope $script:localBytes
                Use-LocalScopeModule $scope
                Reject-LocalScope {Open-TaskPilotStore -DatabasePath $path} 'does not belong to this independent test environment'
                Assert-LocalScope ((Hash-LocalScope ($scope.ReadAllBytes($path)))-ceq$before) 'An old purpose rewrote or retagged a local database.'
                Close-LocalScopeModule
            }finally{$scope.Dispose()}
        }
        $normalCopy=Join-Path $reverseProfile 'local-image-as-normal.db';[IO.File]::WriteAllBytes($normalCopy,$script:localBytes);$before=Get-TPBuildSha $normalCopy
        $script:scopeModule=Import-Module (Join-Path $repo 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force -PassThru
        Reject-LocalScope {Open-TaskPilotStore -DatabasePath $normalCopy -ReadOnly} 'local validation database cannot be opened as a normal'
        Assert-LocalScope ((Get-TPBuildSha $normalCopy)-ceq$before) 'Normal readonly rejection rewrote a local database.'
        Close-LocalScopeModule
    }
    Case-LocalScope 'L08' 'Readonly local reopen preserves identity and a missing local environment is not created' {
        $script:scopeBroker=[TaskPilot.Runtime.Sandbox]::OpenExistingLocalValidation($profile,$script:scopeEnvironmentId)
        Assert-LocalScope ($script:scopeBroker.IsReadOnly-and$script:scopeBroker.IsLocalValidation-and$script:scopeBroker.ReadAllText((Join-Path $script:scopeBroker.Export 'local-synthetic.txt'))-ceq'SYNTHETIC LOCAL ONLY') 'Readonly reopening selected the wrong purpose.'
        . (Join-Path $repo 'local-validation/TaskPilot.LocalValidation.Diagnostics.ps1')
        Reject-LocalScope {Get-TPLocalValidationDiagnosticSummaryFromSandbox -Sandbox $script:scopeBroker} 'READONLY-REQUIRED'
        $lockBefore=Hash-LocalScope ($script:scopeBroker.ReadAllBytes($script:scopeBroker.LockPath))
        $diagnosticLease=$script:scopeBroker.AcquireExistingLocalValidationDiagnosticLock()
        try{
            Assert-LocalScope ($script:scopeBroker.HasLocalValidationDiagnosticLock-and-not$script:scopeBroker.HasAcceptanceDiagnosticLock) 'The local diagnostic lease was confused with formal acceptance.'
            $summary=Get-TPLocalValidationDiagnosticSummaryFromSandbox -Sandbox $script:scopeBroker
            Assert-LocalScope ($summary.Purpose-ceq'LocalDeveloperValidationSyntheticOnly'-and$summary.EventCounts.ACTION-eq1-and$summary.EventCounts.OPERATION_FAILED-eq1-and-not$summary.RawLogsIncluded-and-not$summary.UserDataIncluded-and-not$summary.Uploaded) 'Native local diagnostic aggregation lost its purpose or content bounds.'
            Reject-LocalScope {$script:scopeBroker.AcquireExistingLocalValidationDiagnosticLock()} 'already held'
            Reject-LocalScope {$script:scopeBroker.AcquireExistingAcceptanceDiagnosticLock()} 'Read-only acceptance diagnostics'
            Reject-LocalScope {[TaskPilot.Runtime.Sandbox]::CreateLocalValidation($profile,$script:scopeEnvironmentId)} '.'
        }finally{$diagnosticLease.Dispose()}
        Assert-LocalScope (-not$script:scopeBroker.HasLocalValidationDiagnosticLock-and(Hash-LocalScope ($script:scopeBroker.ReadAllBytes($script:scopeBroker.LockPath)))-ceq$lockBefore) 'Read-only diagnostic locking changed lock bytes or retained its lease.'
        Reject-LocalScope {$script:scopeBroker.WriteNew((Join-Path $script:scopeBroker.Temp 'forbidden.txt'),[byte[]]@(1))} 'read.only'
        $script:scopeBroker.Dispose();$script:scopeBroker=$null
        $missingId=[guid]::NewGuid().ToString('N');$missing=Join-Path (Join-Path $profile 'TaskPilotLocalValidation') $missingId
        Reject-LocalScope {[TaskPilot.Runtime.Sandbox]::OpenExistingLocalValidation($profile,$missingId)} 'not found'
        Assert-LocalScope (-not[IO.Directory]::Exists($missing)) 'Readonly local reopening initialized a missing environment.'
        $noSessionId=[guid]::NewGuid().ToString('N');$noSession=[TaskPilot.Runtime.Sandbox]::CreateLocalValidation($profile,$noSessionId);$noSession.Dispose()
        $noSession=[TaskPilot.Runtime.Sandbox]::OpenExistingLocalValidation($profile,$noSessionId)
        try{
            Reject-LocalScope {$noSession.AcquireExistingLocalValidationDiagnosticLock()} 'Cannot open a test entry'
            Assert-LocalScope (-not$noSession.Exists($noSession.LockPath)) 'Diagnostics created a lock for a never-started local session.'
        }finally{$noSession.Dispose()}
    }
    Case-LocalScope 'L09' 'A wrong local purpose marker is preserved and refuses creation and reopening' {
        $script:scopeBroker=[TaskPilot.Runtime.Sandbox]::CreateLocalValidation($profile,$script:scopeEnvironmentId);$marker=$script:scopeBroker.MarkerPath
        $wrong="TaskPilot desktop acceptance synthetic-only environment v1`n"+$script:scopeEnvironmentId+"`n"
        $script:scopeBroker.AtomicWrite($marker,[Text.Encoding]::UTF8.GetBytes($wrong),$null);$script:scopeBroker.Dispose();$script:scopeBroker=$null
        Reject-LocalScope {[TaskPilot.Runtime.Sandbox]::CreateLocalValidation($profile,$script:scopeEnvironmentId)} 'identity marker does not match'
        Reject-LocalScope {[TaskPilot.Runtime.Sandbox]::OpenExistingLocalValidation($profile,$script:scopeEnvironmentId)} 'identity marker does not match'
        Assert-LocalScope ([IO.File]::ReadAllText($marker)-ceq$wrong) 'A rejected marker was repaired, moved or removed.'
    }
}finally{
    try{Close-LocalScopeModule}finally{if($null-ne$script:scopeBroker){$script:scopeBroker.Dispose();$script:scopeBroker=$null}}
}
$normalUnchanged=$true;foreach($leaf in @('TaskPilot','TaskPilot4','TaskPilot4Logs')){if((Snapshot-LocalScope (Join-Path $profile $leaf))-cne$normalBefore[$leaf]){$normalUnchanged=$false}}
$historicalUnchanged=$script:preservedScopes.Count-eq2
foreach($leaf in $script:preservedScopes.Keys){if((Snapshot-LocalScope (Join-Path $profile $leaf))-cne$script:preservedScopes[$leaf]){$historicalUnchanged=$false}}
$failures=@($cases|Where-Object {-not$_.Passed})
$report=[pscustomobject][ordered]@{Stage='Fixed local validation namespace and database purpose';Passed=($failures.Count-eq0-and$normalUnchanged-and$historicalUnchanged);Cases=$cases.ToArray();FailedCases=$failures.Count;Checks=$checks;RuntimeAssemblySha256=$runtimeSha;NormalFixtureUnchanged=$normalUnchanged;PreviousIndependentAndAcceptanceFixturesUnchanged=$historicalUnchanged;SnapshotIncludes=@('FileSha256','FileLength','DirectoryStructure','OwnerGroupAndDaclSddl');ProductionProfileAccessed=$false;ApplicationLaunched=$false;Windows10And11Verified=$false;SkippedDetails=@();TestRoot=$fixture}
Write-TPBuildNewText (Join-Path $output ('LocalValidationScope_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 12)
return $report
