#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Import-TaskPilotMigrationCodec.ps1')
$codecCount=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAILED: $Message"};$script:codecCount++}
function Fails([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Check $failed $Message}
$json=[TaskPilot.Migration.Codec]::ParseJson('{"ID":1,"id":2,"date":"2026-11-15T10:00:00+09:00","hours":0.0100,"large":9007199254740993,"tiny":1e-100,"unknown":{"a":true},"empty":[],"nothing":null}')
Check ($json -is [Collections.Specialized.OrderedDictionary]) 'Object is ordered case-sensitive dictionary'
Check ($json.Count -eq 9 -and $json.Contains('ID') -and $json.Contains('id')) 'Case-distinct keys remain distinct'
Check ($json['ID'].Lexeme -eq '1' -and $json['id'].Lexeme -eq '2') 'Case-sensitive dictionary indexer'
Check ($json['hours'].Lexeme -ceq '0.0100') 'Decimal literal precision and trailing zeros retained'
Check ($json['large'].Lexeme -ceq '9007199254740993') 'Integer above double precision retained'
Check ($json['tiny'].Lexeme -ceq '1e-100') 'Sub-decimal-range lexeme retained for validation'
Check ($json['date'] -is [string] -and $json['date'] -ceq '2026-11-15T10:00:00+09:00') 'Date never coerced'
Check ($json['empty'] -is [object[]] -and $json['empty'].Length -eq 0) 'Empty array shape retained'
Check ($null -eq $json['nothing']) 'JSON null retained'
$jsonRound=[TaskPilot.Migration.Codec]::ParseJson([TaskPilot.Migration.Codec]::ToJson($json))
Check ($jsonRound['hours'].Lexeme -ceq '0.0100' -and $jsonRound['ID'].Lexeme -eq '1' -and $jsonRound['id'].Lexeme -eq '2') 'Serialization retains case and numeric lexemes'
foreach($invalid in @('{"ID":1,"ID":2}','{"ID":1,"\u0049D":2}','{"x":{"a":1,"a":2}}','[1,]','{"a":1,}','/*x*/{}','{}{}','true false','NaN','Infinity','-Infinity','01','-01','+1','1.','1e','1e+','--1','[null, undefined]','{"a" 1}','"\uD800"','"\uDC00"','"\uD800\u0041"','"\x20"')){
 $badInput=$invalid
 Fails { [TaskPilot.Migration.Codec]::ParseJson($badInput) } ('Invalid JSON rejected: '+$badInput)
}
$emoji=[TaskPilot.Migration.Codec]::ParseJson('"\uD83D\uDE00"')
Check ($emoji.Length -eq 2 -and [char]::IsSurrogatePair($emoji,0)) 'Escaped surrogate pair decoded correctly'
Check ([TaskPilot.Migration.Codec]::ParseJson([TaskPilot.Migration.Codec]::ToJson($emoji)) -ceq $emoji) 'Surrogate pair serializer roundtrip'
$control="`"bad`nstring`""
Fails {[TaskPilot.Migration.Codec]::ParseJson($control)} 'Unescaped newline rejected in JSON string'
$rawUnpaired='"'+[char]0xD800+'"'
Fails {[TaskPilot.Migration.Codec]::ParseJson($rawUnpaired)} 'Raw unpaired surrogate rejected'
$deep64=('['*64)+'0'+(']'*64)
Check ($null -ne [TaskPilot.Migration.Codec]::ParseJson($deep64)) '64 containers allowed'
$deep65=('['*65)+'0'+(']'*65)
Fails {[TaskPilot.Migration.Codec]::ParseJson($deep65)} '65 containers rejected'
Check ([TaskPilot.Migration.Codec]::ParseJson(([char]0xFEFF)+'{"x":1}')['x'].Lexeme -eq '1') 'One leading text BOM accepted without altering raw source'
$types=[Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
$types.Add('decimal',[decimal]0.01);$types.Add('integer',[long]42);$types.Add('flag',$false);$types.Add('list',[object[]]@('日本語',"line`r`nquote`"",$null))
$typesRound=[TaskPilot.Migration.Codec]::ParseJson([TaskPilot.Migration.Codec]::ToJson($types))
Check ($typesRound['decimal'].Lexeme -eq '0.01' -and $typesRound['list'][1] -ceq "line`r`nquote`"") 'Supported .NET values serialize without culture drift'
Fails {[TaskPilot.Migration.Codec]::ToJson([double]0.1)} 'Serializer refuses floating-point loss'
Fails {[TaskPilot.Migration.Codec]::ToJson([datetime]::Now)} 'Serializer refuses arbitrary object activation'
Fails {New-Object TaskPilot.Migration.JsonNumber '01'} 'JsonNumber constructor validates literal'
$csv='ID,Task,Memo'+"`r`n"+'1,"日本語,""引用""","a'+"`r`n"+'b"'+"`r`n"+'2,,'
$rows=[TaskPilot.Migration.Codec]::ParseCsv($csv)
Check ($rows.Length -eq 3 -and $rows[0][0] -ceq 'ID') 'CSV retains header and all data rows'
Check ($rows[1][1] -ceq '日本語,"引用"') 'CSV comma and escaped quote decoded'
Check ($rows[1][2] -ceq "a`r`nb") 'CSV quoted CRLF preserved exactly'
Check ($rows[2].Length -eq 3 -and $rows[2][1] -ceq '' -and $rows[2][2] -ceq '') 'CSV trailing empty fields retained'
$blank=[TaskPilot.Migration.Codec]::ParseCsv("A,B`n`n1,2`n")
Check ($blank.Length -eq 3 -and $blank[1].Length -eq 1 -and $blank[1][0] -ceq '') 'CSV blank record is retained not skipped'
Check ([TaskPilot.Migration.Codec]::ParseCsv('').Length -eq 0) 'Empty CSV gives zero rows'
Check ([TaskPilot.Migration.Codec]::ParseCsv(',').Length -eq 1 -and [TaskPilot.Migration.Codec]::ParseCsv(',')[0].Length -eq 2) 'Comma-only CSV preserves two empty fields'
Check ([TaskPilot.Migration.Codec]::ParseCsv(([char]0xFEFF)+"A,B`r`n1,2")[0][0] -ceq 'A') 'CSV BOM tolerated only at start'
foreach($invalidCsv in @('A,"unclosed','A,b"bad','A,"good"bad','A,"good" ')){
 $badCsv=$invalidCsv
 Fails {[TaskPilot.Migration.Codec]::ParseCsv($badCsv)} ('Malformed CSV rejected: '+$badCsv)
}
Check ([TaskPilot.Migration.Codec]::ParseCsv("A,B`r1,2").Length -eq 2) 'Lone CR record separator accepted as explicit variant'
Check ([TaskPilot.Migration.Codec]::ParseJson('{"$type":"System.IO.FileInfo","__type":"x"}')['$type'] -ceq 'System.IO.FileInfo') 'Type-like keys are inert data'
Write-Output "PASS: $codecCount strict codec assertions; no external data or DB touched."
