# 发布前验证

在项目根目录运行：

```sh
zsh build.sh /tmp/touchpdf-check
/tmp/touchpdf-check/TouchPDF.app/Contents/MacOS/TouchPDF --self-test /tmp/touchpdf-check.pdf
zsh package.sh
codesign --verify --deep --strict dist/TouchPDF.app
(cd dist && shasum -a 256 -c SHA256SUMS.txt)
```

界面回归必须使用副本和隔离的 bundle identifier，避免退出用户窗口或修改原 PDF。完成下面的实际文件打开检查后才算验证应用可用；仅验证空白画布和 PDF 数据解析不够。

1. 冷启动，启动选择框选择有效 PDF，点“打开”：显示对应文件的文档窗口，进程保持运行。
2. 从文档窗口按 ⌘O 再打开另一份 PDF：显示第二个文档，第一份保持打开。
3. 启动时打开无效 PDF：显示错误；关闭错误提示后能重新选择有效 PDF。
4. 启动时新建空白画布：窗口保留；关闭最后一个无修改文档后应用退出。
5. 启动时取消文件选择：应用退出。
6. 有未保存笔迹时 ⌘Q：保存提示正常；取消后可继续操作，保存后退出。
7. 同标识的另一副本启动：出现重复进程提示；请求正常退出后继续启动，不强杀进程。
8. B/E/Esc、单按 Shift、Shift 组合键和输入框状态：工具切换正确，输入文字不切换批注。

自检与界面自动化不能证明真实触控板的双指惯性、捏合、三指移动或轻压手感；这些需要硬件试用。
