[CmdletBinding()]
param(
    [string]$ApiKeysFile,
    [string]$CodexRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'),
    [switch]$SkipCensusInit,
    [switch]$DryRun,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = $PSScriptRoot
$manifestPath = Join-Path $repositoryRoot 'manifests\mcps.lock.json'
$launcherSource = Join-Path $repositoryRoot 'launchers\econ-mcp-launcher.ps1'
$censusPatch = Join-Path $repositoryRoot 'patches\census-api-key.patch'
$CodexRoot = [IO.Path]::GetFullPath($CodexRoot)
$mcpRoot = Join-Path $CodexRoot 'mcp-servers\economic-data'
$secretDirectory = Join-Path $CodexRoot 'secrets'
$secretPath = Join-Path $secretDirectory 'econ-mcp.env'
$launcherDirectory = Join-Path $CodexRoot 'mcp-bootstrap'
$launcherTarget = Join-Path $launcherDirectory 'econ-mcp-launcher.ps1'

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    if ($DryRun) { Write-Output "[DRY RUN] $Message" } else { Write-Output $Message }
}

function Require-File {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file is missing: $Path" }
}

function Find-Command {
    param([Parameter(Mandatory = $true)][string[]]$Names)
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { return $command.Source }
    }
    throw "Required command is missing: $($Names -join ', ')"
}

function Run-Command {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    & $Command @Arguments
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) { throw "Command failed with exit code ${exitCode}: $Command" }
    return $exitCode
}

function Run-GitCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & $Git @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $message = $output -join [Environment]::NewLine
    if ($exitCode -ne 0 -and $message -match '(?i)(schannel.*SEC_E_NO_CREDENTIALS|AcquireCredentialsHandle failed)') {
        Write-Warning 'Git Schannel could not obtain credentials; retrying with the OpenSSL TLS backend.'
        $output = & $Git -c http.sslBackend=openssl @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $message = $output -join [Environment]::NewLine
    }
    if ($exitCode -ne 0) { throw "Git command failed with exit code ${exitCode}: $message" }
    return @($output)
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($DryRun) { Write-Step "Ensure directory exists: $Path"; return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-Entries {
    param([Parameter(Mandatory = $true)]$Manifest)
    foreach ($propertyName in @('servers', 'mcps', 'entries')) {
        $property = $Manifest.PSObject.Properties[$propertyName]
        if ($null -ne $property) { return @($property.Value) }
    }
    throw 'Manifest must contain a servers, mcps, or entries array.'
}

function Get-EntryName {
    param([Parameter(Mandatory = $true)]$Entry)
    if ($Entry.id) { return ([string]$Entry.id).ToLowerInvariant() }
    return ([string]$Entry.name).ToLowerInvariant()
}

function Get-InstallDirectory {
    param([Parameter(Mandatory = $true)]$Entry)
    $directory = $null
    if ($null -ne $Entry.source) {
        if ($Entry.source.checkout_dir) { $directory = [string]$Entry.source.checkout_dir }
        elseif ($Entry.source.local_directory) { $directory = [string]$Entry.source.local_directory }
    }
    elseif ($Entry.local_directory) { $directory = [string]$Entry.local_directory }
    if (-not $directory) { return $null }
    if ([IO.Path]::IsPathRooted($directory) -or $directory -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Unsafe local directory for $(Get-EntryName $Entry): $directory"
    }
    return $directory
}

function Ensure-FixedCheckout {
    param([Parameter(Mandatory = $true)]$Entry)

    $name = Get-EntryName $Entry
    $source = $Entry.source
    $sourceType = if ($null -ne $source -and $source.type) { [string]$source.type } else { [string]$source.kind }
    if ($null -eq $source -or $sourceType -ne 'git') { return }
    $url = [string]$source.url
    $commitProperty = $source.PSObject.Properties['commit']
    if ($null -eq $commitProperty) { $commitProperty = $source.PSObject.Properties['resolved_commit'] }
    $commit = if ($null -ne $commitProperty) { [string]$commitProperty.Value } else { '' }
    $directory = Get-InstallDirectory $Entry
    if (-not $url -or -not $directory) { throw "Incomplete Git source for $name." }
    if ($commit -notmatch '^[0-9a-fA-F]{40}$') { throw "$name is not pinned to a full Git commit." }

    $target = Join-Path $mcpRoot $directory
    if ($DryRun) { Write-Step "Clone or update $name at commit $commit."; return }
    $git = Find-Command @('git.exe', 'git')
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        Run-GitCommand $git @('clone', '--filter=blob:none', '--no-checkout', '--', $url, $target) | Out-Null
        Run-GitCommand $git @('-C', $target, 'fetch', '--depth', '1', 'origin', $commit) | Out-Null
        Run-GitCommand $git @('-C', $target, 'checkout', '--detach', $commit) | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $target '.git'))) { throw "Existing source is not a Git checkout: $target" }

    $head = (& $git -C $target rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Cannot read Git HEAD for $name." }
    if ($head -ieq $commit) { return }
    $dirty = & $git -C $target status --porcelain
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect Git status for $name." }
    if ($dirty) { throw "Refusing to replace a modified checkout for ${name}: $target" }
    Run-GitCommand $git @('-C', $target, 'fetch', '--depth', '1', 'origin', $commit) | Out-Null
    Run-GitCommand $git @('-C', $target, 'checkout', '--detach', $commit) | Out-Null
}

