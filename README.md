# TouchPDF

A lightweight macOS PDF reader and editor that turns your trackpad into a handwriting surface.

一个轻量的 macOS PDF 阅读与批注应用：触控板轻触定位、加力落笔，无需按下左键；手指位置绝对映射到独立书写框，抬手换位后可以自然地继续写公式。

## 下载

在 [Releases](https://github.com/lux-666/TouchPDF/releases) 下载 `TouchPDF-0.6.1-macos-arm64.zip`，解压后将 `TouchPDF.app` 放到“应用程序”目录。

当前版本支持 **Apple Silicon（M 系列）及 macOS 13 或更新版本**。轻压绘画需要兼容的触控板，力度信号会随设备、手指姿势而变化，可用滑块调整门槛；不支持该输入时自动回退到“轻触即写”。Intel 构建尚未验证。

下载包使用临时本地签名，尚无 Developer ID 签名和苹果公证，首次运行可能被 macOS 拦截。也可以按下面的步骤从源码构建。

## 使用

1. 启动时选择 PDF，或选择“新建空白画布”。
2. 打开“触控板批注”，蓝色虚线框就是触控板对应的书写区域；鼠标点击放置框，左键拖动移框。
3. 在“轻压绘画”模式下轻触预览笔尖，加力落笔；无需物理点击或按住 Command。默认开始门槛 30，减力收笔门槛为开始门槛的一半。这些数值是原始信号单位，不是克数。

| 操作 | 行为 |
| --- | --- |
| 单指轻触、加力 | 预览、落笔；抬手结束当前笔画 |
| 勾选“减力收笔” | 减力结束笔画并继续定位，再次加力开始新笔画 |
| 取消“减力收笔” | 加力起笔后持续书写，直到抬手 |
| 双指捏合 | 缩放 PDF |
| 三指移动 | 移动书写框 |
| 书写框大小 40–300% | 独立调整映射区域，受页面和当前视窗尺寸限制 |
| 鼠标滚轮 / 中键或右键拖动 | 滚动 / 平移 PDF |
| Command + 滚轮 | 缩放 PDF |
| Esc | 返回阅读模式 |

触摸期间固定系统箭头，包括外接鼠标；全部抬手或应用失焦后恢复。多指退回单指时，需要全部抬手再继续书写，避免误落笔。系统三指手势可能与应用手势冲突。

支持蓝、黑、红、绿、紫和自定义笔颜色；默认启用“笔迹平滑”，保留细小移动与公式尖角。笔迹保存为标准 PDF 矢量 Ink 批注，支持整笔橡皮、撤销/重做、保存和另存为。颜色、力度、减力收笔和平滑设置会记住；颜色和平滑只影响新笔画。

快捷键：`⌘O` 打开 PDF，`⌘N` 新建空白画布，`⌘S` 保存，`⇧⌘S` 另存为，`⌘Z` 撤销，`⇧⌘Z` 重做。

## 从源码构建

需要 Xcode Command Line Tools，没有第三方运行时依赖。

```sh
git clone https://github.com/lux-666/TouchPDF.git
cd TouchPDF
zsh build.sh
open dist/TouchPDF.app
```

打包发布文件：

```sh
zsh package.sh
```

产物位于 `dist/`，包含应用、ZIP 和 SHA-256 校验文件。构建缓存位于 `.build/`，这些文件都不会进入 Git。

## 验证

从“帮助 → 运行自检”检查输入状态机和 PDF 保存重开。结果写入 `~/Library/Application Support/TouchPDF/Checks/`，不改动当前文档。

检查覆盖减力/抬手收笔、门槛滞回、绝对坐标与断笔、多指和输入中断恢复、指针释放、细小移动采样、公式尖角、彩色平滑笔迹保存重开及擦除、书写框与 PDF 独立缩放、撤销/重做。实际轻压手感已在开发用 MacBook 上试用；自动检查不能替代不同硬件的手感验证。

## 实现

Swift、AppKit、PDFKit 和一个小型 C 桥接。轻触即写使用公开 `NSTouch.normalizedPosition`。轻压模式动态加载私有 `MultitouchSupport.framework`，读取手指位置和未公开标定的力度相关字段，以不同起笔/收笔门槛抑制临界抖动。

笔迹位置不依赖鼠标坐标，不模拟左键，不修改系统触感或手势设置。原始输入仅由前台文档处理，不记录其他应用的输入。输入中断或私有接口不可用时恢复指针并回退；私有接口对未来 macOS 的兼容性没有保证，也不适用于正常 Mac App Store 上架。

## 许可

[MIT](LICENSE)。触摸结构定义的来源和许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
