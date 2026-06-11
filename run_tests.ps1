# Run GUT unit tests headless.
#   .\run_tests.ps1                 - whole test/unit/ suite
#   .\run_tests.ps1 test_dice.gd    - single script (by filename)
# Godot is taken from $env:GODOT, otherwise the default path below.

$ErrorActionPreference = "Stop"
$proj = $PSScriptRoot

$exe = $env:GODOT
if (-not $exe) {
	$exe = "C:\Users\fatuk\Downloads\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"
}
if (-not (Test-Path $exe)) {
	Write-Error "Godot not found: $exe`nSet `$env:GODOT or fix the default in run_tests.ps1."
	exit 1
}
if (-not (Test-Path (Join-Path $proj "addons\gut\gut_cmdln.gd"))) {
	Write-Error "GUT is not installed in addons\gut. See test/README.md (Installation)."
	exit 1
}

$gutArgs = @(
	"--headless", "--path", $proj,
	"-s", "addons/gut/gut_cmdln.gd",
	"-gdir=res://test/unit", "-ginclude_subdirs", "-gexit"
)
if ($args.Count -gt 0) {
	$gutArgs += "-gselect=$($args[0])"
}

& $exe @gutArgs
exit $LASTEXITCODE
