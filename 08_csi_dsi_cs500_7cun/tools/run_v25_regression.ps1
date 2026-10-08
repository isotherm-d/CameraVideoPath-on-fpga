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
    & $vlog -work work (Join-Path $rtl 'group_fifo.v') (Join-Path $projectDir 'user_source\hdl_source\net\cvp_async_fifo.v') (Join-Path $PSScriptRoot 'sim\tb_group_fifo_tags.v')
    if ($LASTEXITCODE -ne 0) { throw 'Group FIFO test compilation failed' }
    $testLog = Join-Path $OutputDir 'tb_group_fifo_tags.log'
    & $vsim -c -novopt -l $testLog work.tb_group_fifo_tags -do 'run -all; quit -f'
    $result = Get-Content -LiteralPath $testLog -Raw
    if ($LASTEXITCODE -ne 0 -or $result -notmatch 'TEST_RESULT PASS' -or $result -match 'TEST_RESULT FAIL') { throw 'Group FIFO sideband regression failed' }
    # Verify actual FIFO transport, RAW gearbox, Bayer window and interpolation.
    $common = Join-Path $projectDir 'user_source\hdl_source\common'
    & $vlog -work work (Join-Path $common 'cvp_sync_fifo.v') (Join-Path $common 'cvp_window3x3.v') (Join-Path $common 'cvp_mailbox.v') (Join-Path $rtl 'cvp_proc.v') (Join-Path $rtl 'cvp_demosaic.v') (Join-Path $PSScriptRoot 'sim\tb_cvp_color_path.v')
    if ($LASTEXITCODE -ne 0) { throw 'Full colour pipeline compilation failed' }
    $testLog = Join-Path $OutputDir 'tb_cvp_color_path.log'
    & $vsim -c -novopt -l $testLog work.tb_cvp_color_path -do 'run -all; quit -f'
    $result = Get-Content -LiteralPath $testLog -Raw
    if ($LASTEXITCODE -ne 0 -or $result -notmatch 'TEST_RESULT PASS' -or $result -match 'TEST_RESULT FAIL') { throw 'Full colour pipeline regression failed' }
    & $vlog -work work (Join-Path $rtl 'pack_4.v') (Join-Path $PSScriptRoot 'sim\tb_pack4_order.v')
    if ($LASTEXITCODE -ne 0) { throw 'Pixel packer compilation failed' }
    $testLog = Join-Path $OutputDir 'tb_pack4_order.log'
    & $vsim -c -novopt -l $testLog work.tb_pack4_order -do 'run -all; quit -f'
    $result = Get-Content -LiteralPath $testLog -Raw
    if ($LASTEXITCODE -ne 0 -or $result -notmatch 'TEST_RESULT PASS' -or $result -match 'TEST_RESULT FAIL') { throw 'Pixel order regression failed' }
    & $vlog -work work (Join-Path $PSScriptRoot 'sim\tb_window_coordinates.v')
    if ($LASTEXITCODE -ne 0) { throw 'Window-coordinate test compilation failed' }
    $testLog = Join-Path $OutputDir 'tb_window_coordinates.log'
    & $vsim -c -novopt -l $testLog work.tb_window_coordinates -do 'run -all; quit -f'
    $result = Get-Content -LiteralPath $testLog -Raw
    if ($LASTEXITCODE -ne 0 -or $result -notmatch 'TEST_RESULT PASS' -or $result -match 'TEST_RESULT FAIL') { throw 'Window coordinate regression failed' }
    $net = Join-Path $projectDir 'user_source\hdl_source\net'
    & $vlog -work work (Join-Path $net 'cvp_eth_dbg.v') (Join-Path $net 'cvp_gmii_mac_tx.v') (Join-Path $net 'cvp_mdio_ro.v') (Join-Path $PSScriptRoot 'sim\tb_eth_frame_stream.v')
    if ($LASTEXITCODE -ne 0) { throw 'Ethernet frame-stream test compilation failed' }
    $testLog = Join-Path $OutputDir 'tb_eth_frame_stream.log'
    & $vsim -c -novopt -l $testLog work.tb_eth_frame_stream work.PH1P_PHY_GSR -do 'run -all; quit -f'
    $result = Get-Content -LiteralPath $testLog -Raw
    if ($LASTEXITCODE -ne 0 -or $result -notmatch 'TEST_RESULT PASS' -or $result -match 'TEST_RESULT FAIL') { throw 'Ethernet frame-stream regression failed' }
    Write-Output 'V25_RTL_REGRESSION_PASS'
} finally {
    $env:Path = $previousPath
    Pop-Location
}