function Apply-CensusPatch {
    param([Parameter(Mandatory = $true)]$Entry)

    if (-not (Test-Path -LiteralPath $censusPatch -PathType Leaf)) { return }
    $target = Join-Path $mcpRoot (Get-InstallDirectory $Entry)
    if ($DryRun) { Write-Step 'Apply the Census API-key patch if needed.'; return }
    $git = Find-Command @('git.exe', 'git')
    & $git -C $target apply --check -- $censusPatch 2>$null
    if ($LASTEXITCODE -eq 0) {
        Run-GitCommand $git @('-C', $target, 'apply', '--', $censusPatch) | Out-Null
        return
    }
    & $git -C $target apply --reverse --check -- $censusPatch 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'The Census patch is neither applicable nor already applied.' }
}

function Build-Entry {
    param([Parameter(Mandatory = $true)]$Entry)

    $sourceType = if ($null -ne $Entry.source -and $Entry.source.type) { [string]$Entry.source.type } else { [string]$Entry.source.kind }
    if ($null -eq $Entry.source -or $sourceType -ne 'git') { return }
    $entryName = Get-EntryName $Entry
    if ($entryName -eq 'econ_census') { return }
    if ($entryName -eq 'econ_alpha_vantage') {
        $workingDirectory = Join-Path $mcpRoot 'alpha_vantage_mcp\mcp'
        if ($DryRun) { Write-Step 'Build econ_alpha_vantage: uv sync'; return }
        Push-Location $workingDirectory
        try { Run-Command (Find-Command @('uv.exe', 'uv')) @('sync') | Out-Null }
        finally { Pop-Location }
        return
    }
    $directory = Get-InstallDirectory $Entry
    $workingDirectory = Join-Path $mcpRoot $directory
    if ($null -ne $Entry.setup -and $Entry.setup.working_dir) {
        $candidate = ([string]$Entry.setup.working_dir).Replace('{install_root}', $mcpRoot).Replace('/', '\')
        $workingDirectory = [IO.Path]::GetFullPath($candidate)
        $rootPrefix = $mcpRoot.TrimEnd('\') + '\'
        if (-not $workingDirectory.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe build directory for $(Get-EntryName $Entry)." }
    }
    elseif ($null -ne $Entry.build -and $Entry.build.working_directory) {
        $relative = [string]$Entry.build.working_directory
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { throw "Unsafe build directory for $(Get-EntryName $Entry)." }
        $workingDirectory = Join-Path $workingDirectory $relative
    }

    $commands = if ($null -ne $Entry.setup -and $null -ne $Entry.setup.commands) { @($Entry.setup.commands) } else { @($Entry.build.commands) }
    foreach ($buildCommand in $commands) {
        $text = ([string]$buildCommand).Trim()
        if (-not $text) { continue }
        if ($DryRun) { Write-Step "Build $(Get-EntryName $Entry): $text"; continue }
        Push-Location $workingDirectory
        try {
            switch -Regex ($text) {
                '^npm install$' { Run-Command (Find-Command @('npm.cmd', 'npm.exe', 'npm')) @('install') | Out-Null; break }
                '^npm ci$' { Run-Command (Find-Command @('npm.cmd', 'npm.exe', 'npm')) @('ci') | Out-Null; break }
                '^npm run build$' { Run-Command (Find-Command @('npm.cmd', 'npm.exe', 'npm')) @('run', 'build') | Out-Null; break }
                '^uv sync$' { Run-Command (Find-Command @('uv.exe', 'uv')) @('sync') | Out-Null; break }
                default { throw "Unsupported manifest build command for $(Get-EntryName $Entry): $text" }
            }
        }
        finally { Pop-Location }
    }
}

function Normalize-Label {
    param([Parameter(Mandatory = $true)][string]$Label)
    return ($Label.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Resolve-SecretName {
    param([Parameter(Mandatory = $true)][string]$Label)
    $allowedNames = @(
        'ALPHA_VANTAGE_API_KEY', 'BEA_API_KEY', 'BLS_API_KEY', 'CENSUS_API_KEY',
        'COMTRADE_SUBSCRIPTION_KEY', 'DC_API_KEY', 'FINANCIAL_DATASETS_API_KEY',
        'FRED_API_KEY', 'NASDAQ_DATA_LINK_API_KEY', 'SEC_EDGAR_USER_AGENT')
    if ($allowedNames -ccontains $Label) { return $Label }
    $labelKey = Normalize-Label $Label
    if ($labelKey -match 'alphavantage') { return 'ALPHA_VANTAGE_API_KEY' }
    if ($labelKey -match 'financialdatasets') { return 'FINANCIAL_DATASETS_API_KEY' }
    if ($labelKey -match 'nasdaq.*(?:datalink|quandl)') { return 'NASDAQ_DATA_LINK_API_KEY' }
    if ($labelKey -match 'datacommons') { return 'DC_API_KEY' }
    if ($labelKey -match 'comtrade') { return 'COMTRADE_SUBSCRIPTION_KEY' }
    if ($labelKey -match 'census') { return 'CENSUS_API_KEY' }
    if ($labelKey -match 'fred') { return 'FRED_API_KEY' }
    if ($labelKey -match 'sec.*(?:edgar|useragent)') { return 'SEC_EDGAR_USER_AGENT' }
    if ($labelKey -match 'bea') { return 'BEA_API_KEY' }
    if ($labelKey -match 'bls') { return 'BLS_API_KEY' }
    return $null
}

function Import-KeyFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Secrets
    )

    foreach ($rawLine in [IO.File]::ReadAllLines($Path)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line -notmatch '^([^:=]+?)\s*[:=]\s*(.+)$') { continue }
        $name = Resolve-SecretName $Matches[1].Trim()
        if (-not $name) { continue }
        $value = $Matches[2].Trim().Trim('"').Trim("'")
        if ($value -match '[\r\n]') { throw "Value for $name contains a newline." }
        if ($value) { $Secrets[$name] = $value }
    }
}

function Convert-SecureValue {
    param([Parameter(Mandatory = $true)][Security.SecureString]$Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Protect-LocalPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Directory
    )

    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($Directory) {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    }
    else {
        $acl = New-Object Security.AccessControl.FileSecurity
        $inheritance = [Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        $sid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
        [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Save-Secrets {
    param([Parameter(Mandatory = $true)][hashtable]$Secrets)
    if ($DryRun) { Write-Step "Save $($Secrets.Count) named secrets locally and restrict the ACL."; return }
    Ensure-Directory $secretDirectory
    $lines = foreach ($name in ($Secrets.Keys | Sort-Object)) {
        $value = [string]$Secrets[$name]
        if ($value -match '[\r\n]') { throw "Value for $name contains a newline." }
        "${name}=$value"
    }
    [IO.File]::WriteAllLines($secretPath, [string[]]$lines, [Text.UTF8Encoding]::new($false))
    Protect-LocalPath $secretDirectory $true
    Protect-LocalPath $secretPath $false
}

function Initialize-Census {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][hashtable]$Secrets
    )

    $seedMarker = Join-Path $mcpRoot '.census-slim-seeded'
    if ($SkipCensusInit) { Write-Step 'Skip Census initialization.'; return }
    if (Test-Path -LiteralPath $seedMarker -PathType Leaf) {
        Write-Step 'Census slim database is already initialized.'
        return
    }
    if (-not $Secrets.ContainsKey('CENSUS_API_KEY')) { Write-Warning 'CENSUS_API_KEY is absent; Census initialization was skipped.'; return }
    if ($DryRun) { Write-Step 'Build Census images, run migrations, slim-seed, and start services.'; return }

    $docker = Find-Command @('docker.exe', 'docker')
    Run-Command $docker @('info') | Out-Null
    $directory = Join-Path $mcpRoot (Get-InstallDirectory $Entry)
    $oldKey = [Environment]::GetEnvironmentVariable('CENSUS_API_KEY', 'Process')
    $oldMode = [Environment]::GetEnvironmentVariable('SEED_MODE', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('CENSUS_API_KEY', [string]$Secrets.CENSUS_API_KEY, 'Process')
        [Environment]::SetEnvironmentVariable('SEED_MODE', 'slim', 'Process')
        Push-Location $directory
        try {
            Run-Command $docker @('compose', '--profile', 'prod', 'build') | Out-Null
            Run-Command $docker @(
                'compose', '--profile', 'prod', 'run', '--rm', '-e', 'SEED_MODE=slim',
                '-e', 'CENSUS_API_KEY', 'census-mcp-db-init', 'sh', '-c',
                'npm run migrate:up && npm run seed'
            ) | Out-Null
            Run-Command $docker @('compose', '--profile', 'prod', 'up', '-d') | Out-Null
            [IO.File]::WriteAllText($seedMarker, ([DateTime]::UtcNow.ToString('o')), [Text.UTF8Encoding]::new($false))
        }
        finally { Pop-Location }
    }
    finally {
        [Environment]::SetEnvironmentVariable('CENSUS_API_KEY', $oldKey, 'Process')
        [Environment]::SetEnvironmentVariable('SEED_MODE', $oldMode, 'Process')
    }
}

function Register-Entries {
    param(
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [Parameter(Mandatory = $true)][hashtable]$Secrets
    )

    $codex = if ($DryRun) { 'codex' } else { Find-Command @('codex.exe', 'codex.cmd', 'codex') }
    $shell = if ($DryRun) { 'powershell' } else { (Get-Process -Id $PID).Path }
    $previousCodexRoot = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $CodexRoot, 'Process')
        foreach ($entry in $Entries) {
            $name = Get-EntryName $entry
            if ($name -notmatch '^econ_[a-z0-9_]+$' -and $name -ne 'stata-mcp') {
                throw "Refusing to manage an unexpected MCP: $name"
            }
            $keyMissing =
                ($name -eq 'econ_financial_datasets' -and -not $Secrets.ContainsKey('FINANCIAL_DATASETS_API_KEY')) -or
                ($name -eq 'econ_nasdaq_data_link' -and -not $Secrets.ContainsKey('NASDAQ_DATA_LINK_API_KEY'))
            if ($DryRun) {
                if ($keyMissing) { Write-Step "Remove $name registration because its API key is absent." }
                else { Write-Step "Replace Codex registration for $name." }
                continue
            }

            Run-Command $codex @('mcp', 'remove', $name) -AllowFailure | Out-Null
            if ($keyMissing) {
                Write-Step "Do not register $name because its API key is absent."
                continue
            }
            Run-Command $codex @(
                'mcp', 'add', $name, '--', $shell, '-NoLogo', '-NoProfile', '-NonInteractive',
                '-ExecutionPolicy', 'Bypass', '-File', $launcherTarget, '-Name', $name,
                '-CodexRoot', $CodexRoot
            ) | Out-Null
        }
    }
    finally { [Environment]::SetEnvironmentVariable('CODEX_HOME', $previousCodexRoot, 'Process') }
}

function Backup-CodexConfig {
    $configPath = Join-Path $CodexRoot 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDirectory = Join-Path $CodexRoot 'backups\config'
    $backupPath = Join-Path $backupDirectory "config.toml.$stamp.bak"
    if ($DryRun) {
        Write-Step "Back up existing Codex config to $backupPath."
        return
    }
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    Copy-Item -LiteralPath $configPath -Destination $backupPath
    Write-Step "Backed up existing Codex config to $backupPath."
}

Require-File $manifestPath
Require-File $launcherSource
try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
catch { throw "Manifest JSON is invalid: $($_.Exception.Message)" }
$entries = @(Get-Entries $manifest)
if ($entries.Count -ne 18) { throw "Manifest must contain 18 MCP entries; found $($entries.Count)." }
$entryNames = @($entries | ForEach-Object { Get-EntryName $_ })
if (@($entryNames | Select-Object -Unique).Count -ne 18) { throw 'Manifest contains duplicate MCP names.' }
foreach ($entry in $entries) {
    $name = Get-EntryName $entry
    if ($name -notmatch '^econ_[a-z0-9_]+$' -and $name -ne 'stata-mcp') {
        throw "Manifest contains an unexpected MCP: $name"
    }
    $sourceType = if ($entry.source.type) { [string]$entry.source.type } else { [string]$entry.source.kind }
    if ($sourceType -eq 'git') {
        $commitProperty = $entry.source.PSObject.Properties['commit']
        if ($null -eq $commitProperty) { $commitProperty = $entry.source.PSObject.Properties['resolved_commit'] }
        $commit = if ($null -ne $commitProperty) { [string]$commitProperty.Value } else { '' }
        if ($commit -notmatch '^[0-9a-fA-F]{40}$') { throw "$name is not pinned to a full Git commit." }
    }
}

$secrets = @{}
if (Test-Path -LiteralPath $secretPath -PathType Leaf) { Import-KeyFile $secretPath $secrets }
if ($ApiKeysFile) {
    $ApiKeysFile = [IO.Path]::GetFullPath($ApiKeysFile)
    if (-not (Test-Path -LiteralPath $ApiKeysFile -PathType Leaf)) { throw "API keys file is missing: $ApiKeysFile" }
    Import-KeyFile $ApiKeysFile $secrets
}

$requiredSecretNames = @('ALPHA_VANTAGE_API_KEY', 'BEA_API_KEY', 'BLS_API_KEY', 'CENSUS_API_KEY', 'COMTRADE_SUBSCRIPTION_KEY', 'DC_API_KEY', 'FRED_API_KEY', 'SEC_EDGAR_USER_AGENT')
if (-not $NonInteractive -and -not $DryRun) {
    foreach ($name in $requiredSecretNames) {
        if ($secrets.ContainsKey($name) -and $secrets[$name]) { continue }
        $secure = Read-Host "$name (required; input hidden)" -AsSecureString
        $plain = Convert-SecureValue $secure
        if ($plain) { $secrets[$name] = $plain }
    }
}
$missingRequired = @($requiredSecretNames | Where-Object { -not $secrets.ContainsKey($_) -or -not $secrets[$_] })
if ($missingRequired.Count -gt 0) {
    if ($DryRun) { Write-Step "Missing required local values: $($missingRequired -join ', ')." }
    else { throw "Missing required local values: $($missingRequired -join ', ')." }
}

Ensure-Directory $mcpRoot
foreach ($entry in $entries) { Ensure-FixedCheckout $entry }
$census = $entries | Where-Object { (Get-EntryName $_) -eq 'econ_census' } | Select-Object -First 1
if ($null -ne $census) { Apply-CensusPatch $census }
foreach ($entry in $entries) { Build-Entry $entry }
Save-Secrets $secrets
Ensure-Directory $launcherDirectory
if ($DryRun) { Write-Step "Copy launcher to $launcherTarget." } else { Copy-Item -LiteralPath $launcherSource -Destination $launcherTarget -Force }
if ($null -ne $census) { Initialize-Census $census $secrets }
Backup-CodexConfig
Register-Entries $entries $secrets
Write-Output 'Windows MCP installation completed.'
