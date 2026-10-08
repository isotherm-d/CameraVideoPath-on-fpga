param([string]$OutputDir='',[string]$Python='python',[string]$ModelSimDir='C:\modeltech64_10.1c\win64')
$ErrorActionPreference='Stop'
$projectDir=Split-Path $PSScriptRoot -Parent
if(-not $OutputDir){$OutputDir=Join-Path $projectDir 'td_project\v27_regression'}
$OutputDir=[IO.Path]::GetFullPath($OutputDir)
& (Join-Path $PSScriptRoot 'run_v26_regression.ps1') -OutputDir $OutputDir -Python $Python -ModelSimDir $ModelSimDir
& $Python (Join-Path $PSScriptRoot 'generate_v27_vectors.py') --output $OutputDir
if($LASTEXITCODE-ne 0){throw 'V27 vector generation failed'}
Push-Location $OutputDir
try {
 $rtl=Join-Path $projectDir 'user_source\hdl_source'
 $sources=@(Get-ChildItem (Join-Path $rtl 'uics500_cfg') -Filter '*.v'|ForEach-Object{$_.FullName})
 $tests=@(Get-ChildItem (Join-Path $PSScriptRoot 'sim') -Filter 'tb_v27_*.v')
 & (Join-Path $ModelSimDir 'vlog.exe') -work work @sources @($tests|ForEach-Object{$_.FullName}) *> 'compile_v27.log'
 if($LASTEXITCODE-ne 0){throw 'V27 compilation failed'}
 foreach($test in $tests){
  $name=$test.BaseName
  & (Join-Path $ModelSimDir 'vsim.exe') -c -novopt -l ($name+'.log') ('work.'+$name) work.PH1P_PHY_GSR -do 'run -all; quit -f' *> ($name+'.stdout')
  $log=Get-Content ($name+'.log') -Raw
  if($LASTEXITCODE-ne 0 -or $log-notmatch 'TEST_RESULT PASS' -or $log-match 'TEST_RESULT FAIL'){throw "Failed $name"}
  Write-Output "PASS $name"
 }
} finally {Pop-Location}
& $Python (Join-Path $PSScriptRoot 'verify_v26_packets.py') --output $OutputDir
& $Python (Join-Path $PSScriptRoot 'verify_v26_packets.py') --output $OutputDir --filename v27_net_packets.hex
if($LASTEXITCODE-ne 0){throw 'Packet integrity check failed'}
& (Join-Path $PSScriptRoot 'run_v25_regression.ps1') -OutputDir (Join-Path $OutputDir 'baseline') -ModelSimDir $ModelSimDir
Push-Location $projectDir
try {& $Python -X utf8 -m unittest discover -s tools -p 'test_*.py';if($LASTEXITCODE-ne 0){throw 'Python regression failed'}}finally{Pop-Location}
