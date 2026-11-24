#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RuntimeAssembly,[Parameter(Mandatory=$true)][string]$OutputRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or-not[Environment]::Is64BitProcess){throw 'Native Windows PowerShell Desktop 5.1 x64 is required; no Windows result was produced.'}
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'An existing developer report directory is required.'}
$fixture=Join-Path $output ('AcceptanceSandbox_'+[guid]::NewGuid().ToString('N'))
$profile=Join-Path $fixture 'SyntheticLocalAppData';$null=[IO.Directory]::CreateDirectory($profile)
$runtimePath=Get-TPBuildFullPath $RuntimeAssembly;Assert-TPBuildNoLinks $runtimePath
$runtimeSha=Get-TPBuildSha $runtimePath;$loaded=[Reflection.Assembly]::LoadFrom($runtimePath)
if(-not[string]::Equals([IO.Path]::GetFullPath($loaded.Location),$runtimePath,[StringComparison]::OrdinalIgnoreCase)-or(Get-TPBuildSha $loaded.Location)-cne$runtimeSha){throw 'The acceptance suite must execute the exact packaged runtime assembly.'}
$cases=New-Object 'Collections.Generic.List[object]';$checks=0
function Assert-AcceptanceSandbox([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw $Message}}
function Reject-AcceptanceSandbox([scriptblock]$Action,[string]$Pattern){
    $failure=$null;try{$null=&$Action}catch{$failure=$_}
    Assert-AcceptanceSandbox ($null-ne$failure-and$failure.Exception.Message-match$Pattern) ('A required boundary refusal was missing: '+$Pattern)
}
function Case-AcceptanceSandbox([string]$CaseId,[string]$Name,[scriptblock]$Action){
    # PowerShell uses dynamic scope: a parameter named Id would shadow the
    # fixture's signed-environment-shaped $id inside the caller scriptblock.
    try{&$Action;$cases.Add([pscustomobject]@{Id=$CaseId;Name=$Name;Passed=$true});Write-Host ('PASS: '+$CaseId+' '+$Name)}
    catch{$cases.Add([pscustomobject]@{Id=$CaseId;Name=$Name;Passed=$false;Error=$_.Exception.ToString();Stack=$_.ScriptStackTrace});Write-Host ('FAIL: '+$CaseId+' '+$_.Exception.Message)}
}
function Snapshot-AcceptanceSandbox([string]$Path){
    $records=New-Object 'Collections.Generic.List[string]'
    $records.Add('DIRECTORY . ACL '+[string](Get-Acl -LiteralPath $Path).Sddl)
    foreach($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force|Sort-Object FullName)){
        if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Synthetic snapshot must not follow a link.'}
        $relative=$item.FullName.Substring($Path.Length+1).Replace('\','/')
        $acl=[string](Get-Acl -LiteralPath $item.FullName).Sddl
        if($item.PSIsContainer){$records.Add('DIRECTORY '+$relative+' ACL '+$acl)}
        else{$records.Add('FILE '+$relative+' '+[string]$item.Length+' '+(Get-TPBuildSha $item.FullName)+' ACL '+$acl)}
    }
    return [string]::Join("`n",$records.ToArray())
}
# These are invented normal and previous-independent data. No actual profile,
# existing business data, registry user settings, or GUI process is inspected.
foreach($relative in @('TaskPilot/Data','TaskPilot4/Data','TaskPilot4/Backup','TaskPilot4Logs')){
    $dir=Join-Path $profile $relative;$null=[IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'synthetic-sentinel.txt'),'SYNTHETIC NORMAL DATA: '+$relative)
}
$normalBefore=@{};foreach($leaf in @('TaskPilot','TaskPilot4','TaskPilot4Logs')){$normalBefore[$leaf]=Snapshot-AcceptanceSandbox (Join-Path $profile $leaf)}
$id=[guid]::NewGuid().ToString('N');$old=$null;$acceptance=$null;$reader=$null;$oldBefore=$null
try{
    Case-AcceptanceSandbox 'A01' 'The same ID selects different fixed namespaces and purpose markers' {
        $script:old=[TaskPilot.Runtime.Sandbox]::Create($profile,$id)
        $script:old.WriteNew((Join-Path $script:old.Data 'previous-independent.txt'),[Text.Encoding]::UTF8.GetBytes('SYNTHETIC PREVIOUS INDEPENDENT DATA'))
        $preparedLock=$script:old.AcquireLock($script:old.LockPath);$preparedLock.Dispose()
        Assert-AcceptanceSandbox ($script:old.Root-ceq(Join-Path (Join-Path $profile 'TaskPilotTest') $id)) 'Existing independent namespace changed.'
        Assert-AcceptanceSandbox ($script:old.ReadAllText($script:old.MarkerPath)-ceq("TaskPilot independent test environment v2`n"+$id+"`n")) 'Existing independent marker changed.'
        $script:old.Dispose();$script:old=$null
        $script:oldBefore=Snapshot-AcceptanceSandbox (Join-Path $profile 'TaskPilotTest')
        $script:acceptance=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$id)
        Assert-AcceptanceSandbox ($script:acceptance.Root-ceq(Join-Path (Join-Path $profile 'TaskPilotAcceptance') $id)) 'Acceptance did not select its own fixed namespace.'
        Assert-AcceptanceSandbox ($script:acceptance.ReadAllText($script:acceptance.MarkerPath)-ceq("TaskPilot desktop acceptance synthetic-only environment v1`n"+$id+"`n")) 'Acceptance purpose marker is not distinct.'
        Assert-AcceptanceSandbox ([IO.Path]::GetFileName($script:acceptance.MarkerPath)-ceq'.taskpilot-acceptance-environment') 'Acceptance marker filename is not distinct.'
    }
    Case-AcceptanceSandbox 'A02' 'Every synthetic output stays in the acceptance namespace and lock is independent' {
        foreach($path in @($script:acceptance.Data,$script:acceptance.Export,$script:acceptance.Backup,$script:acceptance.Logs,$script:acceptance.Temp,$script:acceptance.Input)){
            $script:acceptance.WriteNew((Join-Path $path 'acceptance-synthetic.txt'),[Text.Encoding]::UTF8.GetBytes('SYNTHETIC ACCEPTANCE ONLY'))
            Assert-AcceptanceSandbox ($script:acceptance.ReadAllText((Join-Path $path 'acceptance-synthetic.txt'))-ceq'SYNTHETIC ACCEPTANCE ONLY') 'A synthetic output did not round-trip.'
        }
        $script:old=[TaskPilot.Runtime.Sandbox]::Create($profile,$id)
        $oldLock=$null;$acceptanceLock=$null
        try{
            $oldLock=$script:old.AcquireLock($script:old.LockPath)
            $acceptanceLock=$script:acceptance.AcquireLock($script:acceptance.LockPath)
            Assert-AcceptanceSandbox ($script:old.LockPath-cne$script:acceptance.LockPath-and$null-ne$oldLock-and$null-ne$acceptanceLock) 'Independent and acceptance locks collided.'
        }finally{if($null-ne$acceptanceLock){$acceptanceLock.Dispose()};if($null-ne$oldLock){$oldLock.Dispose()};$script:old.Dispose();$script:old=$null}
        $script:acceptance.Dispose();$script:acceptance=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$id)
        Assert-AcceptanceSandbox ($script:acceptance.ReadAllText((Join-Path $script:acceptance.Data 'acceptance-synthetic.txt'))-ceq'SYNTHETIC ACCEPTANCE ONLY') 'Acceptance restart lost its own data.'
    }
    Case-AcceptanceSandbox 'A03' 'Neither purpose can read the other purpose or ordinary data' {
        Reject-AcceptanceSandbox {$script:acceptance.ReadAllText((Join-Path (Join-Path (Join-Path $profile 'TaskPilotTest') $id) 'Data/previous-independent.txt'))} 'outside this test environment'
        Assert-AcceptanceSandbox $script:acceptance.IsFaulted 'Cross-purpose access did not fault the acceptance context.'
        $script:acceptance.Dispose();$script:acceptance=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$id)
        Reject-AcceptanceSandbox {$script:acceptance.ReadAllText((Join-Path $profile 'TaskPilot4/Data/synthetic-sentinel.txt'))} 'outside this test environment'
        $script:acceptance.Dispose();$script:acceptance=$null
        $script:old=[TaskPilot.Runtime.Sandbox]::Create($profile,$id)
        Reject-AcceptanceSandbox {$script:old.ReadAllText((Join-Path (Join-Path (Join-Path $profile 'TaskPilotAcceptance') $id) 'Data/acceptance-synthetic.txt'))} 'outside this test environment'
        Assert-AcceptanceSandbox $script:old.IsFaulted 'Reverse cross-purpose access did not fault the old context.'
        $script:old.Dispose();$script:old=$null
    }
    Case-AcceptanceSandbox 'A04' 'Read-only reopening is purpose specific and cannot write' {
        $script:reader=[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$id)
        Assert-AcceptanceSandbox ($script:reader.IsReadOnly-and$script:reader.ReadAllText((Join-Path $script:reader.Data 'acceptance-synthetic.txt'))-ceq'SYNTHETIC ACCEPTANCE ONLY') 'Acceptance read-only reopen selected the wrong data.'
        Reject-AcceptanceSandbox {$script:reader.WriteNew((Join-Path $script:reader.Data 'must-not-exist.txt'),[byte[]]@(1))} 'read-only'
        $script:reader.Dispose();$script:reader=$null
    }
    Case-AcceptanceSandbox 'A05' 'A mismatched purpose marker is preserved and blocks both reopening and creation' {
        $script:acceptance=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$id)
        $wrong="TaskPilot independent test environment v2`n"+$id+"`n"
        $marker=$script:acceptance.MarkerPath
        # Explicit corruption is confined to this synthetic acceptance fixture.
        $script:acceptance.AtomicWrite($marker,[Text.Encoding]::UTF8.GetBytes($wrong),$null)
        $script:acceptance.Dispose();$script:acceptance=$null
        Reject-AcceptanceSandbox {[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$id)} 'identity marker does not match'
        Reject-AcceptanceSandbox {[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$id)} 'identity marker does not match'
        Assert-AcceptanceSandbox ([IO.File]::ReadAllText($marker)-ceq$wrong) 'A rejected marker was repaired or discarded.'
    }
    Case-AcceptanceSandbox 'A06' 'A previous independent ID alone is never adopted by the acceptance opener' {
        Assert-AcceptanceSandbox ((Snapshot-AcceptanceSandbox (Join-Path $profile 'TaskPilotTest'))-ceq$script:oldBefore) 'Earlier acceptance operations changed the previous independent namespace before this deliberate new fixture.'
        $missing=[guid]::NewGuid().ToString('N');$script:old=[TaskPilot.Runtime.Sandbox]::Create($profile,$missing)
        $script:old.Dispose();$script:old=$null
        # Include this deliberate setup in the expected old-namespace snapshot.
        $script:oldBefore=Snapshot-AcceptanceSandbox (Join-Path $profile 'TaskPilotTest')
        Reject-AcceptanceSandbox {[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$missing)} 'not found'
        Assert-AcceptanceSandbox (-not[IO.Directory]::Exists((Join-Path (Join-Path $profile 'TaskPilotAcceptance') $missing))) 'The read-only acceptance opener created or adopted a directory.'
    }
}finally{
    foreach($scope in @($script:reader,$script:acceptance,$script:old)){if($null-ne$scope){$scope.Dispose()}}
}
$normalUnchanged=$true
foreach($leaf in @('TaskPilot','TaskPilot4','TaskPilot4Logs')){if((Snapshot-AcceptanceSandbox (Join-Path $profile $leaf))-cne$normalBefore[$leaf]){$normalUnchanged=$false}}
$oldUnchanged=$null-ne$oldBefore-and(Snapshot-AcceptanceSandbox (Join-Path $profile 'TaskPilotTest'))-ceq$oldBefore
$failed=@($cases|Where-Object {-not$_.Passed})
$report=[pscustomobject][ordered]@{Stage='Separate desktop acceptance synthetic namespace';Passed=($failed.Count-eq0-and$normalUnchanged-and$oldUnchanged);Cases=$cases.ToArray();FailedCases=$failed.Count;Checks=$checks;RuntimeAssemblySha256=$runtimeSha;SnapshotIncludes=@('DirectoryStructure','FileLength','FileSha256','OwnerGroupAndDaclSddl');NormalFixtureUnchanged=$normalUnchanged;PreviousIndependentFixtureUnchanged=$oldUnchanged;ProductionProfileAccessed=$false;ApplicationLaunched=$false;Windows10And11Verified=$false;SkippedDetails=@()}
Write-TPBuildNewText (Join-Path $output ('AcceptanceSandbox_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 10)
return $report
