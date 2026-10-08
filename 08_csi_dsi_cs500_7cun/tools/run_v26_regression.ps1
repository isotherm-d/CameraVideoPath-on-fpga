param([string]$OutputDir='',[string]$Python='python',[string]$ModelSimDir='C:\modeltech64_10.1c\win64')
$ErrorActionPreference='Stop'
$projectDir=Split-Path $PSScriptRoot -Parent
if(-not $OutputDir){$OutputDir=Join-Path $projectDir 'td_project\v26_regression'}
$OutputDir=[IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
& $Python (Join-Path $PSScriptRoot 'generate_v26_vectors.py') --output $OutputDir
if($LASTEXITCODE-ne 0){throw 'Reference vector generation failed'}
$rtl=Join-Path $projectDir 'user_source\hdl_source'
Push-Location $OutputDir
try{
 & (Join-Path $ModelSimDir 'vlib.exe') work
 $sources=@(Get-ChildItem (Join-Path $rtl 'common') -Filter '*.v')+
           @(Get-ChildItem (Join-Path $rtl 'advanced') -Filter '*.v' -ErrorAction SilentlyContinue)
 $sources=@($sources|ForEach-Object{$_.FullName})
 $sources+=@('cvp_eth_dbg.v','cvp_gmii_mac_tx.v','cvp_mdio_ro.v','cvp_cmd_rx.v','cvp_async_fifo.v')|ForEach-Object{Join-Path (Join-Path $rtl 'net') $_}
 $sources+=@('ph1p_logic_hdio.v','ph1p_phy_gsr.v')|ForEach-Object{Join-Path 'C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\sim_release\ph1p' $_}
 $sources+=@(Join-Path $rtl 'isp2\cvp_demosaic.v')
 $tests=@(Get-ChildItem (Join-Path $PSScriptRoot 'sim') -Filter 'tb_v26_*.v')
 & (Join-Path $ModelSimDir 'vlog.exe') -work work @sources @($tests|ForEach-Object{$_.FullName}) 2>&1 | Set-Content 'compile.log'
 if($LASTEXITCODE-ne 0){throw 'V26 compilation failed; see compile.log'}
 foreach($t in $tests){
  $name=$t.BaseName
  & (Join-Path $ModelSimDir 'vsim.exe') -c -novopt -l ($name+'.log') ('work.'+$name) work.PH1P_PHY_GSR -do 'run -all; quit -f' 2>&1 | Out-Null
  $log=Get-Content ($name+'.log') -Raw
  if($LASTEXITCODE-ne 0 -or $log-notmatch 'TEST_RESULT PASS' -or $log-match 'TEST_RESULT FAIL'){throw "Failed $name"}
  Write-Output "PASS $name"
 }
}finally{Pop-Location}
