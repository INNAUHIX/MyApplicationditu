---
name: fix_resetCustomMapStyle_error
overview: 修复因误用不存在的 resetCustomMapStyle() 导致的编译错误(ArkTSCheck 1061),并让"经典"样式正确显示为内置暗色。
todos:
  - id: revert-classic-branch
    content: 还原经典分支：移除 resetCustomMapStyle 及其 try/catch，恢复 setCustomMapStyle({styleContent:'[]'})，并在 .then/.catch 置 mapStyled=true
    status: completed
  - id: add-mapstyled-gate
    content: 新增 @State mapStyled；aboutToAppear 置 false；applyMapStyleToMap 暗夜/浅白分支 .then/.catch 置 true
    status: completed
    dependencies:
      - revert-classic-branch
  - id: cover-ui
    content: build 中地图 Stack 加主题底色、MapComponent 按 mapStyled 控制 opacity，遮住未套样式的首帧
    status: completed
    dependencies:
      - revert-classic-branch
      - add-mapstyled-gate
  - id: verify-compile
    content: 在 DevEco 确认无 ArkTSCheck 报错（含 MapOptions.styleId 若不支持则回退）
    status: completed
    dependencies:
      - revert-classic-branch
      - add-mapstyled-gate
      - cover-ui
---

## 问题背景

- 当前代码已落地：顶层遮罩 + `mapLoad`/`styleReady` 双条件揭开机制（`mapRevealed`/`mapLoaded`/`styleReady`）；经典分支为 `setCustomMapStyle({styleContent:'[]'})`；`onPageShow/onPageHide` 已调 `show()/hide()`；`initMapOptions` 已预置 `styleId + dayNightMode`。
- 待修：退出重进 App 时仍"屏闪经典/先经典再过渡"。

## 官方文档查证结论（用户提供的两份官方正文）

1. **`MapOptions` 属性表确认支持 `styleId`（自定义样式ID）与 `dayNightMode`（日夜模式）** → `initMapOptions` 预置二者是官方支持的"初始化即带样式"，**保留，不删**（此前"删 styleId"的判断有误，已纠正）。
2. `setCustomMapStyle` 支持 `{styleId}` 与 `{styleContent}`，当前用法正确。
3. 官方**无独立预加载/预取瓦片 API**；前后台用 `onPageShow→show()` / `onPageHide→hide()` 管理资源（已实现）。遮罩 + 双条件揭开是框架内的极限手段。

## 闪光根因（修订）

- **(a) 遮罩底色 bug（必修）**：当前 `mapStyleIndex === 2 ? '#f2f3f5' : '#16181c'`，经典(index=0)与暗夜都用深底；但经典内置样式是亮色，揭开时"深底 → 亮色经典"闪一下。
- **(b) 云端 styleId 延迟（根因残留）**：`styleId` 为 Petal Maps Studio 云端样式，`setCustomMapStyle` 的 Promise resolve ≠ 云端样式已真正绘制，150ms 揭开时可能还没画上 → 仍可能微闪。彻底根治需改用本地 `styleContent` JSON（可选，见方案2）。

## 修复策略

### 方案1（本次执行，最小改动）

1. **保留** `initMapOptions` 的 `styleId + dayNightMode`（官方支持，不动）。
2. **修复遮罩底色**：仅暗夜(index=1)用深底 `#16181c`，经典(0)与浅白(2)用浅底 `#f2f3f5`。

- 第 1274 行 `backgroundColor`：`this.mapStyleIndex === 2 ? '#f2f3f5' : '#16181c'` → `this.mapStyleIndex === 1 ? '#16181c' : '#f2f3f5'`
- 第 1268 行 `LoadingProgress().color`：`this.mapStyleIndex === 2 ? '#666666' : '#9aa0a6'` → `this.mapStyleIndex === 1 ? '#9aa0a6' : '#666666'`

3. 保留遮罩双条件揭开 + 150ms 延时 + 3.5s `forceReveal` 兜底（均已实现）。

### 方案2（可选，彻底零闪，需用户配合）

- 从 Petal Maps Studio 导出暗夜/浅白两套样式的 JSON，内联为常量 `styleContent`，`applyMapStyleToMap` 改用 `setCustomMapStyle({styleContent})`（本地零网络延迟），揭开时样式几乎即时就位，消除 (b)。
- 依赖用户提供两份 JSON，暂不在本次执行。

## 关键改动

文件：`entry/src/main/ets/pages/Index.ets`（仅 build 中遮罩两行）

- 第 1268 行 `LoadingProgress().color(...)`：条件由 `=== 2` 改为 `=== 1`，颜色顺序对调。
- 第 1274 行 `.backgroundColor(...)`：条件由 `=== 2` 改为 `=== 1`，颜色顺序对调。
- `initMapOptions`、`applyMapStyleToMap`、遮罩揭开逻辑、`onPageShow/onPageHide` **均不改**。

## 架构设计

链路保持不变，仅修正遮罩底色随样式取色的判断，使经典/浅白用浅底、暗夜用深底，消除"深底→亮色经典"的揭开瞬闪。

## 目录结构

```
entry/src/main/ets/pages/Index.ets  # [MODIFY]
  # 仅改 build 遮罩两行：LoadingProgress 颜色(1268) 与 backgroundColor(1274) 的样式判断
```

## 验证

- DevEco 编译无报错。
- 真机：退出重进 App，经典样式不再出现"深底→亮色"闪；暗夜/浅白遮罩底色与目标样式一致。
- 若暗夜/浅白仍见"内置→自定义"微闪，说明是云端 styleId 延迟(b)，再评估方案2（本地 styleContent）。