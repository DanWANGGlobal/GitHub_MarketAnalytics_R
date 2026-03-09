# Google Drive 同步设置指南

## 概述

作为坚果云同步的替代方案，现已支持将分析结果自动上传到Google Drive。

## 设置步骤

### 1. 创建Google Cloud项目

1. 访问 [Google Cloud Console](https://console.cloud.google.com/)
2. 创建新项目或选择现有项目
3. 启用 Google Drive API：
   - 左侧菜单 → APIs & Services → Library
   - 搜索 "Google Drive API"
   - 点击 "Enable"

### 2. 创建Service Account

1. 左侧菜单 → APIs & Services → Credentials
2. 点击 "Create Credentials" → "Service Account"
3. 填写Service Account名称（如：r-analysis-uploader）
4. 角色选择：Project → Editor（或更严格的Drive权限）
5. 点击 "Done"

### 3. 创建并下载密钥

1. 在Service Accounts列表中，点击刚创建的账号
2. 进入 "Keys" 标签页
3. 点击 "Add Key" → "Create new key"
4. 选择 "JSON" 格式，点击 "Create"
5. 密钥文件会自动下载（如：`r-analysis-uploader-xxx.json`）

### 4. 编码密钥

在终端中运行：

```bash
# macOS/Linux
cat r-analysis-uploader-xxx.json | base64 | pbcopy  # macOS
cat r-analysis-uploader-xxx.json | base64 -w 0      # Linux

# Windows (PowerShell)
[Convert]::ToBase64String([IO.File]::ReadAllBytes("r-analysis-uploader-xxx.json")) | Set-Clipboard
```

或者直接输出到文件：
```bash
cat r-analysis-uploader-xxx.json | base64 -w 0 > credentials.b64.txt
```

### 5. 添加到GitHub Secrets

1. 打开GitHub仓库 → Settings → Secrets and variables → Actions
2. 点击 "New repository secret"
3. 添加以下Secrets：
   - **Name**: `GOOGLE_CREDENTIALS_B64`
   - **Value**: 上一步复制的base64编码内容

4. （可选）添加文件夹名称：
   - **Name**: `GDRIVE_FOLDER_NAME`
   - **Value**: `R-Analysis-Output`（或你想要的文件夹名）

### 6. 共享Drive文件夹（可选）

如果你想让其他人访问上传的文件：

1. 第一次运行workflow后，在Google Drive中找到创建的文件夹
2. 右键文件夹 → "Share"
3. 添加需要访问的邮箱地址，设置权限（Viewer/Editor）
4. 或者获取分享链接，设置为"Anyone with the link can view"

## 验证

推送代码到GitHub后，查看Actions运行日志：
- 如果看到 "Successfully connected to Google Drive" → 配置成功
- 如果看到 "GOOGLE_CREDENTIALS_B64 not set" → Secrets未配置

## 故障排除

### 问题："Google Drive API has not been used in project..."

**解决**：访问控制台中的Google Drive API页面，点击 "Enable"

### 问题："Insufficient Permission"

**解决**：确保Service Account有足够的权限，或手动共享目标文件夹给Service Account邮箱

### 问题：上传失败但无错误

**解决**：检查Google Drive存储空间是否已满

## 安全提示

1. **永远不要**将JSON密钥文件提交到Git仓库
2. **永远不要**在公开场合分享base64编码的凭证
3. 定期轮换Service Account密钥（建议每90天）
4. 给Service Account最小必要的权限（只用Drive API，不用整个项目Editor）

## 与坚果云对比

| 特性 | 坚果云 | Google Drive |
|------|--------|--------------|
| 国内访问 | ✅ 快 | ⚠️ 需梯子 |
| 免费额度 | 1GB/月上传 | 15GB总空间 |
| 分享便捷 | 链接分享 | 链接分享 |
| API稳定性 | 偶有409错误 | 稳定 |
| 配置复杂度 | 简单 | 较复杂 |

建议：国内使用优先坚果云，国际分享用Google Drive。
