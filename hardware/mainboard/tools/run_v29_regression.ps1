param(
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [string]$Python = 'python',
    [string]$ModelSimDir = 'C:\modeltech64_2020.4\win64',
    [string]$TdRoot = 'C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116'
)
$ErrorActionPreference = 'Stop'
$projectDir = Split-Path $PSScriptRoot -Parent
$rtl = Join-Path $projectDir 'user_source\hdl_source'
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
foreach ($generator in @('generate_v26_vectors.py','generate_v27_vectors.py')) {
    & $Python (Join-Path $PSScriptRoot $generator) --output $OutputDir
    if ($LASTEXITCODE -ne 0) { throw "Vector generation failed: $generator" }
}
$sources = foreach ($folder in @('common','advanced','uics500_cfg')) {
    Get-ChildItem (Join-Path $rtl $folder) -Filter '*.v' | ForEach-Object { $_.FullName }
}
$sources += @('cvp_eth_dbg.v','cvp_gmii_mac_tx.v','cvp_mdio_ro.v','cvp_cmd_rx.v','cvp_async_fifo.v') |
    ForEach-Object { Join-Path (Join-Path $rtl 'net') $_ }
$sources += @('cvp_dpc.v','cvp_proc.v','cvp_demosaic.v','group_fifo.v','pack_4.v','imgproc_win3x3.v') |
    ForEach-Object { Join-Path (Join-Path $rtl 'isp2') $_ }
$sources += (Join-Path $rtl 'uial2axis/uial2axis.v'),(Join-Path $rtl 'line_retimer.v')
$sources += @('ph1p_logic_hdio.v','ph1p_phy_gsr.v') |
    ForEach-Object { Join-Path (Join-Path $TdRoot 'sim_release\ph1p') $_ }
$sources += @('cvp_frame_stats_gold.v','cvp_style_gold.v','cvp_contour_gold.v') |
    ForEach-Object { Join-Path (Join-Path $PSScriptRoot 'sim\gold_a') $_ }
foreach ($baseline in @('gold_v30','gold_v31','gold_v32','gold_v33','gold_v34','gold_v35','gold_v36','gold_v37')) {
    $sources += @(Get-ChildItem (Join-Path $PSScriptRoot ('sim\'+$baseline)) -Filter '*.v' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
}
$tests = @(Get-ChildItem (Join-Path $PSScriptRoot 'sim') -Filter 'tb_v26_*.v') +
         @(Get-ChildItem (Join-Path $PSScriptRoot 'sim') -Filter 'tb_v27_*.v') +
         @(Get-ChildItem (Join-Path $PSScriptRoot 'sim') -Filter 'tb_a_*.v') +
         @(Get-ChildItem (Join-Path $PSScriptRoot 'sim') -Filter 'tb_opt_*.v') +
         @(Get-Item (Join-Path $PSScriptRoot 'sim\tb_cvp_color_path.v')) +
         @(Get-Item (Join-Path $PSScriptRoot 'sim\tb_camera_boot.v'))
$summary = [Collections.Generic.List[string]]::new()
Push-Location $OutputDir
try {
    & (Join-Path $ModelSimDir 'vlib.exe') work *> 'vlib.log'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create simulation library' }
    & (Join-Path $ModelSimDir 'vlog.exe') -work work @sources @($tests | ForEach-Object { $_.FullName }) *> 'compile.log'
    if ($LASTEXITCODE -ne 0) { throw 'RTL compilation failed; see compile.log' }
    foreach ($test in $tests) {
        $name = $test.BaseName
        # Match the release's unoptimized simulation. ModelSim 2020.4 treats the
        # deprecated -novopt notice as error 12110 unless explicitly suppressed.
        # Batch mode avoids the old interactive client's IPv6 RPC connection.
        & (Join-Path $ModelSimDir 'vsim.exe') -batch -novopt -suppress 12110 -l ($name+'.log') ('work.'+$name) work.PH1P_PHY_GSR -do 'run -all; quit -f' *> ($name+'.stdout')
        $log = Get-Content ($name+'.log') -Raw
        if ($LASTEXITCODE -ne 0 -or $log -notmatch 'TEST_RESULT PASS' -or $log -match 'TEST_RESULT FAIL') {
            $summary.Add("FAIL $name")
            throw "Failed $name; see $OutputDir\$name.log"
        }
        $summary.Add("PASS $name")
        Write-Output "PASS $name"
    }
    foreach ($filename in @('net_packets.hex','v27_net_packets.hex')) {
        & $Python (Join-Path $PSScriptRoot 'verify_v26_packets.py') --output $OutputDir --filename $filename *> ($filename+'.verify.log')
        if ($LASTEXITCODE -ne 0) { throw "Packet integrity check failed: $filename" }
        $summary.Add("PASS packet_integrity $filename")
    }
    Write-Output "V29_RTL_REGRESSION_PASS $($tests.Count) RTL tests and 2 packet integrity checks"
} finally {
    $summary | Set-Content -Encoding utf8 'rtl-tests.log'
    Pop-Location
}
