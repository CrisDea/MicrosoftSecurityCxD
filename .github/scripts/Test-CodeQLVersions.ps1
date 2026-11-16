param(
    [string] $WorkflowContent
)

$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('WorkflowContent')) {
    $WorkflowContent = Get-Content -Raw (Join-Path $PSScriptRoot '../workflows/codeql.yml')
}

$versions = @{}
foreach ($action in @('init', 'analyze')) {
    $pattern = '(?m)^\s*-?\s*uses:\s*github/codeql-action/' + $action + '@([^\s#]+)'
    $actionMatches = [regex]::Matches($WorkflowContent, $pattern)
    if ($actionMatches.Count -ne 1) {
        throw "Expected exactly one CodeQL $action step; found $($actionMatches.Count)."
    }
    $versions[$action] = $actionMatches[0].Groups[1].Value
}

if ($versions.init -ne $versions.analyze) {
    throw "CodeQL init and analyze must use the same version."
}
Write-Host 'CodeQL init and analyze versions match.'
