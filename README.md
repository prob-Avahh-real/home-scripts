# home-scripts

通用多运行时一键部署与字体子集化运维脚本集（已归档于 `archive/from-home/home-scripts`）。

## 核心脚本

- `deploy.sh`：通用一键部署脚本 v3.0，支持 `static`（Nginx 静态站点）、`node`、`python`、`go` 四种模式及 `.env.deploy` 配置、Swap 初始化与 `--dry-run` 预览
- `serve.sh`：本地轻量静态/开发服务启动辅助脚本
- `subset-tc-fonts.py` / `subset-tc-fonts.sh`：繁体中文字体按字符集裁剪与体积优化工具

## 目标平台（Target 判定）

- **移动端**：可选（服务器与构建侧运维脚本）
- **智能硬件**：可选（可搁置）

## 快速运行与验证

```bash
# 预览部署流程（不实际执行变更）
./deploy.sh --mode node --port 3000 --dry-run

# 运行归档冒烟测试
npm test
```

## 归档说明

家用机迁入归档工程，默认只读或按需小修。
