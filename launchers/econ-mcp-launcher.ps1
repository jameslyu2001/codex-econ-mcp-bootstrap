[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('econ_bls', 'econ_ecb', 'econ_eurostat', 'econ_imf', 'econ_oecd',
        'econ_world_bank', 'econ_world_bank_data360', 'econ_un_comtrade',
        'econ_alpha_vantage', 'econ_bea', 'econ_census', 'econ_data_commons',
        'econ_financial_datasets', 'econ_fred', 'econ_nasdaq_data_link',
        'econ_sec_edgar', 'econ_tam', 'stata-mcp')]
    [Alias('ServerName')]
    [string]$Name,
    [string]$CodexRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$mcpRoot = Join-Path $CodexRoot 'mcp-servers\economic-data'
$secretPath = Join-Path $CodexRoot 'secrets\econ-mcp.env'

function Import-Secrets {
    if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) { return }
    foreach ($line in Get-Content -LiteralPath $secretPath) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        $separator = $line.IndexOf('=')
        if ($separator -le 0) { continue }
        $variableName = $line.Substring(0, $separator).Trim()
        if ($variableName -match '^[A-Z][A-Z0-9_]+$') {
            [Environment]::SetEnvironmentVariable($variableName, $line.Substring($separator + 1), 'Process')
        }
    }
}

function Find-Program {
    param([string[]]$Names, [string[]]$Fallbacks = @())
    foreach ($candidateName in $Names) {
        $candidate = Get-Command $candidateName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $candidate) { return $candidate.Source }
    }
    foreach ($candidate in $Fallbacks) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    throw "Required executable is missing: $($Names -join ', ')"
}

function Need-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "MCP entry point is missing: $Path" }
    return $Path
}

function Need-Secret {
    param([string]$VariableName)
    $value = [Environment]::GetEnvironmentVariable($VariableName, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Required local credential is missing: $VariableName" }
    return $value
}

function Start-Mcp {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
    exit 0
}

Import-Secrets

switch ($Name) {
    'econ_bls' {
        Start-Mcp (Find-Program @('node.exe', 'node')) @((Need-File (Join-Path $mcpRoot 'mcp-bls\dist\index.js')))
    }
    'econ_ecb' {
        Start-Mcp (Find-Program @('node.exe', 'node')) @((Need-File (Join-Path $mcpRoot 'ecb-mcp\dist\index.js')))
    }
    'econ_eurostat' {
        Start-Mcp (Find-Program @('uv.exe', 'uv')) @('--directory', (Join-Path $mcpRoot 'eurostat-mcp'), 'run', 'server.py')
    }
    'econ_imf' {
        Start-Mcp (Find-Program @('uv.exe', 'uv')) @('--directory', (Join-Path $mcpRoot 'imf-data-mcp'), 'run', 'imf-data-mcp')
    }
    'econ_oecd' {
        Start-Mcp (Find-Program @('node.exe', 'node')) @((Need-File (Join-Path $mcpRoot 'oecd-mcp\dist\index.js')))
    }
    'econ_world_bank' {
        Start-Mcp (Find-Program @('uv.exe', 'uv')) @('--directory', (Join-Path $mcpRoot 'world_bank_mcp_server'), 'run', 'world_bank_mcp_server')
    }
    'econ_world_bank_data360' {
        Start-Mcp (Find-Program @('uv.exe', 'uv')) @(
            '--directory', (Join-Path $mcpRoot 'data360-mcp'), 'run', 'fastmcp', 'run',
            'src/data360/server.py', '--transport', 'stdio')
    }
    'econ_un_comtrade' {
        Start-Mcp (Find-Program @('npx.cmd', 'npx')) @('-y', '@cyanheads/un-comtrade-mcp-server@0.1.5')
    }
    'econ_alpha_vantage' {
        $apiKey = Need-Secret 'ALPHA_VANTAGE_API_KEY'
        Start-Mcp (Find-Program @('uv.exe', 'uv')) @(
            '--directory', (Join-Path $mcpRoot 'alpha_vantage_mcp\mcp'), 'run', 'marketdata-mcp-server', $apiKey)
    }
    'econ_bea' {
        Start-Mcp (Find-Program @('node.exe', 'node')) @((Need-File (Join-Path $mcpRoot 'mcp-bea\dist\index.js')))
    }
    'econ_census' {
        $fallbacks = @(
            (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Git\bin\bash.exe'),
            (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Git\bin\bash.exe'),
            (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\Git\bin\bash.exe'))
        Start-Mcp (Find-Program @('bash.exe', 'bash') $fallbacks) @(
            (Need-File (Join-Path $mcpRoot 'us-census-bureau-data-api-mcp\scripts\mcp-connect.sh')))
    }
    'econ_data_commons' {
        Start-Mcp (Find-Program @('uv.exe', 'uv')) @(
            '--directory', (Join-Path $mcpRoot 'datacommons-agent-toolkit\packages\datacommons-mcp'),
            'run', 'datacommons-mcp', 'serve', 'stdio')
    }
    'econ_financial_datasets' {
        [void](Need-Secret 'FINANCIAL_DATASETS_API_KEY')
        Start-Mcp (Find-Program @('uv.exe', 'uv')) @(
            '--directory', (Join-Path $mcpRoot 'financial-datasets-mcp-server'), 'run', 'server.py')
    }
    'econ_fred' {
        Start-Mcp (Find-Program @('node.exe', 'node')) @((Need-File (Join-Path $mcpRoot 'fred-mcp-server\build\index.js')))
    }
    'econ_nasdaq_data_link' {
        [void](Need-Secret 'NASDAQ_DATA_LINK_API_KEY')
        [Environment]::SetEnvironmentVariable('PYTHONPATH', (Join-Path $mcpRoot 'nasdaq-data-link-mcp'), 'Process')
        Start-Mcp (Find-Program @('uv.exe', 'uv')) @(
            '--directory', (Join-Path $mcpRoot 'nasdaq-data-link-mcp'), 'run', 'python', 'nasdaq_data_link_mcp_os/server.py')
    }
    'econ_sec_edgar' {
        Start-Mcp (Find-Program @('uv.exe', 'uv')) @('--directory', (Join-Path $mcpRoot 'sec-edgar-mcp'), 'run', 'sec-edgar-mcp')
    }
    'econ_tam' {
        Start-Mcp (Find-Program @('node.exe', 'node')) @((Need-File (Join-Path $mcpRoot 'TAM-MCP-Server\dist\stdio-simple.js')))
    }
    'stata-mcp' {
        Start-Mcp (Find-Program @('uv.exe', 'uv')) @(
            '--directory', (Join-Path $mcpRoot 'mcp-for-stata'), 'run', '--frozen', 'stata-mcp')
    }
}
