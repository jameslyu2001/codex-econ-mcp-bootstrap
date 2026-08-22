[CmdletBinding()]
param(
    [string]$CodexRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$mcpRoot = Join-Path $CodexRoot 'mcp-servers\economic-data'
$secretsFile = Join-Path $CodexRoot 'secrets\econ-mcp.env'

$checks = @(
    @('file', 'lock manifest', (Join-Path $repoRoot 'manifests\mcps.lock.json')),
    @('file', 'installed launcher', (Join-Path $CodexRoot 'mcp-bootstrap\econ-mcp-launcher.ps1')),
    @('file', 'local secrets file', $secretsFile),
    @('command', 'git', 'git.exe'),
    @('command', 'node', 'node.exe'),
    @('command', 'npm', 'npm.cmd'),
    @('command', 'npx', 'npx.cmd'),
    @('command', 'uv', 'uv.exe'),
    @('command', 'uvx', 'uvx.exe'),
    @('command', 'codex', 'codex.exe'),
    @('command', 'docker', 'docker.exe'),
    @('directory', 'econ_bls source', (Join-Path $mcpRoot 'mcp-bls')),
    @('file', 'econ_bls entry point', (Join-Path $mcpRoot 'mcp-bls\dist\index.js')),
    @('directory', 'econ_ecb source', (Join-Path $mcpRoot 'ecb-mcp')),
    @('file', 'econ_ecb entry point', (Join-Path $mcpRoot 'ecb-mcp\dist\index.js')),
    @('directory', 'econ_eurostat source', (Join-Path $mcpRoot 'eurostat-mcp')),
    @('directory', 'econ_imf source', (Join-Path $mcpRoot 'imf-data-mcp')),
    @('directory', 'econ_oecd source', (Join-Path $mcpRoot 'oecd-mcp')),
    @('file', 'econ_oecd entry point', (Join-Path $mcpRoot 'oecd-mcp\dist\index.js')),
    @('directory', 'econ_world_bank source', (Join-Path $mcpRoot 'world_bank_mcp_server')),
    @('directory', 'econ_world_bank_data360 source', (Join-Path $mcpRoot 'data360-mcp')),
    @('command', 'econ_un_comtrade npx runtime', 'npx.cmd'),
    @('directory', 'econ_alpha_vantage source', (Join-Path $mcpRoot 'alpha_vantage_mcp')),
    @('directory', 'econ_bea source', (Join-Path $mcpRoot 'mcp-bea')),
    @('file', 'econ_bea entry point', (Join-Path $mcpRoot 'mcp-bea\dist\index.js')),
    @('directory', 'econ_census source', (Join-Path $mcpRoot 'us-census-bureau-data-api-mcp')),
    @('file', 'econ_census entry point', (Join-Path $mcpRoot 'us-census-bureau-data-api-mcp\scripts\mcp-connect.sh')),
    @('directory', 'econ_data_commons source', (Join-Path $mcpRoot 'datacommons-agent-toolkit')),
    @('directory', 'econ_financial_datasets source', (Join-Path $mcpRoot 'financial-datasets-mcp-server')),
    @('directory', 'econ_fred source', (Join-Path $mcpRoot 'fred-mcp-server')),
    @('file', 'econ_fred entry point', (Join-Path $mcpRoot 'fred-mcp-server\build\index.js')),
    @('directory', 'econ_nasdaq_data_link source', (Join-Path $mcpRoot 'nasdaq-data-link-mcp')),
    @('directory', 'econ_sec_edgar source', (Join-Path $mcpRoot 'sec-edgar-mcp')),
    @('directory', 'econ_tam source', (Join-Path $mcpRoot 'TAM-MCP-Server')),
    @('file', 'econ_tam entry point', (Join-Path $mcpRoot 'TAM-MCP-Server\dist\stdio-simple.js'))
)

foreach ($check in $checks) {
    $present = switch ($check[0]) {
        'command' { $null -ne (Get-Command $check[2] -ErrorAction SilentlyContinue) }
        'directory' { Test-Path -LiteralPath $check[2] -PathType Container }
        'file' { Test-Path -LiteralPath $check[2] -PathType Leaf }
    }
    $status = if ($present) { 'PRESENT' } else { 'MISSING' }
    Write-Output ('{0,-8} {1}' -f $status, $check[1])
}

$credentialNames = @{}
if (Test-Path -LiteralPath $secretsFile -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $secretsFile) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            $name = $line.Substring(0, $separator).Trim()
            if ($name -match '^[A-Z][A-Z0-9_]+$') { $credentialNames[$name] = $true }
        }
    }
}

foreach ($name in @(
    'ALPHA_VANTAGE_API_KEY', 'BEA_API_KEY', 'BLS_API_KEY', 'CENSUS_API_KEY',
    'COMTRADE_SUBSCRIPTION_KEY', 'DC_API_KEY', 'FINANCIAL_DATASETS_API_KEY',
    'FRED_API_KEY', 'NASDAQ_DATA_LINK_API_KEY', 'SEC_EDGAR_USER_AGENT')) {
    $status = if ($credentialNames.ContainsKey($name)) { 'PRESENT' } else { 'MISSING' }
    Write-Output ('{0,-8} credential name {1}' -f $status, $name)
}
