# Прогнать симулятор баланса карт (headless). Отчёт → sim-report/balance.{json,csv}.
# Godot берётся из $env:GODOT, иначе команда `godot` в PATH.

$ErrorActionPreference = "Stop"
$proj = $PSScriptRoot

$exe = $env:GODOT
if (-not $exe) {
	$cmd = Get-Command godot -ErrorAction SilentlyContinue
	if ($cmd) { $exe = $cmd.Source }
}
if (-not $exe -or -not (Test-Path $exe)) {
	Write-Error "Godot not found. Set `$env:GODOT to your Godot console executable, or put 'godot' on PATH."
	exit 1
}

& $exe --headless --path $proj -s res://tools/card_sim.gd
exit $LASTEXITCODE
