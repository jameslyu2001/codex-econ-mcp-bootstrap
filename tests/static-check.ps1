[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = New-Object System.Collections.Generic.List[string]
$manifestPath = Join-Path $repoRoot 'manifests\mcps.lock.json'

$requiredFiles = @(
    'manifests\mcps.lock.json', 'install-windows.ps1', 'doctor-windows.ps1',
    'launchers\econ-mcp-launcher.ps1', 'tests\static-check.ps1')
$expectedNames = @(
    'econ_bls', 'econ_ecb', 'econ_eurostat', 'econ_imf', 'econ_oecd',
    'econ_world_bank', 'econ_world_bank_data360', 'econ_un_comtrade',
    'econ_alpha_vantage', 'econ_bea', 'econ_census', 'econ_data_commons',
    'econ_financial_datasets', 'econ_fred', 'econ_nasdaq_data_link',
    'econ_sec_edgar', 'econ_tam', 'stata-mcp')

foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $relativePath) -PathType Leaf)) {
        $failures.Add("Required file is missing: $relativePath")
    }
}

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $entryProperty = $manifest.PSObject.Properties['mcps']
        if ($null -eq $entryProperty) { $entryProperty = $manifest.PSObject.Properties['servers'] }
        if ($null -eq $entryProperty) { throw 'Manifest has no mcps or servers array.' }
        $entries = @($entryProperty.Value)
        $names = @($entries | ForEach-Object { ([string]$_.id).ToLowerInvariant() })
        if ($entries.Count -ne 18) { $failures.Add("Manifest contains $($entries.Count) entries instead of 18.") }
        if (@($names | Select-Object -Unique).Count -ne $names.Count) { $failures.Add('Manifest contains duplicate MCP names.') }
        foreach ($name in $expectedNames) {
            if ($names -notcontains $name) { $failures.Add("Manifest is missing MCP: $name") }
        }
        foreach ($name in $names) {
            if ($expectedNames -notcontains $name) { $failures.Add("Manifest contains unexpected MCP: $name") }
        }
        foreach ($entry in $entries) {
            $sourceTypeProperty = $entry.source.PSObject.Properties['type']
            if ($null -eq $sourceTypeProperty) { $sourceTypeProperty = $entry.source.PSObject.Properties['kind'] }
            $sourceType = if ($null -ne $sourceTypeProperty) { [string]$sourceTypeProperty.Value } else { '' }
            if ($sourceType -eq 'git') {
                $commitProperty = $entry.source.PSObject.Properties['commit']
                if ($null -eq $commitProperty) { $commitProperty = $entry.source.PSObject.Properties['resolved_commit'] }
                $commit = if ($null -ne $commitProperty) { [string]$commitProperty.Value } else { '' }
                if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
                    $failures.Add("MCP is not pinned to a full Git commit: $($entry.id)")
                }
            }
        }
        $stataEntry = $entries | Where-Object { $_.id -eq 'stata-mcp' } | Select-Object -First 1
        if ($null -eq $stataEntry) {
            $failures.Add('stata-mcp lock entry is missing.')
        }
        else {
            if ($stataEntry.source.url -ne 'https://github.com/SepineTam/mcp-for-stata.git') {
                $failures.Add('stata-mcp source URL is unexpected.')
            }
            if ($stataEntry.source.commit -ne 'e5b25dc90058001c942fb7ef851637c9f5728486') {
                $failures.Add('stata-mcp commit differs from the reviewed lock.')
            }
            if ($stataEntry.source.upstream_version -ne '1.22.0' -or $stataEntry.source.license -ne 'AGPL-3.0') {
                $failures.Add('stata-mcp version or license metadata is invalid.')
            }
            if (@($stataEntry.setup.commands) -notcontains 'uv sync') {
                $failures.Add('stata-mcp setup must use uv sync.')
            }
            if (@($stataEntry.runtime.windows.args) -notcontains '--frozen' -or
                @($stataEntry.runtime.macos.args) -notcontains '--frozen') {
                $failures.Add('stata-mcp launch commands must use the generated lock with --frozen.')
            }
        }
    }
    catch { $failures.Add("Manifest JSON is invalid: $($_.Exception.Message)") }
}

$blockedNamePattern = '(?i)(^|[\\/])(\.env($|\.)|api[ _-]?keys?\.txt$|credentials?\.(json|txt|ya?ml)$|.*\.(pem|p12|pfx)|id_rsa$)'
$usersSegment = [regex]::Escape('Users')
$userPathPattern = '(?i)([A-Z]:\\' + $usersSegment + '\\[^\\\s"'']+|/' + $usersSegment + '/[^/\s"'']+)'
$assignmentPattern = '(?i)(api[_ -]?key|access[_ -]?token|client[_ -]?secret|password)\s*[:=]\s*["'']?(?!\$\{|<|YOUR_|REPLACE_|EXAMPLE_|process\.env\.|null\b|true\b|false\b)[A-Za-z0-9_./+=-]{16,}'
$secretPatterns = @(
    'AKIA[0-9A-Z]{16}', 'gh[pousr]_[A-Za-z0-9]{30,}',
    'sk-[A-Za-z0-9]{20,}', '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----')
$extensions = @('.ps1', '.json', '.md', '.yaml', '.yml', '.toml', '.txt', '.sh', '.patch')

$files = Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.git[\\/]' -and $extensions -contains $_.Extension.ToLowerInvariant()
}
foreach ($file in $files) {
    $relativePath = $file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')
    if ($relativePath -match $blockedNamePattern) { $failures.Add("Blocked credential file name: $relativePath") }
    $content = Get-Content -LiteralPath $file.FullName -Raw
    if ($content -match $userPathPattern) { $failures.Add("Hard-coded user path found: $relativePath") }
    if ($content -match $assignmentPattern) { $failures.Add("Possible credential assignment found: $relativePath") }
    foreach ($pattern in $secretPatterns) {
        if ($content -match $pattern) { $failures.Add("Possible secret found: $relativePath"); break }
    }
}

$launcherPath = Join-Path $repoRoot 'launchers\econ-mcp-launcher.ps1'
if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
    $launcher = Get-Content -LiteralPath $launcherPath -Raw
    foreach ($name in $expectedNames) {
        if ($launcher -notmatch [regex]::Escape("'$name'")) { $failures.Add("Launcher mapping is missing: $name") }
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Error $failure -ErrorAction Continue }
    exit 1
}
Write-Output 'Static checks passed.'
