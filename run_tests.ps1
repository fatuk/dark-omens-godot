# Run GUT unit tests headless.
#   .\run_tests.ps1                 - whole test/unit/ suite
#   .\run_tests.ps1 test_dice.gd    - single script (by filename)
# Godot is taken from $env:GODOT, otherwise the 'godot' command on PATH.

$ErrorActionPreference = "Stop"
$proj = $PSScriptRoot

$exe = $env:GODOT
if (-not $exe) {
	$cmd = Get-Command godot -ErrorAction SilentlyContinue
	if ($cmd) { $exe = $cmd.Source }
}
if (-not $exe -or -not (Test-Path $exe)) {
	Write-Error "Godot not found. Set `$env:GODOT to your Godot console executable, or put 'godot' on PATH.`n  Example: `$env:GODOT = 'C:\path\to\Godot_console.exe'"
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
