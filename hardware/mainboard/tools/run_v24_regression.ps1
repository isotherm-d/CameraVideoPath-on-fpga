param(
    [string]$ModelSimDir = 'C:\modeltech64_10.1c\win64',
    [string]$TdRoot = 'C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116',
    [string]$OutputDir = ''
)
$ErrorActionPreference = 'Stop'
$projectDir = Split-Path $PSScriptRoot -Parent
if (-not $OutputDir) { $OutputDir = Join-Path $projectDir 'td_project\v24_regression' }
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$vlog = Join-Path $ModelSimDir 'vlog.exe'
$vsim = Join-Path $ModelSimDir 'vsim.exe'
$vlib = Join-Path $ModelSimDir 'vlib.exe'
$iddr = Join-Path $TdRoot 'sim_release\ph1p\ph1p_logic_hdio.v'
$gsr = Join-Path $TdRoot 'sim_release\ph1p\ph1p_phy_gsr.v'
foreach ($requiredFile in @($vlog,$vsim,$vlib,$iddr,$gsr)) {
    if (-not (Test-Path -LiteralPath $requiredFile)) { throw "Missing dependency: $requiredFile" }
}
$rtl = Join-Path $projectDir 'user_source\hdl_source'
$sources = @(
    (Join-Path $PSScriptRoot 'sim\boot_image_stubs.v'),
    (Join-Path $PSScriptRoot 'sim\tb_camera_boot.v'),
    (Join-Path $PSScriptRoot 'sim\tb_udp_command_rx.v'),
    (Join-Path $rtl 'isp2\cvp_proc.v'),
    (Join-Path $rtl 'uics500_cfg\uicfgcs500.v'),
    (Join-Path $rtl 'uics500_cfg\uii2c.v'),
    (Join-Path $rtl 'uics500_cfg\uics500reg.v'),
    (Join-Path $rtl 'uics500_cfg\uics500regAE.v'),
    (Join-Path $rtl 'uics500_cfg\SC500GainTbl.v'),
    (Join-Path $rtl 'net\cvp_cmd_rx.v'),
    $iddr,
    $gsr
)
$previousPath = $env:Path
Push-Location $OutputDir
try {
    $env:Path = $ModelSimDir + ';' + $env:Path
    & $vlib work
    if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    & $vlog -work work @sources 2>&1 | Tee-Object -FilePath 'compile.log'
    if ($LASTEXITCODE -ne 0) { throw 'RTL compilation failed' }
    foreach ($test in @('tb_camera_boot','tb_udp_command_rx')) {
        $testLog = Join-Path $OutputDir ($test + '.log')
        & $vsim -c -novopt -l $testLog ('work.' + $test) work.PH1P_PHY_GSR -do 'run -all; quit -f'
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $test" }
        $result = Get-Content -LiteralPath $testLog -Raw
        if ($result -notmatch 'TEST_RESULT PASS' -or $result -match 'TEST_RESULT FAIL') {
            throw "Regression failed: $test (see $testLog)"
        }
    }
    Write-Output 'V24_REGRESSION_PASS'
} finally {
    $env:Path = $previousPath
    Pop-Location
}
