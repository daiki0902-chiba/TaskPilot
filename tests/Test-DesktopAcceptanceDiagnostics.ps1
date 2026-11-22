#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputRoot,[string]$RuntimeAssembly)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
$checks=0
function Assert-Diagnostic($Condition,[string]$Name){if(-not$Condition){throw ('Diagnostic assertion failed: '+$Name)};$script:checks++}
# Synthetic in-memory broker; no profile path or real logs are touched.
$broker=[pscustomobject]@{Logs='synthetic-logs';IsFaulted=$false;Content='';LengthOverride=$null}
$broker|Add-Member ScriptMethod Exists {param($p)return $this.Content.Length-gt0}
$broker|Add-Member ScriptMethod GetFileLength {param($p)if($null-ne$this.LengthOverride){return [long]$this.LengthOverride};return [long][Text.Encoding]::UTF8.GetByteCount($this.Content)}
$broker|Add-Member ScriptMethod AppendText {param($p,$text)$this.Content+=$text}
$broker|Add-Member ScriptMethod ReadAllTextLimited {param($p,$maximum)return $this.Content}
$script:TPRuntimeContext=[pscustomobject]@{IsAcceptance=$true;IsTestMode=$true;Sandbox=$broker}
. (Join-Path $repo 'acceptance/TaskPilot.Acceptance.Diagnostics.ps1')
Write-ActionLog 'PRIVATE-CUSTOMER' 'C:\Users\Private\Business.db sensitive memo'
Write-ErrorLog ([pscustomobject]@{Exception=[Exception]::new('private SQL and task name');ScriptStackTrace='private-path'})
Write-TPAcceptanceEvent SESSION_STARTED
$summary=Get-TPAcceptanceDiagnosticSummary
Assert-Diagnostic ($summary.EventCounts.ACTION-eq1-and$summary.EventCounts.OPERATION_FAILED-eq1-and$summary.EventCounts.SESSION_STARTED-eq1) 'Only fixed event counters persist'
Assert-Diagnostic ($broker.Content-notmatch'PRIVATE|sensitive|Users|Business|SQL|private') 'Raw details discarded'
Assert-Diagnostic (-not$summary.RawLogsIncluded-and-not$summary.UserDataIncluded-and-not$summary.Uploaded) 'No raw data or upload'
Assert-Diagnostic (($summary|ConvertTo-Json -Depth 5)-notmatch'Users|private|Business') 'Summary has no paths or task details'
$broker.Content='{"FormatVersion":1,"Code":"ACTION","Memo":"business"}'
$failed=$false;try{$null=Get-TPAcceptanceDiagnosticSummary}catch{$failed=$true}
Assert-Diagnostic $failed 'Injected JSON fields rejected'
$broker.Content='{"FormatVersion":1,"Code":"SECRET"}'
$failed=$false;try{$null=Get-TPAcceptanceDiagnosticSummary}catch{$failed=$true}
Assert-Diagnostic $failed 'Unknown event code rejected'
$broker.Content=('x'*65537);$broker.LengthOverride=0
$failed=$false;try{$null=Get-TPAcceptanceDiagnosticSummary}catch{$failed=$true}
Assert-Diagnostic $failed 'Parser also refuses a falsely underreported byte length'
$broker.Content='{"FormatVersion":1,"Code":"SECRET"}'
$broker.LengthOverride=65537
$failed=$false;try{$null=Get-TPAcceptanceDiagnosticSummary}catch{$failed=$true}
Assert-Diagnostic $failed 'Oversize reads refused'
$before=$broker.Content;Write-ActionLog 'anything' 'anything'
Assert-Diagnostic ($broker.Content-ceq$before) 'Bounded persistent log'
$broker.LengthOverride=65535;Write-ActionLog 'anything' 'anything'
Assert-Diagnostic ($broker.Content-ceq$before) 'Last append cannot exceed the byte budget'
$broker.LengthOverride=$null;$broker.IsFaulted=$true
$failed=$false;try{Write-ActionLog 'anything' 'anything'}catch{$failed=$true}
Assert-Diagnostic $failed 'Faulted broker refuses logging'
$script:TPRuntimeContext.IsAcceptance=$false;$broker.IsFaulted=$false
$failed=$false;try{Write-ActionLog 'anything' 'anything'}catch{$failed=$true}
Assert-Diagnostic $failed 'No normal-mode diagnostic fallback'
$report=& (Join-Path $repo 'tools/Collect-TaskPilotDesktopAcceptanceLogs.ps1') -PackageRoot $repo
Assert-Diagnostic ($report.Status-ceq'BLOCKED'-and-not$report.ProfileAccessed-and-not$report.UserDataIncluded-and-not$report.Uploaded) 'Standalone collector blocked without profile access'
$nativeExecuted=$false;$nativeChecks=0;$nativeCases=New-Object 'Collections.Generic.List[object]';$normalUnchanged=$true;$runtimeSha=$null
if($RuntimeAssembly){
    if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'Native diagnostic reopen tests require x64 Windows PowerShell Desktop 5.1.'}
    if(-not$OutputRoot){throw 'An existing synthetic output directory is required for native diagnostic tests.'}
    . (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
    $runtimePath=Get-TPBuildFullPath $RuntimeAssembly;Assert-TPBuildNoLinks $runtimePath
    $runtimeSha=Get-TPBuildSha $runtimePath;$assembly=[Reflection.Assembly]::LoadFrom($runtimePath)
    if(-not[string]::Equals($assembly.Location,$runtimePath,[StringComparison]::OrdinalIgnoreCase)-or(Get-TPBuildSha $assembly.Location)-cne$runtimeSha){throw 'Native diagnostic tests must use the exact internal-package runtime.'}
    $fixture=Join-Path (Get-TPBuildFullPath $OutputRoot) ('DiagnosticReopen_'+[guid]::NewGuid().ToString('N'))
    $profile=Join-Path $fixture 'SyntheticLocalAppData';$normal=Join-Path $profile 'TaskPilot4'
    $null=[IO.Directory]::CreateDirectory($normal);$normalFile=Join-Path $normal 'synthetic-normal-data.txt'
    [IO.File]::WriteAllText($normalFile,'SYNTHETIC NORMAL DATA AND PRIVATE TEXT MUST NOT BE COLLECTED')
    $beforeHash=Get-TPBuildSha $normalFile;$beforeAcl=[string](Get-Acl -LiteralPath $normalFile).Sddl
    $beforeDirectoryAcl=[string](Get-Acl -LiteralPath $normal).Sddl
    function Assert-NativeDiagnostic([bool]$Condition,[string]$Name){Assert-Diagnostic $Condition $Name;$script:nativeChecks++}
    function Case-NativeDiagnostic([string]$CaseId,[scriptblock]$Operation){
        &$Operation;$nativeCases.Add([pscustomobject]@{Id=$CaseId;Passed=$true})
    }
    function Reject-NativeDiagnostic([scriptblock]$Operation){
        $denied=$false;try{$null=&$Operation}catch{$denied=$true}
        Assert-NativeDiagnostic $denied 'The native diagnostic boundary must reject this synthetic input.'
    }
    function Read-NativeDiagnosticSummary($Scope){
        $scopeLock=$Scope.AcquireExistingAcceptanceDiagnosticLock()
        try{return Get-TPAcceptanceDiagnosticSummaryFromSandbox -Sandbox $Scope}finally{$scopeLock.Dispose()}
    }
    $id=[guid]::NewGuid().ToString('N');$writer=$null;$reader=$null
    try{
        Case-NativeDiagnostic 'D01' {
            $script:writer=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$id)
            $script:TPRuntimeContext=[pscustomobject]@{IsAcceptance=$true;IsTestMode=$true;Sandbox=$script:writer}
            Write-ActionLog 'SYNTHETIC PRIVATE TASK' 'SYNTHETIC PRIVATE PATH'
            Write-ErrorLog ([Exception]::new('SYNTHETIC PRIVATE ERROR'))
            $preparedLock=$script:writer.AcquireLock($script:writer.LockPath);$preparedLock.Dispose()
            $script:writer.Dispose();$script:writer=$null
            $script:reader=[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$id)
            Reject-NativeDiagnostic {Get-TPAcceptanceDiagnosticSummaryFromSandbox -Sandbox $script:reader}
            $summary=Read-NativeDiagnosticSummary $script:reader
            Assert-NativeDiagnostic ($summary.EventCounts.ACTION-eq1-and$summary.EventCounts.OPERATION_FAILED-eq1) 'Native persisted counters reopen through the actual read-only broker.'
            Assert-NativeDiagnostic (($summary|ConvertTo-Json -Depth 5)-notmatch'PRIVATE|Users|TaskPilot4|synthetic-normal-data') 'The reopened summary contains no input data or paths.'
            Assert-NativeDiagnostic ($script:reader.IsReadOnly-and-not$summary.UserDataIncluded-and-not$summary.RawLogsIncluded-and-not$summary.Uploaded) 'Reopening is read-only and does not collect or upload raw data.'
            Reject-NativeDiagnostic {$script:reader.WriteNew((Join-Path $script:reader.Logs 'forbidden-write.txt'),[byte[]]@(1))}
            $script:reader.Dispose();$script:reader=$null
        }
        Case-NativeDiagnostic 'D02' {
            $emptyId=[guid]::NewGuid().ToString('N');$scope=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$emptyId)
            $preparedLock=$scope.AcquireLock($scope.LockPath);$preparedLock.Dispose();$scope.Dispose()
            $scope=[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$emptyId)
            try{
                $summary=Read-NativeDiagnosticSummary $scope
                Assert-NativeDiagnostic ($summary.EventCounts.ACTION-eq0-and-not$scope.Exists((Join-Path $scope.Logs 'acceptance-events.jsonl'))) 'Missing diagnostics remain missing and return empty counters.'
            }finally{$scope.Dispose()}
        }
        Case-NativeDiagnostic 'D03' {
            foreach($bad in @('{"FormatVersion":1,"Code":"ACTION","Memo":"SYNTHETIC PRIVATE MEMO"}','{"FormatVersion":1,"Code":"UNKNOWN"}')){
                $scope=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$id)
                try{$scope.AtomicWrite((Join-Path $scope.Logs 'acceptance-events.jsonl'),[Text.Encoding]::UTF8.GetBytes($bad),$null)}finally{$scope.Dispose()}
                $scope=[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$id)
                try{Reject-NativeDiagnostic {Read-NativeDiagnosticSummary $scope}}finally{$scope.Dispose()}
            }
        }
        Case-NativeDiagnostic 'D04' {
            $scope=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$id)
            try{$scope.AtomicWrite((Join-Path $scope.Logs 'acceptance-events.jsonl'),[Text.Encoding]::UTF8.GetBytes(('x'*65537)),$null)}finally{$scope.Dispose()}
            $scope=[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$id)
            try{
                Reject-NativeDiagnostic {Read-NativeDiagnosticSummary $scope}
                Reject-NativeDiagnostic {$scope.ReadAllTextLimited((Join-Path $scope.Logs 'acceptance-events.jsonl'),65536)}
            }finally{$scope.Dispose()}
        }
        Case-NativeDiagnostic 'D05' {
            $scope=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$id);$marker=$scope.MarkerPath
            $wrong="TaskPilot independent test environment v2`n"+$id+"`n"
            try{$scope.AtomicWrite($marker,[Text.Encoding]::UTF8.GetBytes($wrong),$null)}finally{$scope.Dispose()}
            $before=Get-TPBuildSha $marker
            Reject-NativeDiagnostic {[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$id)}
            Assert-NativeDiagnostic ((Get-TPBuildSha $marker)-ceq$before) 'A wrong purpose marker is neither repaired nor deleted.'
        }
        Case-NativeDiagnostic 'D06' {
            $missingId=[guid]::NewGuid().ToString('N');$missing=Join-Path (Join-Path $profile 'TaskPilotAcceptance') $missingId
            Reject-NativeDiagnostic {[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$missingId)}
            Assert-NativeDiagnostic (-not[IO.Directory]::Exists($missing)) 'The read-only opener never initializes a missing environment.'
        }
        Case-NativeDiagnostic 'D07' {
            $oldId=[guid]::NewGuid().ToString('N');$scope=[TaskPilot.Runtime.Sandbox]::Create($profile,$oldId);$scope.Dispose()
            $scope=[TaskPilot.Runtime.Sandbox]::OpenExisting($profile,$oldId)
            try{Reject-NativeDiagnostic {Get-TPAcceptanceDiagnosticSummaryFromSandbox -Sandbox $scope}}finally{$scope.Dispose()}
            $freshId=[guid]::NewGuid().ToString('N');$scope=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$freshId)
            try{Reject-NativeDiagnostic {Get-TPAcceptanceDiagnosticSummaryFromSandbox -Sandbox $scope}}finally{$scope.Dispose()}
        }
        Case-NativeDiagnostic 'D08' {
            $linkedProfile=Join-Path $fixture 'SyntheticLinkedProfile';$acceptanceNamespace=Join-Path $linkedProfile 'TaskPilotAcceptance';$null=[IO.Directory]::CreateDirectory($acceptanceNamespace)
            $linkedId=[guid]::NewGuid().ToString('N');$junction=Join-Path $acceptanceNamespace $linkedId
            # Junction creation needs no protection-setting change. The new
            # unowned namespace must be refused before any target content read.
            $null=New-Item -ItemType Junction -Path $junction -Value $normal -ErrorAction Stop
            Assert-NativeDiagnostic (([IO.File]::GetAttributes($junction)-band[IO.FileAttributes]::ReparsePoint)-ne0) 'A genuine native junction positive control exists.'
            Reject-NativeDiagnostic {[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($linkedProfile,$linkedId)}
        }
        Case-NativeDiagnostic 'D09' {
            $activeId=[guid]::NewGuid().ToString('N');$scope=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$activeId)
            $events=Join-Path $scope.Logs 'acceptance-events.jsonl';$scope.WriteNew($events,[Text.Encoding]::UTF8.GetBytes('{"FormatVersion":1,"Code":"ACTION"}'))
            $activeLock=$scope.AcquireLock($scope.LockPath);$lockPath=$scope.LockPath
            try{Reject-NativeDiagnostic {[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$activeId)}}finally{$activeLock.Dispose();$scope.Dispose()}
            $before=Get-TPBuildSha $lockPath;$scope=[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$activeId)
            try{
                $lease=$scope.AcquireExistingAcceptanceDiagnosticLock()
                try{
                    Assert-NativeDiagnostic $scope.HasAcceptanceDiagnosticLock 'A read-only existing lock lease is held.'
                    Reject-NativeDiagnostic {[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$activeId)}
                    $summary=Get-TPAcceptanceDiagnosticSummaryFromSandbox -Sandbox $scope
                    Assert-NativeDiagnostic ($summary.EventCounts.ACTION-eq1) 'The same environment can be read after the live GUI lock closes.'
                }finally{$lease.Dispose()}
                Assert-NativeDiagnostic (-not$scope.HasAcceptanceDiagnosticLock) 'Disposing a diagnostic lease releases the lock state.'
            }finally{$scope.Dispose()}
            Assert-NativeDiagnostic ((Get-TPBuildSha $lockPath)-ceq$before) 'Read-only lock acquisition does not write lock bytes.'
        }
        Case-NativeDiagnostic 'D10' {
            $scope=[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$activeId);$lease=$scope.AcquireExistingAcceptanceDiagnosticLock();$externalWriter=$null
            try{
                $events=Join-Path $scope.Logs 'acceptance-events.jsonl'
                # Request only data-write access. GenericWrite also requests
                # WRITE_ATTRIBUTES/WRITE_EA, deliberately denied by the broker.
                $externalWriter=[IO.FileStream]::new($events,[IO.FileMode]::Open,[Security.AccessControl.FileSystemRights]::WriteData,[IO.FileShare]::ReadWrite,4096,[IO.FileOptions]::None)
                Reject-NativeDiagnostic {Get-TPAcceptanceDiagnosticSummaryFromSandbox -Sandbox $scope}
                $externalWriter.Dispose();$externalWriter=$null
                Assert-NativeDiagnostic ((Get-TPAcceptanceDiagnosticSummaryFromSandbox -Sandbox $scope).EventCounts.ACTION-eq1) 'Bounded reading succeeds after a competing raw writer closes.'
            }finally{if($null-ne$externalWriter){$externalWriter.Dispose()};$lease.Dispose();$scope.Dispose()}
        }
        Case-NativeDiagnostic 'D11' {
            $neverStartedId=[guid]::NewGuid().ToString('N');$scope=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$neverStartedId);$scope.Dispose()
            $scope=[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$neverStartedId)
            try{
                Reject-NativeDiagnostic {$scope.AcquireExistingAcceptanceDiagnosticLock()}
                Assert-NativeDiagnostic (-not$scope.Exists($scope.LockPath)) 'A missing GUI lock file is not initialized or repaired by diagnostics.'
            }finally{$scope.Dispose()}
        }
    }finally{foreach($scope in @($script:reader,$script:writer)){if($null-ne$scope){$scope.Dispose()}}}
    $normalUnchanged=(Get-TPBuildSha $normalFile)-ceq$beforeHash-and[string](Get-Acl -LiteralPath $normalFile).Sddl-ceq$beforeAcl-and
        [string](Get-Acl -LiteralPath $normal).Sddl-ceq$beforeDirectoryAcl-and[IO.Directory]::GetFileSystemEntries($normal).Length-eq1
    Assert-NativeDiagnostic $normalUnchanged 'The synthetic normal sentinel bytes and owner/DACL remain unchanged.'
    $nativeExecuted=$true
}
$result=[pscustomobject]@{Suite='DesktopAcceptanceDiagnostics';Passed=$true;Checks=$checks;NativeReadonlyReopenExecuted=$nativeExecuted;NativeReadonlyChecks=$nativeChecks;NativeCases=$nativeCases.ToArray();RuntimeAssemblySha256=$runtimeSha;NormalFixtureUnchanged=$normalUnchanged;ProductionProfileAccessed=$false;GuiExecuted=$false;PositiveProductionAuthorizationVerified=$false}
if($OutputRoot){$null=[IO.Directory]::CreateDirectory($OutputRoot);[IO.File]::WriteAllText((Join-Path $OutputRoot ('DesktopAcceptanceDiagnostics_'+[guid]::NewGuid().ToString('N')+'.json')),($result|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
$result
