# 云端R分析部署指南

## 项目结构

```
cloud-r-analysis/
├── .github/workflows/
│   └── r-analysis.yml          # GitHub Actions工作流
├── input/
│   ├── tickers_macro.xlsx      # 股票代码列表
│   └── template_AnalysisReport.xlsx  # 报告模板
├── output/                     # 输出目录（运行时生成）
├── scripts/
│   └── nutstore_sync.py        # 坚果云同步脚本
├── MarketAnalytics_cloud.R     # 云端版R分析脚本
├── renv.lock                   # R包版本锁定
└── README.md
```

## 快速部署步骤

### 1. 创建GitHub仓库

1. 在GitHub上创建新仓库（如 `cloud-r-analysis`）
2. 将本项目代码推送到仓库：

```bash
git init
git add .
git commit -m "Initial commit: Cloud R Analysis Pipeline"
git remote add origin https://github.com/YOUR_USERNAME/cloud-r-analysis.git
git push -u origin main
```

### 2. 配置GitHub Secrets

进入仓库 Settings -> Secrets and variables -> Actions，添加以下Secrets：

| Secret Name | Value | 获取方式 |
|------------|-------|---------|
| `NUTSTORE_USER` | 坚果云邮箱 | 坚果云账号 |
| `NUTSTORE_PASSWORD` | 应用密码 | 坚果云设置 -> 第三方应用管理 |
| `NUTSTORE_WEBDAV_URL` | `https://dav.jianguoyun.com/dav/` | 固定值 |
| `NUTSTORE_REMOTE_PATH` | `/R-Analysis-Output/` | 自定义远程路径 |

**坚果云应用密码获取步骤：**
1. 登录坚果云网页版
2. 点击右上角用户名 -> 账户信息
3. 选择"安全选项" -> "第三方应用管理"
4. 添加应用，获取应用密码

### 3. 配置定时任务（可选修改）

编辑 `.github/workflows/r-analysis.yml`：

```yaml
# 默认：每个工作日 9:00 AM CST
cron: '0 1 * * 1-5'

# 自定义示例：
# 每天 8:00 AM CST: '0 0 * * *'
# 每周一 9:00 AM CST: '0 1 * * 1'
```

### 4. 首次运行

1. 进入GitHub仓库 Actions 标签页
2. 选择 "R Analysis Pipeline" 工作流
3. 点击 "Run workflow" 手动触发
4. 等待执行完成（约5-10分钟）

## 主要改动说明

### R代码重构

| 原代码 | 云端版本 | 说明 |
|-------|---------|------|
| `setwd("C:/Users/...")` | `Sys.getenv("WORK_DIR", getwd())` | 使用环境变量 |
| `pacman::p_load(...)` | `install_if_missing()` | 内置包管理 |
| `./output/` | `file.path(OUTPUT_DIR, ...)` | 相对路径 |
| 无日志 | `log_message()` | 结构化日志 |
| 原始图表 | 简化版图表 | 减少资源占用 |

### 依赖管理

- **本地**: 使用 `pacman` 动态安装包
- **云端**: 使用 `renv.lock` 锁定版本，支持缓存

### 输出同步

- **本地**: 直接保存到本地目录
- **云端**: 自动同步到坚果云WebDAV

## 监控与调试

### 查看执行日志

1. 进入 Actions 标签页
2. 点击最新的工作流运行
3. 查看每个步骤的日志输出

### 下载输出文件

每次运行后会自动上传Artifact：
- 在 Actions 运行页面找到 "Artifacts"
- 下载 `analysis-output-{run_id}` 压缩包

### 坚果云验证

登录坚果云网页版，检查目录：
```
/R-Analysis-Output/
├── 2024-03-08/
│   ├── data.xlsx
│   ├── AnalysisReport_formal.xlsx
│   ├── dataAnalysis/
│   │   ├── BTCUSD_DataAnalysis.xlsx
│   │   └── ...
│   └── charts/
│       ├── 2024-03-08_BTCUSD.html
│       └── ...
```

## 故障排除

### 问题1: R包安装失败

**现象**: Actions卡在"Run R Analysis"步骤

**解决**: 
1. 检查系统依赖是否完整
2. 在 `r-analysis.yml` 中添加缺失的库

### 问题2: Yahoo Finance数据下载失败

**现象**: 报错 "ERROR: yahoo code doesn't exist"

**解决**:
1. 检查股票代码是否正确
2. Yahoo Finance偶尔限制IP，重试即可

### 问题3: 坚果云同步失败

**现象**: "Failed to connect to WebDAV"

**解决**:
1. 确认Secrets配置正确
2. 检查坚果云WebDAV服务状态
3. 尝试使用应用密码而非登录密码

### 问题4: 内存不足

**现象**: "Process completed with exit code 137"

**解决**:
1. 减少分析的股票数量
2. 缩短历史数据范围（修改 `dataHistory`）
3. 使用GitHub Actions的更大运行器（付费功能）

## 高级配置

### 修改股票列表

编辑 `input/tickers_macro.xlsx`，格式：
| name | ticker |
|------|--------|
| BTCUSD | BTC-USD |
| ETHUSD | ETH-USD |
| ... | ... |

### 修改分析参数

编辑 `MarketAnalytics_cloud.R` 开头部分：

```r
dataHistory <- 10        # 历史数据年数
maParameters <- c(5, 21, 89, 144)  # 均线周期
portfolioVol <- "ATR"    # 波动率计算方式
```

### 添加邮件通知

在 `.github/workflows/r-analysis.yml` 末尾添加：

```yaml
- name: Send Email Notification
  if: always()
  uses: dawidd6/action-send-mail@v3
  with:
    server_address: smtp.gmail.com
    server_port: 587
    username: ${{ secrets.EMAIL_USER }}
    password: ${{ secrets.EMAIL_PASS }}
    subject: R Analysis ${{ job.status }}
    to: your-email@example.com
    from: github-actions@example.com
    body: Analysis completed with status ${{ job.status }}
```

## 成本估算

GitHub Actions免费额度（公开仓库）：
- 每月 2,000 分钟
- 单次运行约 5-10 分钟
- **每月可运行 200-400 次**

## 安全建议

1. **永远不要提交敏感信息到仓库**
   - 使用GitHub Secrets存储密码
   - `.gitignore` 已配置忽略敏感文件

2. **定期轮换密码**
   - 每3个月更新坚果云应用密码
   - 同步更新GitHub Secrets

3. **限制Action权限**
   - 仓库 Settings -> Actions -> General
   - 选择 "Read repository contents permission"

## 联系支持

如有问题，请：
1. 检查Actions日志获取详细错误信息
2. 确认所有Secrets配置正确
3. 参考GitHub Actions和坚果云官方文档
