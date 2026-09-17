[CmdletBinding()]
param(
    [Parameter()][string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'),
    [Parameter()][string]$OutputPath = (Join-Path (Join-Path $PSScriptRoot '..') 'SCRIPT-SHA256SUMS.txt')
)

$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$items = Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File -Recurse | Sort-Object FullName
$lines = foreach ($item in $items) {
    $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $relative = $item.FullName.Substring($root.Length).TrimStart('\\','/').Replace('\\','/')
    "$hash  $relative"
}
$lines | Set-Content -LiteralPath $OutputPath -Encoding ascii
Write-Output "Wrote $($items.Count) hashes to $OutputPath"
