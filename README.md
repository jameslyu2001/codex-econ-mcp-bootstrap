# Codex Economic Data MCP Bootstrap

这是一个跨 Windows 与 macOS 的 Codex 经济数据 MCP 安装仓库。它会按 lock manifest 安装 18 个 MCP、导入本机 API key、初始化 Census 数据库，并通过官方 `codex mcp add` 写入 `~/.codex/config.toml`。

> 本仓库是私有的，但仍然不保存任何真实 API key。密钥只从每台电脑的本地文件或隐藏输入导入，并写到 `~/.codex/secrets/econ-mcp.env`。

## 收录的 MCP

`econ_bls`、`econ_ecb`、`econ_eurostat`、`econ_imf`、`econ_oecd`、`econ_world_bank`、`econ_world_bank_data360`、`econ_un_comtrade`、`econ_alpha_vantage`、`econ_bea`、`econ_census`、`econ_data_commons`、`econ_financial_datasets`、`econ_fred`、`econ_nasdaq_data_link`、`econ_sec_edgar`、`econ_tam`、`stata-mcp`。

- 17 个 Git 项固定到完整 commit。
- UN Comtrade 固定到 `@cyanheads/un-comtrade-mcp-server@0.1.5`。
- 缺少 `FINANCIAL_DATASETS_API_KEY` 或 `NASDAQ_DATA_LINK_API_KEY` 时，对应源码仍会安装，但 MCP 不会注册。
- `stata-mcp` 固定到 [SepineTam/mcp-for-stata](https://github.com/SepineTam/mcp-for-stata) 的完整 commit，对应上游 `v1.22.0`；它不需要 API key，但需要有效的 Stata 安装与许可证。

## 前置条件

两种平台均需安装：

- Codex CLI、Git、Node.js 18+、npm/npx、Python、`uv`/`uvx`
- GitHub CLI `gh`，且已登录有权访问本私有仓库的账户
- Docker Desktop 与 Docker Compose v2，用于 `econ_census`
- Python 3.11+ 与已授权的 Stata，用于 `stata-mcp`

macOS 当前 lock 中的 Data360 需要 Python 3.11+。Windows 建议使用 PowerShell 7。

## Windows 一键安装

```powershell
gh repo clone jameslyu2001/codex-econ-mcp-bootstrap
cd codex-econ-mcp-bootstrap
.\install-windows.ps1 -ApiKeysFile "C:\path\to\API Keys.txt"
```

不提供 key 文件时，安装器会对必需项目进行隐藏输入：

```powershell
.\install-windows.ps1
```

检查结果：

```powershell
.\doctor-windows.ps1
codex mcp list
```

## macOS 一键安装

```bash
gh repo clone jameslyu2001/codex-econ-mcp-bootstrap
cd codex-econ-mcp-bootstrap
chmod +x install-macos.sh doctor-macos.sh launchers/econ-mcp-launcher.sh
./install-macos.sh --api-keys-file "$HOME/path/API Keys.txt"
```

不提供 key 文件时会隐藏输入。检查结果：

```bash
./doctor-macos.sh
codex mcp list
```

## 常用选项

Windows：

```powershell
# 只预览，不写文件、不注册、不启动 Docker
.\install-windows.ps1 -DryRun -SkipCensusInit

# 自动化环境：不提示，缺少必需 key 时直接失败
.\install-windows.ps1 -ApiKeysFile "C:\path\to\API Keys.txt" -NonInteractive
```

macOS：

```bash
./install-macos.sh --dry-run --skip-census-init
./install-macos.sh --api-keys-file "$HOME/path/API Keys.txt" --non-interactive
```

## API key

支持 `KEY=VALUE`，也支持当前使用的友好标签格式。完整映射和申请地址见 [`docs/API_KEYS.md`](docs/API_KEYS.md)。主要映射如下：

| 本地标签 | 环境变量 |
| --- | --- |
| Alpha Vantage | `ALPHA_VANTAGE_API_KEY` |
| BEA | `BEA_API_KEY` |
| BLS | `BLS_API_KEY` |
| Open Census MCP Server | `CENSUS_API_KEY` |
| Data Commons | `DC_API_KEY` |
| FRED | `FRED_API_KEY` |
| un-comtrade | `COMTRADE_SUBSCRIPTION_KEY` |
| Financial Datasets | `FINANCIAL_DATASETS_API_KEY`（可选） |
| Nasdaq Data Link | `NASDAQ_DATA_LINK_API_KEY`（可选） |

SEC EDGAR 还需要本机的 `SEC_EDGAR_USER_AGENT`，它不是 API key，但仍作为敏感本地配置保存。

## Stata MCP

`stata-mcp` 使用上游 canonical 注册名，不需要写入 `econ-mcp.env`。安装器从固定 commit 创建本地 `.venv`，启动器通过：

```console
uv --directory ~/.codex/mcp-servers/economic-data/mcp-for-stata run --frozen stata-mcp
```

上游会自动寻找 Stata。需要覆盖路径时，使用环境变量 `STATA_CLI` 或本机配置 `~/.statamcp/config.toml`；这些机器相关路径不会进入 Git。可运行以下命令只检查 Stata 路径：

```console
uv --directory ~/.codex/mcp-servers/economic-data/mcp-for-stata run --frozen stata-mcp doctor --check stata_cli
```

## 安装器会改动什么

- 源码：`~/.codex/mcp-servers/economic-data/`
- 本机密钥：`~/.codex/secrets/econ-mcp.env`
- 启动器：Windows 为 `~/.codex/mcp-bootstrap/econ-mcp-launcher.ps1`，macOS 为 `~/.codex/launchers/econ-mcp-launcher.sh`
- Codex 配置：只通过 `codex mcp remove/add` 管理上述 `econ_*` 名称和 `stata-mcp`
- 配置备份：注册前复制到 `~/.codex/backups/config/`

Windows 会把 secret 文件 ACL 限制为当前用户；macOS 使用权限 `600`。启动器在 MCP 进程启动时读取本机 secret 文件，真实值不会写进 Git 或 `config.toml`。

## Census 初始化

安装器会在固定 commit 上应用 [`patches/census-api-key.patch`](patches/census-api-key.patch)，将 `CENSUS_API_KEY` 只传给 Census API 请求并在日志中脱敏。首次安装默认执行：

1. Docker Compose build
2. 数据库 migration
3. `SEED_MODE=slim` seed
4. 启动 production profile

成功后写入本机 marker，使后续安装保持幂等。需要暂时跳过时使用 `-SkipCensusInit` 或 `--skip-census-init`。

## 安全与复现

- 不要提交 `API Keys.txt`、`.env`、`config.toml`、日志、数据库数据或任何 token。
- 所有 Git 上游均固定完整 commit；npm 上游固定精确版本。
- 安装器只替换无本地修改的旧 checkout；检测到改动会停止。
- 静态检查会拦截常见 secret、硬编码用户路径和未固定 Git 来源。

```powershell
.\tests\static-check.ps1
```

```bash
bash tests/static-check.sh
```

安装或更新后请重启 Codex，使桌面端、CLI 和 IDE 重新载入配置。Codex MCP 的共享配置和 CLI 命令以 [OpenAI 官方 MCP 文档](https://developers.openai.com/codex/mcp/) 为准。

## 第三方许可证

本仓库的 MIT License 只覆盖自行编写的安装器、启动器、补丁和文档。第三方 MCP 源码与名称仍由各自上游许可证约束，本仓库不会把这些源码提交到 Git；MCP-for-Stata 上游使用 AGPL-3.0。
