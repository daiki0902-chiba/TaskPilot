#requires -Version 5.1
# Legacy-shaped task DTOs backed only by the active SQLite store.
# The host supplies Invoke-TPGuiSql and Invoke-TPGuiTransaction; this adapter never updates UI/reports.
function Initialize-TPGuiTaskState {
    if(-not(Test-Path variable:script:TPGuiTaskState) -or $null-eq$script:TPGuiTaskState -or -not[object]::ReferenceEquals($script:TPGuiTaskState.Store,$script:TPGuiStore)){
        $script:TPGuiTaskState=[pscustomobject]@{Store=$script:TPGuiStore;Partitions=@{};TaskSnapshots=@{};ReadOrder=(New-Object 'Collections.Generic.Queue[string]');Versions=@{};Children=@{};ChildSnapshots=@{};ChildReadOrder=(New-Object 'Collections.Generic.Queue[string]');Reserved=(New-Object 'Collections.Generic.HashSet[long]')}
    }
}
function Test-TPGuiField($Object,[string]$Name){
    if($null-eq$Object){return $false}
    if($Object-is[Collections.IDictionary]){return $Object.Contains($Name)}
    return $null-ne$Object.PSObject.Properties[$Name]
}
function ConvertTo-TPGuiId($Value){
    $id=[long]0;$text=[string]$Value
    if($text-cnotmatch'^[1-9][0-9]*$' -or -not[long]::TryParse($text,[ref]$id) -or $id-gt[int]::MaxValue){throw 'タスクIDが不正です。'}
    return $id
}
function ConvertFrom-TPGuiIsoDate($Value){if($null-eq$Value){return ''};return ([string]$Value).Replace('-','/')}
function ConvertTo-TPGuiHours100($Value,[long]$Maximum=10000000,[long]$Minimum=0){
    if($Value-is[double] -or $Value-is[single]){$text=$Value.ToString('R',[cultureinfo]::InvariantCulture)}
    elseif($Value-is[decimal] -or $Value-is[long] -or $Value-is[int]){$text=$Value.ToString([cultureinfo]::InvariantCulture)}
    else{throw '時間には数値を指定してください。'}
    $match=[regex]::Match($text,'^(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$')
    if(-not$match.Success){throw '時間が不正です。'}
    $digits=($match.Groups[2].Value+$match.Groups[3].Value).TrimStart('0')
    if($digits.Length-eq0){if($Minimum-gt0){throw '時間が範囲外です。'};return [long]0}
    $exponent=0
    if($match.Groups[4].Success -and -not[int]::TryParse($match.Groups[4].Value,[ref]$exponent)){throw '時間の指数が範囲外です。'}
    $shift=[long]$exponent-$match.Groups[3].Value.Length+2
    if($shift-ge0){if($digits.Length+$shift-gt19){throw '時間が範囲外です。'};$integer=$digits+('0'*[int]$shift)}
    else{$remove=-$shift;if($remove-gt$digits.Length -or $digits.Substring($digits.Length-[int]$remove)-match'[^0]'){throw '時間は0.01時間単位で指定してください。丸めて保存はしません。'};$integer=$digits.Substring(0,$digits.Length-[int]$remove)}
    if($match.Groups[1].Value-eq'-'){$integer='-'+$integer}
    $number=[long]0
    if(-not[long]::TryParse($integer,[ref]$number) -or $number-lt$Minimum -or $number-gt$Maximum){throw '時間が範囲外です。'}
    return $number
}
function Get-TPGuiPartition([string]$Path){
    if([string]::Equals($Path,[string]$TaskFile,[StringComparison]::OrdinalIgnoreCase)){return [long]0}
    if([string]::Equals($Path,[string]$ArchiveFile,[StringComparison]::OrdinalIgnoreCase)){return [long]1}
    throw 'SQLite画面ではTaskList/CompletedTask以外のタスク保存先を指定できません。'
}
function Get-TPGuiTaskRow([long]$Id,[switch]$AllowDeleted){
    $rows=@(Invoke-TPGuiSql -Sql 'SELECT * FROM tasks WHERE task_id=@id' -Parameters @{id=$Id})
    if($rows.Count-ne1 -or (-not$AllowDeleted -and $rows[0].is_deleted)){throw 'タスクが存在しないか削除済みです。再読込してください。'}
    return $rows[0]
}
function Get-TPGuiExpectedVersion([long]$Id,[long]$ExpectedVersion=0){
    Initialize-TPGuiTaskState
    if($ExpectedVersion-gt0){return $ExpectedVersion}
    if($script:TPGuiTaskState.Versions.ContainsKey([string]$Id)){return [long]$script:TPGuiTaskState.Versions[[string]$Id]}
    throw '編集開始時のタスク情報がありません。再読込してから保存してください。'
}
function Touch-TPGuiTask([long]$Id,[long]$ExpectedVersion){
    $changed=Invoke-TPGuiSql -Sql 'UPDATE tasks SET row_version=row_version+1,updated_at_utc=@now WHERE task_id=@id AND row_version=@version AND is_deleted=0' -Parameters @{id=$Id;version=$ExpectedVersion;now=[datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ',[cultureinfo]::InvariantCulture)} -Mode NonQuery
    if($changed-ne1){throw '競合: タスクが変更されました。再読込してから保存してください。'}
}
function ConvertTo-TPGuiTaskValues($Item){
    $title=[string](Get-TPGuiValue $Item 'Task');$priority=[string](Get-TPGuiValue $Item 'Priority');$status=[string](Get-TPGuiValue $Item 'Status')
    if([string]::IsNullOrWhiteSpace($title)){throw 'タスク名を入力してください。'}
    if(@('高','中','低')-cnotcontains$priority -or @('未着手','対応中','完了')-cnotcontains$status){throw '優先度または状態が不正です。'}
    return @{registered=(ConvertTo-TPGuiIsoDate (Get-TPGuiValue $Item 'Date'));title=$title;priority=$priority;status=$status;due=(ConvertTo-TPGuiIsoDate (Get-TPGuiValue $Item 'DueDate') -Optional);memo=[string](Get-TPGuiValue $Item 'Memo' '')}
}
function Read-Tasks([string]$path){
    Initialize-TPGuiTaskState
    $partition=Get-TPGuiPartition $path;$baseline=@{};$token=[guid]::NewGuid().ToString('N')
    foreach($row in @(Invoke-TPGuiSql -Sql 'SELECT * FROM tasks WHERE is_deleted=0 AND is_archived=@archive ORDER BY task_id' -Parameters @{archive=$partition})){
        $key=[string]$row.task_id;$baseline[$key]=[long]$row.row_version;$script:TPGuiTaskState.Versions[$key]=[long]$row.row_version
        [pscustomobject]@{ID=[long]$row.task_id;Date=(ConvertFrom-TPGuiIsoDate $row.registered_on);Task=$row.title;Priority=$row.priority;DueDate=(ConvertFrom-TPGuiIsoDate $row.due_on);Status=$row.status;Memo=$row.memo;TPRowVersion=[long]$row.row_version;TPIsArchived=[bool]$row.is_archived;TPReadToken=$token}
    }
    $script:TPGuiTaskState.TaskSnapshots[$token]=[pscustomobject]@{Partition=$partition;Rows=$baseline}
    $script:TPGuiTaskState.Partitions[[string]$partition]=$token
    $script:TPGuiTaskState.ReadOrder.Enqueue($token)
    while($script:TPGuiTaskState.ReadOrder.Count-gt128){$script:TPGuiTaskState.TaskSnapshots.Remove($script:TPGuiTaskState.ReadOrder.Dequeue())}
}
function Repair-NextTaskId {
    $seq=[long](Invoke-TPGuiSql -Sql "SELECT COALESCE(MAX(seq),0) FROM sqlite_sequence WHERE name='tasks'" -Mode Scalar)
    $max=[long](Invoke-TPGuiSql -Sql 'SELECT COALESCE(MAX(task_id),0) FROM tasks' -Mode Scalar)
    if($seq-lt$max -or $seq-gt[int]::MaxValue){throw 'タスクIDの採番情報が不正です。保存を中止しました。'}
}
function Reserve-TaskId {
    Initialize-TPGuiTaskState
    $id=Invoke-TPGuiTransaction {
        Repair-NextTaskId
        $count=[long](Invoke-TPGuiSql -Sql "SELECT COUNT(*) FROM sqlite_sequence WHERE name='tasks'" -Mode Scalar)
        if($count-gt1){throw 'タスクIDの採番情報が重複しています。'}
        $next=[long](Invoke-TPGuiSql -Sql "SELECT COALESCE(MAX(seq),0)+1 FROM sqlite_sequence WHERE name='tasks'" -Mode Scalar)
        if($next-gt[int]::MaxValue){throw 'タスクIDが上限に達しました。'}
        if($count-eq0){$null=Invoke-TPGuiSql -Sql "INSERT INTO sqlite_sequence(name,seq) VALUES('tasks',@id)" -Parameters @{id=$next} -Mode NonQuery}
        else{$null=Invoke-TPGuiSql -Sql "UPDATE sqlite_sequence SET seq=@id WHERE name='tasks'" -Parameters @{id=$next} -Mode NonQuery}
        return $next
    }
    $null=$script:TPGuiTaskState.Reserved.Add([long]$id)
    return [long]$id
}
function Save-Tasks([string]$path,[array]$items,[string]$ExpectedSnapshotToken=''){
    Initialize-TPGuiTaskState;$partition=Get-TPGuiPartition $path;$key=[string]$partition
    $token=$ExpectedSnapshotToken
    foreach($item in @($items)){
        $itemToken=[string](Get-TPGuiValue $item 'TPReadToken' '')
        if($itemToken-eq''){continue}
        if($token-ne'' -and $token-cne$itemToken){throw '異なる読込時点の一覧はまとめて保存できません。再読込してください。'}
        $token=$itemToken
    }
    if($token-eq''){
        if(-not$script:TPGuiTaskState.Partitions.ContainsKey($key)){throw '保存前の一覧を読み込んでください。'}
        $token=$script:TPGuiTaskState.Partitions[$key]
        if(-not$script:TPGuiTaskState.TaskSnapshots.ContainsKey($token) -or $script:TPGuiTaskState.TaskSnapshots[$token].Rows.Count-gt0){throw '全件削除を伴う保存には元のTPReadTokenをExpectedSnapshotTokenとして指定してください。'}
    }
    if(-not$script:TPGuiTaskState.TaskSnapshots.ContainsKey($token)){throw '一覧の読込情報が失効しました。再読込してください。'}
    $snapshot=$script:TPGuiTaskState.TaskSnapshots[$token]
    if($snapshot.Partition-ne$partition){throw '異なる一覧への移動は専用のアーカイブ操作を使用してください。'}
    $baseline=$snapshot.Rows
    $null=Invoke-TPGuiTransaction {
        $current=@{};foreach($row in @(Invoke-TPGuiSql -Sql 'SELECT * FROM tasks WHERE is_deleted=0 AND is_archived=@archive ORDER BY task_id' -Parameters @{archive=$partition})){$current[[string]$row.task_id]=$row}
        if($baseline.Count-ne$current.Count){throw '競合: タスク一覧が変更されています。再読込してください。'}
        foreach($id in $baseline.Keys){if(-not$current.ContainsKey($id) -or $current[$id].row_version-ne$baseline[$id]){throw '競合: タスク一覧が変更されています。再読込してください。'}}
        $seen=@{}
        foreach($item in @($items)){
            if($null-eq$item){throw '空のタスクを保存できません。'}
            $id=ConvertTo-TPGuiId (Get-TPGuiValue $item 'ID');$idKey=[string]$id
            if($seen.ContainsKey($idKey)){throw 'タスクIDが重複しています。'};$seen[$idKey]=$true
            $values=ConvertTo-TPGuiTaskValues $item;$values.id=$id;$values.archive=$partition
            $existing=@(Invoke-TPGuiSql -Sql 'SELECT * FROM tasks WHERE task_id=@id' -Parameters @{id=$id})
            if($existing.Count-eq0){
                if(-not$script:TPGuiTaskState.Reserved.Contains($id)){throw '未予約の新規タスクIDは保存できません。'}
                $sequence=[long](Invoke-TPGuiSql -Sql "SELECT MAX(seq) FROM sqlite_sequence WHERE name='tasks'" -Mode Scalar)
                if($sequence-lt$id){throw '予約したタスクIDは有効でなくなりました。'}
                $null=Invoke-TPGuiSql -Sql 'INSERT INTO tasks(task_id,registered_on,title,priority,status,due_on,memo,is_archived) VALUES(@id,@registered,@title,@priority,@status,@due,@memo,@archive)' -Parameters $values -Mode NonQuery
                $null=Invoke-TPGuiSql -Sql 'INSERT INTO task_plans(task_id) VALUES(@id)' -Parameters @{id=$id} -Mode NonQuery
                $null=$script:TPGuiTaskState.Reserved.Remove($id)
            }else{
                $old=$existing[0];$version=[long](Get-TPGuiValue $item 'TPRowVersion' 0)
                if($old.is_deleted -or $version-lt1 -or $old.row_version-ne$version){throw '競合: 編集開始時のタスクが変更されています。'}
                $same=$old.registered_on-ceq$values.registered -and $old.title-ceq$values.title -and $old.priority-ceq$values.priority -and $old.status-ceq$values.status -and $old.due_on-ceq$values.due -and $old.memo-ceq$values.memo -and $old.is_archived-eq$partition
                if(-not$same){Touch-TPGuiTask $id $version;$null=Invoke-TPGuiSql -Sql 'UPDATE tasks SET registered_on=@registered,title=@title,priority=@priority,status=@status,due_on=@due,memo=@memo,is_archived=@archive WHERE task_id=@id' -Parameters $values -Mode NonQuery}
            }
        }
        foreach($id in $baseline.Keys){if(-not$seen.ContainsKey($id)){Touch-TPGuiTask ([long]$id) ([long]$baseline[$id]);$null=Invoke-TPGuiSql -Sql 'UPDATE tasks SET is_deleted=1,deleted_at_utc=@now WHERE task_id=@id' -Parameters @{id=[long]$id;now=[datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ',[cultureinfo]::InvariantCulture)} -Mode NonQuery}}
    }
    $script:TPGuiTaskState.Partitions.Clear()
}
function Read-PlannedDates {
    Initialize-TPGuiTaskState;$map=@{}
    foreach($row in @(Invoke-TPGuiSql -Sql 'SELECT t.task_id,t.row_version,p.planned_on FROM tasks t LEFT JOIN task_plans p ON p.task_id=t.task_id WHERE t.is_deleted=0')){$key=[string]$row.task_id;$script:TPGuiTaskState.Versions[$key]=[long]$row.row_version;if($null-ne$row.planned_on){$map[$key]=ConvertFrom-TPGuiIsoDate $row.planned_on}}
    return $map
}
function Read-WorkPlans {
    Initialize-TPGuiTaskState;$map=@{}
    foreach($row in @(Invoke-TPGuiSql -Sql 'SELECT t.task_id,t.row_version,p.work_start_on,COALESCE(p.estimated_hours_x100,0) AS hours FROM tasks t LEFT JOIN task_plans p ON p.task_id=t.task_id WHERE t.is_deleted=0')){$key=[string]$row.task_id;$script:TPGuiTaskState.Versions[$key]=[long]$row.row_version;if($null-ne$row.work_start_on -or $row.hours-ne0){$map[$key]=[pscustomobject]@{StartDate=(ConvertFrom-TPGuiIsoDate $row.work_start_on);EstimatedHours=([decimal]$row.hours/100)}}}
    return $map
}
function Save-PlannedDate([string]$taskId,[string]$plannedDate,[long]$ExpectedVersion=0){
    $id=ConvertTo-TPGuiId $taskId;$version=Get-TPGuiExpectedVersion $id $ExpectedVersion;$date=ConvertTo-TPGuiIsoDate $plannedDate -Optional
    $null=Invoke-TPGuiTransaction {Touch-TPGuiTask $id $version;$null=Invoke-TPGuiSql -Sql 'INSERT INTO task_plans(task_id,planned_on) VALUES(@id,@date) ON CONFLICT(task_id) DO UPDATE SET planned_on=excluded.planned_on' -Parameters @{id=$id;date=$date} -Mode NonQuery}
    $script:TPGuiTaskState.Versions.Remove([string]$id)
}
function Save-WorkPlan([string]$taskId,[string]$startDate,[decimal]$hours,[long]$ExpectedVersion=0){
    $id=ConvertTo-TPGuiId $taskId;$version=Get-TPGuiExpectedVersion $id $ExpectedVersion;$date=ConvertTo-TPGuiIsoDate $startDate -Optional;$scaled=ConvertTo-TPGuiHours100 $hours
    $null=Invoke-TPGuiTransaction {Touch-TPGuiTask $id $version;$null=Invoke-TPGuiSql -Sql 'INSERT INTO task_plans(task_id,work_start_on,estimated_hours_x100) VALUES(@id,@date,@hours) ON CONFLICT(task_id) DO UPDATE SET work_start_on=excluded.work_start_on,estimated_hours_x100=excluded.estimated_hours_x100' -Parameters @{id=$id;date=$date;hours=$scaled} -Mode NonQuery}
    $script:TPGuiTaskState.Versions.Remove([string]$id)
}
function Read-ActualHours {
    Initialize-TPGuiTaskState;$map=@{}
    foreach($row in @(Invoke-TPGuiSql -Sql 'SELECT a.*,t.row_version FROM completion_actuals a JOIN tasks t ON t.task_id=a.task_id WHERE t.is_deleted=0')){$key=[string]$row.task_id;$script:TPGuiTaskState.Versions[$key]=[long]$row.row_version;$map[$key]=[pscustomobject]@{CompletedDate=(ConvertFrom-TPGuiIsoDate $row.completed_on);ActualHours=([decimal]$row.actual_hours_x100/100);TaskName=$row.task_name_snapshot}}
    return $map
}
function Save-ActualHours([string]$id,[datetime]$completedDate,[decimal]$hours,[string]$name,[long]$ExpectedVersion=0){
    $task=ConvertTo-TPGuiId $id;$version=Get-TPGuiExpectedVersion $task $ExpectedVersion;$scaled=ConvertTo-TPGuiHours100 $hours;$date=$completedDate.ToString('yyyy-MM-dd',[cultureinfo]::InvariantCulture)
    $null=Invoke-TPGuiTransaction {
        $current=Get-TPGuiTaskRow $task;if($current.status-cne'完了'){throw '完了実績は完了したタスクに入力してください。'}
        Touch-TPGuiTask $task $version
        $null=Invoke-TPGuiSql -Sql 'INSERT INTO completion_actuals(task_id,completed_on,actual_hours_x100,task_name_snapshot) VALUES(@id,@date,@hours,@name) ON CONFLICT(task_id) DO UPDATE SET completed_on=excluded.completed_on,actual_hours_x100=excluded.actual_hours_x100,task_name_snapshot=excluded.task_name_snapshot' -Parameters @{id=$task;date=$date;hours=$scaled;name=$name} -Mode NonQuery
    }
    $script:TPGuiTaskState.Versions.Remove([string]$task)
}
function Get-TPGuiChildRows([ValidateSet('subtasks','work_logs')][string]$Table){
    if($Table-eq'subtasks'){return @(Invoke-TPGuiSql -Sql 'SELECT s.*,t.row_version FROM subtasks s JOIN tasks t ON t.task_id=s.parent_task_id ORDER BY s.sort_order,s.subtask_id')}
    return @(Invoke-TPGuiSql -Sql 'SELECT s.*,t.row_version FROM work_logs s JOIN tasks t ON t.task_id=s.task_id ORDER BY s.sort_order,s.entry_id')
}
function ConvertTo-TPGuiChildValues($Item,[string]$Table){
    if($Table-eq'subtasks'){
        $key=[string](Get-TPGuiValue $Item 'Id');$parent=ConvertTo-TPGuiId (Get-TPGuiValue $Item 'ParentId');$title=[string](Get-TPGuiValue $Item 'Title');$done=Get-TPGuiValue $Item 'Done'
        # The GUI applies the legacy 200-character limit to newly entered titles.
        # Existing imported titles must remain readable and survive unrelated edits.
        if([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($title) -or $done-isnot[bool]){throw 'サブタスクID・名前・完了フラグが不正です。'}
        return @{key=$key;parent=$parent;title=$title;done=[long][int]$done}
    }
    $key=[string](Get-TPGuiValue $Item 'EntryId');if([string]::IsNullOrWhiteSpace($key)){throw '作業記録IDが空です。'}
    return @{key=$key;parent=(ConvertTo-TPGuiId (Get-TPGuiValue $Item 'TaskId'));date=(ConvertTo-TPGuiIsoDate (Get-TPGuiValue $Item 'WorkDate'));hours=(ConvertTo-TPGuiHours100 (Get-TPGuiValue $Item 'Hours') -Maximum 2400 -Minimum 1);memo=[string](Get-TPGuiValue $Item 'Memo' '')}
}
function ConvertFrom-TPGuiChildRow($Row,[string]$Table){
    if($Table-eq'subtasks'){return [pscustomobject]@{Id=$Row.subtask_id;ParentId=[string]$Row.parent_task_id;Title=$Row.title;Done=[bool]$Row.is_done;TPRowVersion=[long]$Row.row_version}}
    return [pscustomobject]@{EntryId=$Row.entry_id;TaskId=[string]$Row.task_id;WorkDate=(ConvertFrom-TPGuiIsoDate $Row.work_date);Hours=([decimal]$Row.hours_x100/100);Memo=$Row.memo;TPRowVersion=[long]$Row.row_version}
}
function Read-TPGuiChildren([string]$Table){
    Initialize-TPGuiTaskState;$baseline=@{};$versions=@{};$token=[guid]::NewGuid().ToString('N')
    foreach($parent in @(Invoke-TPGuiSql -Sql 'SELECT task_id,row_version FROM tasks WHERE is_deleted=0')){$versions[[string]$parent.task_id]=[long]$parent.row_version}
    foreach($row in @(Get-TPGuiChildRows $Table)){
        $dto=ConvertFrom-TPGuiChildRow $row $Table;$values=ConvertTo-TPGuiChildValues $dto $Table
        $baseline[$values.key]=$values;$versions[[string]$values.parent]=[long]$row.row_version
        $script:TPGuiTaskState.Versions[[string]$values.parent]=[long]$row.row_version
        $dto|Add-Member -NotePropertyName TPReadToken -NotePropertyValue $token
        $dto
    }
    $script:TPGuiTaskState.ChildSnapshots[$token]=[pscustomobject]@{Table=$Table;Rows=$baseline;Versions=$versions}
    $script:TPGuiTaskState.Children[$Table]=$token
    $script:TPGuiTaskState.ChildReadOrder.Enqueue($token)
    while($script:TPGuiTaskState.ChildReadOrder.Count-gt128){$script:TPGuiTaskState.ChildSnapshots.Remove($script:TPGuiTaskState.ChildReadOrder.Dequeue())}
}
function Read-Subtasks {Read-TPGuiChildren 'subtasks'}
function Read-WorkLogs {Read-TPGuiChildren 'work_logs'}
function Get-TPGuiLastChildSnapshotToken([ValidateSet('subtasks','work_logs')][string]$Table){
    Initialize-TPGuiTaskState
    if(-not$script:TPGuiTaskState.Children.ContainsKey($Table)){throw '子レコードの読込情報がありません。再読込してください。'}
    return [string]$script:TPGuiTaskState.Children[$Table]
}
function Test-TPGuiChildEqual($First,$Second){
    if($First.Count-ne$Second.Count){return $false}
    foreach($key in $First.Keys){if(-not$Second.ContainsKey($key) -or $First[$key]-cne$Second[$key]){return $false}}
    return $true
}
function Save-TPGuiChildren([string]$Table,[array]$Items,[string]$ExpectedSnapshotToken=''){
    Initialize-TPGuiTaskState
    $token=$ExpectedSnapshotToken
    foreach($item in @($Items)){
        $itemToken=[string](Get-TPGuiValue $item 'TPReadToken' '')
        if($itemToken-eq''){continue}
        if($token-ne'' -and $token-cne$itemToken){throw '異なる読込時点の子レコードはまとめて保存できません。'}
        $token=$itemToken
    }
    if($token-eq''){
        $token=Get-TPGuiLastChildSnapshotToken $Table
        if(-not$script:TPGuiTaskState.ChildSnapshots.ContainsKey($token) -or $script:TPGuiTaskState.ChildSnapshots[$token].Rows.Count-gt0){throw '子レコード全件削除にはExpectedSnapshotTokenを指定してください。'}
    }
    if(-not$script:TPGuiTaskState.ChildSnapshots.ContainsKey($token)){throw '子レコードの読込情報が失効しました。再読込してください。'}
    $snapshot=$script:TPGuiTaskState.ChildSnapshots[$token];$desired=@{}
    if($snapshot.Table-cne$Table){throw '異なる種類の子レコード読込情報は使用できません。'}
    foreach($item in @($Items)){$values=ConvertTo-TPGuiChildValues $item $Table;if($desired.ContainsKey($values.key)){throw '子レコードのIDが重複しています。'};$desired[$values.key]=$values}
    $null=Invoke-TPGuiTransaction {
        $current=@{}
        foreach($row in @(Get-TPGuiChildRows $Table)){$dto=ConvertFrom-TPGuiChildRow $row $Table;$values=ConvertTo-TPGuiChildValues $dto $Table;$current[$values.key]=$values}
        if($current.Count-ne$snapshot.Rows.Count){throw '競合: 子レコードが変更されています。再読込してください。'}
        foreach($key in $snapshot.Rows.Keys){if(-not$current.ContainsKey($key) -or -not(Test-TPGuiChildEqual $snapshot.Rows[$key] $current[$key])){throw '競合: 子レコードが変更されています。再読込してください。'}}
        $changedParents=@{}
        foreach($key in $desired.Keys){
            $values=$desired[$key]
            if($snapshot.Rows.ContainsKey($key)){
                if($snapshot.Rows[$key].parent-ne$values.parent){throw '子レコードの親タスクは変更できません。'}
                if(-not(Test-TPGuiChildEqual $snapshot.Rows[$key] $values)){$changedParents[[string]$values.parent]=$true}
            }else{$changedParents[[string]$values.parent]=$true}
        }
        foreach($key in $snapshot.Rows.Keys){if(-not$desired.ContainsKey($key)){$changedParents[[string]$snapshot.Rows[$key].parent]=$true}}
        foreach($parent in $changedParents.Keys){
            if(-not$snapshot.Versions.ContainsKey($parent)){throw '親タスクは子レコード読込後に追加または変更されました。再読込してください。'}
            $version=[long]$snapshot.Versions[$parent]
            Touch-TPGuiTask ([long]$parent) $version
        }
        $idColumn=if($Table-eq'subtasks'){'subtask_id'}else{'entry_id'}
        foreach($key in $snapshot.Rows.Keys){if(-not$desired.ContainsKey($key)){$null=Invoke-TPGuiSql -Sql ('DELETE FROM '+$Table+' WHERE '+$idColumn+'=@key') -Parameters @{key=$key} -Mode NonQuery}}
        $order=[long](Invoke-TPGuiSql -Sql ('SELECT COALESCE(MAX(sort_order),-1)+1 FROM '+$Table) -Mode Scalar)
        foreach($item in @($Items)){
            $values=ConvertTo-TPGuiChildValues $item $Table
            if($snapshot.Rows.ContainsKey($values.key) -and (Test-TPGuiChildEqual $snapshot.Rows[$values.key] $values)){continue}
            if($snapshot.Rows.ContainsKey($values.key)){
                $sql=if($Table-eq'subtasks'){'UPDATE subtasks SET title=@title,is_done=@done WHERE subtask_id=@key AND parent_task_id=@parent'}else{'UPDATE work_logs SET work_date=@date,hours_x100=@hours,memo=@memo WHERE entry_id=@key AND task_id=@parent'}
            }else{
                $values.order=$order;$order++
                $sql=if($Table-eq'subtasks'){'INSERT INTO subtasks(subtask_id,parent_task_id,title,is_done,sort_order) VALUES(@key,@parent,@title,@done,@order)'}else{'INSERT INTO work_logs(entry_id,task_id,work_date,hours_x100,memo,sort_order) VALUES(@key,@parent,@date,@hours,@memo,@order)'}
            }
            $n=Invoke-TPGuiSql -Sql $sql -Parameters $values -Mode NonQuery;if($n-ne1){throw '子レコードの保存対象が見つかりません。'}
        }
    }
    $script:TPGuiTaskState.Children.Remove($Table)
    foreach($values in $desired.Values){$script:TPGuiTaskState.Versions.Remove([string]$values.parent)}
}
function Save-Subtasks([array]$items,[string]$ExpectedSnapshotToken=''){Save-TPGuiChildren 'subtasks' $items $ExpectedSnapshotToken}
function Save-WorkLogs($rows,[string]$ExpectedSnapshotToken=''){Save-TPGuiChildren 'work_logs' @($rows) $ExpectedSnapshotToken}
function Save-TPGuiTaskAggregate {
    [CmdletBinding()]param($Target,[Parameter(Mandatory=$true)]$Value)
    Initialize-TPGuiTaskState
    return [long](Invoke-TPGuiTransaction {
        $date=if($null-ne$Target){[string](Get-TPGuiValue $Target 'Date')}else{(Get-Date).ToString('yyyy/MM/dd')}
        $dto=[pscustomobject]@{Date=$date;Task=(Get-TPGuiValue $Value 'Task');Priority=(Get-TPGuiValue $Value 'Priority');DueDate=(Get-TPGuiValue $Value 'DueDate' '');Status=(Get-TPGuiValue $Value 'Status');Memo=(Get-TPGuiValue $Value 'Memo' '')}
        $values=ConvertTo-TPGuiTaskValues $dto
        if($null-eq$Target){
            $id=Reserve-TaskId;$values.id=$id
            $null=Invoke-TPGuiSql -Sql 'INSERT INTO tasks(task_id,registered_on,title,priority,status,due_on,memo) VALUES(@id,@registered,@title,@priority,@status,@due,@memo)' -Parameters $values -Mode NonQuery
            $null=Invoke-TPGuiSql -Sql 'INSERT INTO task_plans(task_id) VALUES(@id)' -Parameters @{id=$id} -Mode NonQuery
            $null=$script:TPGuiTaskState.Reserved.Remove($id)
        }else{
            $id=ConvertTo-TPGuiId (Get-TPGuiValue $Target 'ID');$version=[long](Get-TPGuiValue $Target 'TPRowVersion' 0)
            if($version-lt1){throw '編集開始時のタスク版がありません。'}
            Touch-TPGuiTask $id $version;$values.id=$id
            $null=Invoke-TPGuiSql -Sql 'UPDATE tasks SET title=@title,priority=@priority,status=@status,due_on=@due,memo=@memo WHERE task_id=@id' -Parameters $values -Mode NonQuery
        }
        if((Test-TPGuiField $Value 'PlannedDate') -or (Test-TPGuiField $Value 'WorkStartDate') -or (Test-TPGuiField $Value 'EstimatedHours')){$null=Invoke-TPGuiSql -Sql 'INSERT INTO task_plans(task_id) VALUES(@id) ON CONFLICT(task_id) DO NOTHING' -Parameters @{id=$id} -Mode NonQuery}
        if(Test-TPGuiField $Value 'PlannedDate'){$planned=ConvertTo-TPGuiIsoDate (Get-TPGuiValue $Value 'PlannedDate') -Optional;$null=Invoke-TPGuiSql -Sql 'INSERT INTO task_plans(task_id,planned_on) VALUES(@id,@date) ON CONFLICT(task_id) DO UPDATE SET planned_on=excluded.planned_on' -Parameters @{id=$id;date=$planned} -Mode NonQuery}
        if((Test-TPGuiField $Value 'WorkStartDate') -or (Test-TPGuiField $Value 'EstimatedHours')){
            $plan=@(Invoke-TPGuiSql -Sql 'SELECT work_start_on,estimated_hours_x100 FROM task_plans WHERE task_id=@id' -Parameters @{id=$id})[0]
            $start=$plan.work_start_on;$hours=[long]$plan.estimated_hours_x100
            if(Test-TPGuiField $Value 'WorkStartDate'){$start=ConvertTo-TPGuiIsoDate (Get-TPGuiValue $Value 'WorkStartDate') -Optional}
            if(Test-TPGuiField $Value 'EstimatedHours'){$hours=ConvertTo-TPGuiHours100 (Get-TPGuiValue $Value 'EstimatedHours')}
            $null=Invoke-TPGuiSql -Sql 'UPDATE task_plans SET work_start_on=@start,estimated_hours_x100=@hours WHERE task_id=@id' -Parameters @{id=$id;start=$start;hours=$hours} -Mode NonQuery
        }
        return $id
    })
}
