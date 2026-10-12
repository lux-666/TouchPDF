# 本地工作区

项目根目录是 Git 仓库，公开源码与本地构建、用户文档分开存放。

| 路径 | 内容 |
| --- | --- |
| `src/` | Swift 源码、触控板 C 桥接 |
| `resources/` | 应用配置与版本号 |
| `build.sh` / `package.sh` | 构建与打包入口 |
| `dist/` | 当前应用、ZIP 和校验文件，Git 忽略 |
| `docs/releases/` | 历史版本说明 |
| `outputs/` | 本地用户文档，Git 忽略 |
| `archive/` | 旧发布包、研究资料与整理前快照，Git 忽略 |
| `.build/` | 构建缓存，Git 忽略 |
| `release/TouchPDF/dist` | 指向根目录 `dist/` 的兼容链接 |

双击根目录的 `启动 TouchPDF 稳定版.command` 会从 `dist/TouchPDF.app` 启动新进程。窗口标题和“关于 TouchPDF / 当前版本…”显示编译版本；关于窗口还显示实际运行路径。

如果发现其他同标识进程，应用会列出路径，允许请求正常退出或取消启动。未保存文档仍显示系统保存提示，不会强制结束进程。“TouchPDF → 退出所有 TouchPDF”同样使用正常退出流程。

工作区整理前的源码有快照提交；旧空仓库元数据、搬移清单与 SHA-256 清单保存在 `archive/`。日常使用从固定入口启动即可，不需要进入归档目录。
