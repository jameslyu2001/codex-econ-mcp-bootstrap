# API key 与本地标签映射

本文件只记录变量名、`API Keys.txt` 中的标签和申请网址，**不包含任何值**。目标机器上的 key 应在安装时本地读取或隐藏输入，不能提交到 Git，也不能打印到命令历史、Actions 或 Docker 日志中。

## 已有标签映射

当前用户的 `API Keys.txt` 只核对了标签名称，没有把值读取到本文档中：

| MCP | 本地变量或逻辑名称 | `API Keys.txt` 标签 | 申请/说明网址 | 备注 |
| --- | --- | --- | --- | --- |
| `econ_alpha_vantage` | `ALPHA_VANTAGE_API_KEY` | `Alpha Vantage` | https://www.alphavantage.co/support/#api-key | 当前 MCP 把值作为位置参数传入；`econ_tam` 使用同一值的环境变量。 |
| `econ_bea` | `BEA_API_KEY` | `BEA` | https://apps.bea.gov/API/signup/ | 按当前配置使用。 |
| `econ_bls` | `BLS_API_KEY` | `BLS` | https://data.bls.gov/registrationEngine/ | BLS 无 key 时额度较低；当前配置使用该 key。 |
| `econ_census` | `CENSUS_API_KEY` | `Open Census MCP Server` | https://api.census.gov/data/key_signup.html | MCP 运行与首次 seed 都要在本机注入。 |
| `econ_data_commons` | `DC_API_KEY` | `Data Commons` | https://apikeys.datacommons.org/ | 按当前配置使用。 |
| `econ_fred` | `FRED_API_KEY` | `FRED` | https://fred.stlouisfed.org/docs/api/api_key.html | 按当前配置使用。 |
| `econ_sec_edgar` | `SEC_EDGAR_USER_AGENT` | `SEC_EDGAR_USER_AGENT` | https://www.sec.gov/search-filings/edgar-application-programming-interfaces | 不是 API key；应是能识别应用/个人的合规 User-Agent，可能含邮箱，因此仍按本地敏感配置处理。 |
| `econ_un_comtrade` | `COMTRADE_SUBSCRIPTION_KEY` | `un-comtrade` | https://comtradedeveloper.un.org/ | 在 UN Comtrade Developer Portal 登录并取得 subscription key。 |

## 当前缺失的标签

| MCP | 变量名 | 建议新增的 `API Keys.txt` 标签 | 申请/说明网址 | 当前状态 |
| --- | --- | --- | --- | --- |
| `econ_financial_datasets` | `FINANCIAL_DATASETS_API_KEY` | `Financial Datasets` | https://docs.financialdatasets.ai/introduction | 当前本机 key 文件未找到，MCP 默认禁用。 |
| `econ_nasdaq_data_link` | `NASDAQ_DATA_LINK_API_KEY` | `Nasdaq Data Link` | https://data.nasdaq.com/sign-up | 当前本机 key 文件未找到，MCP 默认禁用。 |

## 无需 API key 的 MCP

`econ_ecb`、`econ_eurostat`、`econ_imf`、`econ_oecd`、`econ_world_bank` 和 `stata-mcp` 不需要在当前配置中提供 API key。`stata-mcp` 需要本机已授权的 Stata；可选的 `STATA_CLI` 是可执行文件路径，不是凭据。

`econ_world_bank_data360` 使用两个非秘密的服务地址变量：

- `DATA360_API_BASE_URL`
- `DATA360_CODELIST_API_BASE_URL`

它们是 endpoint 配置，不是凭据。安装器应从 manifest 的默认值生成本机配置，不应写入 `API Keys.txt`。

## `econ_tam` 的复用关系

`econ_tam` 复用以下本地凭据：

- `ALPHA_VANTAGE_API_KEY` ← `Alpha Vantage`
- `BLS_API_KEY` ← `BLS`
- `CENSUS_API_KEY` ← `Open Census MCP Server`
- `FRED_API_KEY` ← `FRED`
- `NASDAQ_DATA_LINK_API_KEY` ← `Nasdaq Data Link`（当前缺失，可按上游功能作为可选项处理）

## 安全读取流程

1. 只在目标机器本地打开 `API Keys.txt`，按本页标签匹配。
2. 不把文件复制进仓库或临时 clone；不把真实值拼进 Git URL。
3. 写配置和日志前对值脱敏；健康检查只报告成功/失败或长度，不回显值。
4. 安装器把合并后的值写入 `~/.codex/secrets/econ-mcp.env`：Windows 移除继承 ACL 并只授权当前用户，macOS 设置为 `600`。这个文件不会进入仓库或 `config.toml`。
5. Alpha Vantage 上游只接受位置参数，因此本机启动器必须把该 key 传给子进程；在多人共用的机器上应额外考虑本地进程检查风险。
6. 如果 key 曾进入 Git 历史，先撤销或轮换，再清理历史；只删除当前文件不足以使旧 key 失效。
