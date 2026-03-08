# Cloud-Ready R Analysis Pipeline

## 项目概述
将本地R分析任务迁移到云端执行，使用GitHub Actions + 坚果云WebDAV

## 架构设计

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  GitHub     │────▶│  GitHub     │────▶│  坚果云      │
│  Repository │     │  Actions    │     │  WebDAV     │
└─────────────┘     └─────────────┘     └─────────────┘
                           │
                           ▼
                    ┌─────────────┐
                    │  Yahoo      │
                    │  Finance    │
                    └─────────────┘
```

## 目录结构

```
.
├── .github/
│   └── workflows/
│       └── r-analysis.yml      # GitHub Actions工作流
├── input/
│   ├── tickers_macro.xlsx      # 股票代码输入
│   └── template_AnalysisReport.xlsx  # 报告模板
├── output/                      # 输出目录（GitHub临时存储）
│   ├── data.xlsx               # 下载的原始数据
│   ├── dataAnalysis/           # 分析结果
│   ├── charting/               # 图表输出
│   └── *_AnalysisReport.*      # 最终报告
├── renv/                       # R依赖管理
├── scripts/
│   └── nutstore_sync.py        # 坚果云同步脚本
├── MarketAnalytics_cloud.R     # 云端版R脚本
├── renv.lock                   # R包版本锁定
└── README.md
```

## 环境变量配置

在GitHub Repository Settings中设置以下Secrets:

| Secret Name | Description |
|------------|-------------|
| `NUTSTORE_USER` | 坚果云用户名 |
| `NUTSTORE_PASSWORD` | 坚果云密码 |
| `NUTSTORE_WEBDAV_URL` | WebDAV地址 (如: https://dav.jianguoyun.com/dav/) |
| `NUTSTORE_REMOTE_PATH` | 远程存储路径 (如: /R-Analysis-Output/) |

## 执行流程

1. **触发条件**: 
   - 定时触发 (cron): 每个工作日 9:00 CST
   - 手动触发 (workflow_dispatch)
   - Push到main分支

2. **执行步骤**:
   - 检出代码
   - 设置R环境
   - 安装依赖 (renv)
   - 执行分析脚本
   - 同步结果到坚果云

## 迁移说明

### 主要改动

1. **路径处理**: 使用相对路径 + 环境变量
2. **依赖管理**: 使用renv替代pacman
3. **输出同步**: 增加坚果云WebDAV同步
4. **错误处理**: 增加tryCatch和日志记录

### 本地测试

```bash
# 安装依赖
R -e "renv::restore()"

# 运行分析
Rscript MarketAnalytics_cloud.R
```

## 许可证
MIT
