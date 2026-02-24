param(
    [ValidateSet("ToNAS", "FromNAS")]
    [string]$Direction = "ToNAS",
    [switch]$Verify
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$syncScript = Join-Path $scriptRoot "sync-world.ps1"

& $syncScript -Direction $Direction -Verify:$Verify
