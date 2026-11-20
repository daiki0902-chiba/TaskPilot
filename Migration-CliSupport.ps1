#requires -Version 5.1
# CLI output helpers only. No application/store operations are performed here.
function Get-TPMigrationCLIReportPath {
    param([string]$ReportPath,[Parameter(Mandatory=$true)][string]$SourceRoot)
    if([string]::IsNullOrWhiteSpace($ReportPath)){return $null}
    $provider=$null;$drive=$null
    $report=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath,[ref]$provider,[ref]$drive)
    if($provider.Name-ne'FileSystem'){throw 'ReportPath must be a filesystem path.'}
    $source=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourceRoot)
    $source=[IO.Path]::GetFullPath($source).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $report=[IO.Path]::GetFullPath($report)
    if($report.Equals($source,[StringComparison]::OrdinalIgnoreCase)-or $report.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'ReportPath must be outside SourceRoot.'}
    $inspect=$report
    while($inspect){
        $exists=$true
        try{$attributes=[IO.File]::GetAttributes($inspect)}catch [IO.FileNotFoundException]{$exists=$false}catch [IO.DirectoryNotFoundException]{$exists=$false}
        if($exists){
            if($inspect-eq$report){throw 'ReportPath already exists and will not be overwritten.'}
            if(($attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'ReportPath must not traverse a symbolic link or junction.'}
        }
        $parent=[IO.Path]::GetDirectoryName($inspect);if($parent-eq$inspect){break};$inspect=$parent
    }
    if(-not[IO.Directory]::Exists([IO.Path]::GetDirectoryName($report))){throw 'ReportPath parent directory must already exist.'}
    return $report
}
function Write-TPMigrationCLIReport {
    param([string]$ReportPath,[Parameter(Mandatory=$true)]$Result,[Parameter(Mandatory=$true)][string]$SourceRoot)
    if(-not$ReportPath){return}
    $target=Get-TPMigrationCLIReportPath -ReportPath $ReportPath -SourceRoot $SourceRoot
    $text=ConvertTo-Json -InputObject $Result -Depth 30
    $encoding=New-Object Text.UTF8Encoding($true)
    $stream=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{
        $preamble=$encoding.GetPreamble();$stream.Write($preamble,0,$preamble.Length)
        $bytes=$encoding.GetBytes($text+[Environment]::NewLine);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
    } finally{$stream.Dispose()}
}
