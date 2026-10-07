param(
    [string]$ModelSimDir = 'C:\modeltech64_10.1c\win64',
    [string]$TdRoot = 'C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116',
    [string]$OutputDir = ''
)
$ErrorActionPreference = 'Stop'
$projectDir = Split-Path $PSScriptRoot -Parent
if (-not $OutputDir) { $OutputDir = Join-Path $projectDir 'td_project\v25_regression' }
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
& (Join-Path $PSScriptRoot 'run_v24_regression.ps1') -ModelSimDir $ModelSimDir -TdRoot $TdRoot -OutputDir $OutputDir
$rtl = Join-Path $projectDir 'user_source\hdl_source\isp2'
$vlog = Join-Path $ModelSimDir 'vlog.exe'
$vsim = Join-Path $ModelSimDir 'vsim.exe'
$previousPath = $env:Path
Push-Location $OutputDir
try {
    $env:Path = $ModelSimDir + ';' + $env:Path
    & $vlog -work work (Join-Path $rtl 'color_correct.v') (Join-Path $rtl 'wb_kelvin.v') (Join-Path $PSScriptRoot 'sim\tb_color_correct.v') (Join-Path $PSScriptRoot 'sim\tb_wb_kelvin.v')
    if ($LASTEXITCODE -ne 0) { throw 'Image-control RTL compilation failed' }
    foreach ($test in @('tb_color_correct','tb_wb_kelvin')) {
        $testLog = Join-Path $OutputDir ($test + '.log')
        & $vsim -c -novopt -l $testLog ('work.' + $test) -do 'run -all; quit -f'
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $test" }
        $result = Get-Content -LiteralPath $testLog -Raw
        if ($result -notmatch 'TEST_RESULT PASS' -or $result -match 'TEST_RESULT FAIL') { throw "Regression failed: $test" }
    }
    # Use the real DPC/window modules, replacing the control-only image stubs.
    & $vlog -work work (Join-Path $rtl 'cvp_dpc.v') (Join-Path $rtl 'imgproc_win3x3.v') (Join-Path $PSScriptRoot 'sim\tb_dpc_color.v')
    if ($LASTEXITCODE -ne 0) { throw 'DPC regression compilation failed' }
    $testLog = Join-Path $OutputDir 'tb_dpc_color.log'
    & $vsim -c -novopt -l $testLog work.tb_dpc_color -do 'run -all; quit -f'
    $result = Get-Content -LiteralPath $testLog -Raw
    if ($LASTEXITCODE -ne 0 -or $result -notmatch 'TEST_RESULT PASS' -or $result -match 'TEST_RESULT FAIL') { throw 'DPC regression failed' }
    Write-Output 'V25_RTL_REGRESSION_PASS'
} finally {
    $env:Path = $previousPath
    Pop-Location
}
