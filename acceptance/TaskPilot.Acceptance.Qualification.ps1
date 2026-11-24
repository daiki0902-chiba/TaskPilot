#requires -Version 5.1
# A headless backend probe, not a launcher and not an authorization override.
# This file does not resolve KnownFolders, choose a profile, change a policy,
# or inspect the normal application's files. Its caller owns the verified broker.
function Get-TPAcceptanceQualificationReadiness {
    [CmdletBinding()]
    param()
    # Backend success cannot stand in for protected installation, authenticated
    # delivery, or native adversarial probes on the target client. No caller
    # Boolean/configuration value can manufacture the missing evidence.
    [pscustomobject][ordered]@{
        FormatVersion=1;Purpose='DesktopAcceptanceSyntheticOnly';Version='0.4.0.2'
        Status='BLOCKED';CanLaunch=$false;ProductionLaunchAuthorized=$false
        BackendProbeImplemented=$true;FullClientQualificationImplemented=$false
        RequiredCodes=@('TP-QUALIFICATION-PROTECTED-INSTALL-REQUIRED','TP-QUALIFICATION-CLIENT-BOUNDARY-PROTOCOL-REQUIRED')
        ProfileAccessed=$false;UserDataIncluded=$false
    }
}

function Invoke-TPAcceptanceQualificationCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Sandbox,
        [Parameter(Mandatory=$true)][Management.Automation.PSModuleInfo]$StorageModule
    )
    if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or
       $PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'TP-QUALIFICATION-WINDOWS-51-X64-REQUIRED'}
    if($Sandbox.GetType().FullName-cne'TaskPilot.Runtime.Sandbox'-or$Sandbox.IsReadOnly-or$Sandbox.IsDisposed-or$Sandbox.IsFaulted){throw 'TP-QUALIFICATION-ACCEPTANCE-BROKER-REQUIRED'}
    if($StorageModule.Name-cne'TaskPilot.Storage'){throw 'TP-QUALIFICATION-STORAGE-MODULE-REQUIRED'}
    $qualificationExpectedRoot=[IO.Path]::Combine([string]$Sandbox.ProfileRoot,'TaskPilotAcceptance',[string]$Sandbox.EnvironmentId)
    if($Sandbox.EnvironmentId-cnotmatch'^[a-f0-9]{32}$'-or
       -not[string]::Equals($Sandbox.Root,$qualificationExpectedRoot,[StringComparison]::OrdinalIgnoreCase)-or
       [IO.Path]::GetFileName($Sandbox.MarkerPath)-cne'.taskpilot-acceptance-environment'){
        throw 'TP-QUALIFICATION-ACCEPTANCE-BROKER-REQUIRED'
    }
    $Sandbox.ValidateTree()
    if($Sandbox.ReadAllText($Sandbox.MarkerPath)-cne("TaskPilot desktop acceptance synthetic-only environment v1`n"+$Sandbox.EnvironmentId+"`n")){throw 'TP-QUALIFICATION-ACCEPTANCE-BROKER-REQUIRED'}
    $qualificationFresh=& $StorageModule {
        return $null-eq$script:TPTestSandbox-and$null-eq$script:TPProvider-and$script:TPBoundaryConnections.Count-eq0-and$script:TPMemoryConnections.Count-eq0
    }
    if(-not$qualificationFresh){throw 'TP-QUALIFICATION-FRESH-STORAGE-MODULE-REQUIRED'}
    # A new GUID and exclusive broker creation make every probe independent.
    # Keep the probe as evidence; do not recursively delete or repair anything.
    $qualificationRunId=[guid]::NewGuid().ToString('N')
    $qualificationDirectory=Join-Path ([string]$Sandbox.Temp) ('qualification_'+$qualificationRunId)
    if($Sandbox.Exists($qualificationDirectory)){throw 'TP-QUALIFICATION-NEW-PROBE-DIRECTORY-REQUIRED'}
    $null=$Sandbox.EnsureDirectory($qualificationDirectory)
    $qualificationReport=& $StorageModule {
        param($qualificationBroker,[string]$qualificationDirectory,[string]$qualificationRunId)
        $qualificationCases=New-Object 'Collections.Generic.List[object]'
        $qualificationCounters=@{Checks=0}
        $qualificationState=@{Store=$null;TaskId=0;LastVersion=0}
        $qualificationDatabase=Join-Path $qualificationDirectory 'synthetic-probe.db'
        function Assert-TPQualificationProbe([bool]$Condition){
            $qualificationCounters.Checks++
            if(-not$Condition){throw 'TP-QUALIFICATION-ASSERTION'}
        }
        function Invoke-TPQualificationProbe([string]$CaseId,[scriptblock]$Action){
            try{&$Action;$qualificationCases.Add([pscustomobject]@{Id=$CaseId;Passed=$true;Code=('TP-QUALIFICATION-'+$CaseId+'-PASSED')})}
            catch{$qualificationCases.Add([pscustomobject]@{Id=$CaseId;Passed=$false;Code=('TP-QUALIFICATION-'+$CaseId+'-FAILED')})}
        }
        try{
            Set-TaskPilotTestSandbox $qualificationBroker
            Invoke-TPQualificationProbe 'Q01' {
                $created=New-TaskPilotDatabase -DatabasePath $qualificationDatabase
                Assert-TPQualificationProbe ($created.SchemaVersion-eq40001-and-not$created.TestOnly-and-not$created.LegacyDataImported)
                $qualificationState.Store=Open-TaskPilotStore -DatabasePath $qualificationDatabase
                $info=Get-TaskPilotStoreInfo $qualificationState.Store
                Assert-TPQualificationProbe ($info.SchemaVersion-eq40001-and$info.Tables-eq26)
                Assert-TPQualificationProbe ([long](Invoke-TPSql $qualificationState.Store 'PRAGMA application_id' -Mode Scalar)-eq1414547788)
                $databases=@(Invoke-TPSql $qualificationState.Store 'PRAGMA database_list')
                Assert-TPQualificationProbe ($databases.Count-eq1-and$databases[0].name-ceq'main'-and[string]::IsNullOrEmpty([string]$databases[0].file))
                Assert-TPQualificationProbe ($qualificationState.Store.Connection.ConnectionString-match'Data Source=:memory:')
                Assert-TPQualificationProbe ([long](Invoke-TPSql $qualificationState.Store 'PRAGMA temp_store' -Mode Scalar)-eq2)
            }
            Invoke-TPQualificationProbe 'Q02' {
                $task=Add-TaskPilotTask -Store $qualificationState.Store -Title 'SYNTHETIC ACCEPTANCE PROBE' -RegisteredOn '2026-01-02' -EstimatedHours ([decimal]'1.01')
                $qualificationState.TaskId=[long]$task.task_id
                $child=Add-TaskPilotSubtask -Store $qualificationState.Store -TaskId $task.task_id -ExpectedVersion $task.row_version -Title 'SYNTHETIC CHILD'
                $log=Add-TaskPilotWorkLog -Store $qualificationState.Store -TaskId $task.task_id -ExpectedVersion $child.Task.row_version -WorkDate '2026-01-02' -Hours ([decimal]'0.25')
                $qualificationState.LastVersion=[long]$log.Task.row_version
                Assert-TPQualificationProbe (@(Get-TaskPilotSubtask -Store $qualificationState.Store -TaskId $task.task_id).Count-eq1)
                Assert-TPQualificationProbe (@(Get-TaskPilotWorkLog -Store $qualificationState.Store -TaskId $task.task_id)[0].hours-eq[decimal]'0.25')
                Assert-TPQualificationProbe (@(Get-TaskPilotTask -Store $qualificationState.Store -TaskId $task.task_id)[0].estimated_hours-eq[decimal]'1.01')
            }
            Invoke-TPQualificationProbe 'Q03' {
                $beforeBytes=[Convert]::ToBase64String($qualificationBroker.ReadAllBytes($qualificationDatabase))
                $transactionRejected=$false
                try{
                    Invoke-TaskPilotTransaction -Store $qualificationState.Store -Action {
                        param($transactionStore)
                        $null=Set-TaskPilotTask -Store $transactionStore -TaskId $qualificationState.TaskId -ExpectedVersion $qualificationState.LastVersion -Title 'SYNTHETIC ROLLBACK'
                        throw 'TP-QUALIFICATION-SYNTHETIC-ROLLBACK'
                    }
                }catch{$transactionRejected=$true}
                Assert-TPQualificationProbe $transactionRejected
                $task=@(Get-TaskPilotTask -Store $qualificationState.Store -TaskId $qualificationState.TaskId)[0]
                Assert-TPQualificationProbe ($task.title-ceq'SYNTHETIC ACCEPTANCE PROBE'-and$task.row_version-eq$qualificationState.LastVersion)
                Assert-TPQualificationProbe ([Convert]::ToBase64String($qualificationBroker.ReadAllBytes($qualificationDatabase))-ceq$beforeBytes)
            }
            Invoke-TPQualificationProbe 'Q04' {
                $secondWriter=$null;$writerRejected=$false
                try{$secondWriter=Open-TaskPilotStore -DatabasePath $qualificationDatabase}catch{$writerRejected=$true}
                finally{if($null-ne$secondWriter){Close-TaskPilotStore $secondWriter}}
                Assert-TPQualificationProbe $writerRejected
                $reader=Open-TaskPilotStore -DatabasePath $qualificationDatabase -ReadOnly
                try{
                    Assert-TPQualificationProbe ($reader.ReadOnly-and@(Get-TaskPilotTask -Store $reader).Count-eq1)
                    $readOnlyRejected=$false
                    try{$null=Add-TaskPilotTask -Store $reader -Title 'SYNTHETIC FORBIDDEN'}catch{$readOnlyRejected=$true}
                    Assert-TPQualificationProbe $readOnlyRejected
                }finally{Close-TaskPilotStore $reader}
            }
            Invoke-TPQualificationProbe 'Q05' {
                Close-TaskPilotStore $qualificationState.Store;$qualificationState.Store=$null
                $qualificationState.Store=Open-TaskPilotStore -DatabasePath $qualificationDatabase
                $task=@(Get-TaskPilotTask -Store $qualificationState.Store -TaskId $qualificationState.TaskId)[0]
                Assert-TPQualificationProbe ($task.title-ceq'SYNTHETIC ACCEPTANCE PROBE'-and$task.estimated_hours-eq[decimal]'1.01'-and$task.row_version-eq$qualificationState.LastVersion)
                Assert-TPQualificationProbe (@(Get-TaskPilotSubtask -Store $qualificationState.Store -TaskId $task.task_id).Count-eq1)
                Assert-TPQualificationProbe (@(Get-TaskPilotWorkLog -Store $qualificationState.Store -TaskId $task.task_id)[0].hours-eq[decimal]'0.25')
                Assert-TPQualificationProbe ((Invoke-TPSql $qualificationState.Store 'PRAGMA integrity_check' -Mode Scalar)-ceq'ok')
                Assert-TPQualificationProbe (@(Invoke-TPSql $qualificationState.Store 'PRAGMA foreign_key_check').Count-eq0)
                Assert-TPQualificationProbe (@($qualificationBroker.ListDirectory($qualificationDirectory)|Where-Object {$_.Name-match'-(wal|shm|journal)$'}).Count-eq0)
            }
            Invoke-TPQualificationProbe 'Q06' {
                # Exercise the authorizer without targeting any real or even
                # synthetic-normal file. This new subdirectory is the only I/O scope.
                $deniedDatabase=Join-Path $qualificationDirectory 'must-not-create.db'
                foreach($statement in @('ATTACH DATABASE @path AS forbidden','VACUUM main INTO @path')){
                    $rejected=$false
                    try{$null=Invoke-TPSql $qualificationState.Store $statement -Parameters @{path=$deniedDatabase} -Mode NonQuery}catch{$rejected=$true}
                    Assert-TPQualificationProbe $rejected
                    Assert-TPQualificationProbe (-not$qualificationBroker.Exists($deniedDatabase))
                }
                foreach($statement in @('PRAGMA temp_store=FILE','PRAGMA journal_mode=DELETE','PRAGMA writable_schema=ON')){
                    $rejected=$false;try{$null=Invoke-TPSql $qualificationState.Store $statement -Mode NonQuery}catch{$rejected=$true}
                    Assert-TPQualificationProbe $rejected
                }
            }
        }catch{
            # Mode binding/setup errors get a fixed code. Never return the
            # Exception/ErrorRecord, SQL, filenames or provider connection text.
            $qualificationCases.Add([pscustomobject]@{Id='Q00';Passed=$false;Code='TP-QUALIFICATION-SETUP-FAILED'})
        }finally{
            if($null-ne$qualificationState.Store-and-not$qualificationState.Store.Closed){
                try{Close-TaskPilotStore $qualificationState.Store}catch{
                    $qualificationCases.Add([pscustomobject]@{Id='Q99';Passed=$false;Code='TP-QUALIFICATION-CLOSE-FAILED'})
                }
            }
        }
        $qualificationFailed=@($qualificationCases|Where-Object {-not$_.Passed})
        $qualificationComplete=$qualificationCases.Count-eq6-and$qualificationFailed.Count-eq0
        [pscustomobject][ordered]@{
            FormatVersion=1;Purpose='DesktopAcceptanceSyntheticOnly';Version='0.4.0.2'
            Status=$(if($qualificationComplete){'BACKEND_PROBE_PASSED_GUI_BLOCKED'}else{'BACKEND_PROBE_FAILED_GUI_BLOCKED'})
            CorePassed=$qualificationComplete;Cases=$qualificationCases.ToArray();Checks=$qualificationCounters.Checks
            FailedCases=$qualificationFailed.Count;FullClientQualificationVerified=$false;ProductionLaunchAuthorized=$false
            GuiExecuted=$false;UserDataIncluded=$false;RunId=$qualificationRunId
        }
    } $Sandbox $qualificationDirectory $qualificationRunId
    return $qualificationReport
}

function Invoke-TPAcceptanceQualification {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Authority)
    $qualificationLauncher='TaskPilot.Acceptance.Launcher'-as[type]
    if($null-eq$qualificationLauncher-or-not$qualificationLauncher::IsDedicatedLauncher){throw 'TP-QUALIFICATION-DEDICATED-LAUNCHER-REQUIRED'}
    if($null-eq$Authority-or$Authority.Status-cne'AUTHORIZED_FOR_DESKTOP_ACCEPTANCE'-or$Authority.Purpose-cne'DesktopAcceptanceSyntheticOnly'){
        throw 'TP-QUALIFICATION-AUTHORITY-REQUIRED'
    }
    # Production integration is intentionally blocked BEFORE KnownFolder/profile
    # selection until OS-enforced installation and the complete client-native
    # boundary protocol have been implemented and reviewed. The core's six
    # backend cases cannot replace those checks or grant a GUI launch.
    return Get-TPAcceptanceQualificationReadiness
}
