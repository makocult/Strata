# Strata

本地优先的层级结构思维导图工具，面向跨分支的同级节点审查与比较。

## 第一版范围

- 原生 SwiftUI macOS 应用
- 本地 JSON 自动保存：`~/Library/Application Support/Strata/map.json`
- 节点树：根节点、子节点、同级节点、删除
- 结构地图视图
- 层级审查视图：按深度列出同级节点，并保留祖先路径
- macOS 14+

## 开发

```sh
swift build
swift test
swift run Strata
```

## 当前限制

这是第一版核心切片，不包含全局快捷键、自由画布布局、拖拽重排、撤销/重做和 `.mm` 导出。下一步优先验证层级审查视图是否符合实际工作方式，再决定布局和入口设计。
