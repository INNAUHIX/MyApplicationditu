# Implementation Plan: 地图轨迹应用架构重构

**Input**: Feature specification from `spec/arch-refactor/spec.md`

## Summary

将地图轨迹应用的巨石架构（Index.ets 1210行、Mine.ets 1223行）按职责拆分为 MVVM 模式的模块化架构。核心改造：Index 从上帝对象变为轻量编排层（≤300行），3 个 Tab 页拆为独立 @Component；Mine 瘦身至 ≤200行，面板拆为子组件；统一 Haversine 实现、修复里程计算不一致与 DB 字段丢失、偏好统一管理、ViewModel 去除 UI 调用、MapStyle JSON 外置。

## Technical Context

**Language/Version**: ArkTS (HarmonyOS SDK 6.1.1(24), 兼容 6.1.0(23))  
**Primary Dependencies**: @kit.MapKit, @kit.LocationKit, @kit.ArkData, @kit.AbilityKit, @kit.UIDesignKit (HdsNavigation/HdsTabs), @kit.ArkUI  
**Storage**: ArkData RdbStore (footprint.db), Preferences (app_prefs)  
**Testing**: 设备实机/模拟器运行验证（ArkTS 无标准单测框架）  
**Target Platform**: HarmonyOS Phone  
**Project Type**: 移动应用（地图轨迹记录）  
**Performance Goals**: 地图 60fps，轨迹记录无丢点，统计页秒开  
**Constraints**: 后台持续定位 + 长任务保活；地图沉浸全屏；V1 @Component 装饰器体系（非 V2）  
**Scale/Scope**: 单模块 entry，3 个 Tab 页，~12 个 .ets 文件 → ~18 个 .ets 文件

## Project Structure

### Documentation (this feature)

```text
spec/arch-refactor/
├── spec.md              # 需求规范
├── plan.md              # 本文件（架构方案）
└── tasks.md             # 任务分解
```

### Source Code (repository root)

```text
entry/src/main/ets/
├── entryability/
│   └── EntryAbility.ets           # 不变：入口 Ability + 后台长任务
├── entrybackupability/
│   └── EntryBackupAbility.ets     # 不变：备份扩展
├── pages/
│   ├── Index.ets                  # [重构] 编排层：持有服务、生命周期、HdsTabs 编排（≤300行）
│   ├── FootprintTab.ets           # [新增] 足迹地图 Tab 组件（地图+覆盖物+实时连线+时间切换+工具面板）
│   ├── StatsTab.ets               # [新增] 统计 Tab 组件（统计页 List + 7天分布）
│   └── Mine.ets                   # [重构] 我的 Tab 组件（瘦身≤200行，面板拆为子组件）
├── components/
│   ├── RecordModePanel.ets        # [新增] 定位模式面板 @Builder 子组件
│   ├── LocationPermPanel.ets      # [新增] 定位权限面板 @Builder 子组件
│   ├── SettingPanel.ets           # [新增] 设置面板 @Builder 子组件（含隐私二级视图）
│   ├── StrategyLabPanel.ets       # [新增] 策略实验室面板 @Builder 子组件
│   └── CardItem.ets               # [新增] 通用列表项组件（从 Mine 内部提取）
├── viewmodel/
│   ├── TimeViewModel.ets          # [重构] 移除 UI 调用，仅数据/状态/偏好
│   └── MapStyleViewModel.ets      # [新增] 地图样式偏好管理（从 Index 的 saveMapStyle/loadMapStyle 迁入）
├── model/
│   └── TrackTypes.ets             # [微调] 移除 TAG 常量（改由各模块自行定义）
├── service/
│   ├── TrackLocationService.ets   # [重构] 从 location/ 迁入 service/，统一调用 TrackUtils.calculateDistance
│   ├── PermissionService.ets      # [重构] 从 location/ 迁入 service/，接口不变
│   └── MapOverlayManager.ets      # [重构] 从 map/ 迁入 service/，统一调用 TrackUtils.calculateDistance
├── data/
│   └── TrackDatabase.ets          # [重构] queryByRange 补全 accuracy/speed，flushBatch 失败保缓冲
├── common/
│   └── TrackUtils.ets             # [重构] 从 util/ 迁入 common/，唯一 Haversine 实现 + 里程计算统一
└── (旧目录 location/ map/ util/ 删除，内容已迁移)

entry/src/main/resources/
├── rawfile/
│   └── map_style_test.json        # [新增] 外置的地图测试样式 JSON（从 MapStyleTest.ets 迁出）
└── (其他资源不变)
```

**Structure Decision**: 本项目为现有 HarmonyOS/ArkTS 项目，当前架构已有 data/model/service 分层雏形但未严格执行。本次重构按 MVVM 模式重新组织目录：新增 `viewmodel/` 承载 UI 状态编排，新增 `service/` 统一业务服务（原散落在 location/ map/），新增 `components/` 承载可复用 UI 子组件，`common/` 承载纯函数工具。这是对现有架构的 MVVM 优化迁移，计划 18 个 .ets 文件（原 12 个 + 新增 6 个），属于必要拆分——原 Index/Mine 各超 1000 行，拆分是维护性刚需。

## Research & Decisions

### Decision 1: 组件通信模式 — V1 @Link + 回调

**Decision**: 拆分出的 Tab 组件与 Index 之间使用 V1 @Link（双向同步状态）+ 回调函数（单向事件通知）通信。面板子组件与 Mine 之间同理。

**Rationale**: 项目已全面使用 V1 @Component/@State/@Link 体系，V2 @ComponentV2/@Local/@Param 尚不成熟且迁移代价大。V1 @Link 是当前最稳定的跨组件双向绑定方式。

**Alternatives considered**:
- V2 @ComponentV2 + @Param + @Event：更现代但迁移成本高，V2 装饰器与现有 HdsTabs/HdsNavigation 等系统组件的兼容性未经充分验证
- AppStorage/LocalStorage：全局状态存储，但 Tab 组件状态多为页面级而非应用级，全局化会增加不必要的刷新

### Decision 2: Haversine 统一与里程计算修正

**Decision**: 统一使用 TrackUtils.calculateDistance()（完整 Haversine 公式）作为唯一距离计算实现。TimeViewModel.applyTimeView() 和 TrackUtils.computeStats() 中的简化公式替换为调用 calculateDistance()。

**Rationale**: 简化公式 `√(Δlat² + Δlon²) × 6371000 × π/180` 在高纬度地区误差显著（经度方向 1° 对应的实际距离随纬度增大而减小），且与防漂移使用的 Haversine 不一致，导致统计里程与实时里程对不上。统一 Haversine 后计算结果一致，且性能差异在当前数据规模下可忽略。

**Alternatives considered**:
- 保持简化公式：性能微优但数据不一致，用户体验差
- 两处都改用 Haversine 但保留各自实现：维护负担，仍有不一致风险

### Decision 3: ViewModel 不直接调用 UI — DatePickerDialog 事件化

**Decision**: TimeViewModel 的 onTimeViewSelected() 在切换到自定义视图时不直接弹出 DatePickerDialog，而是通过回调通知页面层，由页面层弹出日期选择对话框并将结果回传给 ViewModel。

**Rationale**: ViewModel 应只管理数据和状态，不依赖 UI 上下文。这使 ViewModel 可被非 UI 场景复用（如后台任务），也便于单元测试。

**Alternatives considered**:
- 保持现状：ViewModel 耦合 UI，无法独立测试
- 将日期选择完全移入页面：ViewModel 仅提供 setCustomRange(start, end) 接口，页面自行管理日期选择流程——此为最终方案

### Decision 4: DB flushBatch 失败策略 — 保留缓冲

**Decision**: flushBatch() 写入失败时不清空 pendingPoints 缓冲，保留数据等下次定时触发重试。增加错误计数器，连续失败超过阈值（5次）时打日志告警但不丢弃数据。

**Rationale**: 轨迹数据是用户核心资产，丢失不可恢复。保留缓冲虽可能短暂增加内存占用，但缓冲大小受限于采样频率（最大约 1点/5秒 × 15点/批 × 8秒/定时 = 低增长率），不会无限增长。

**Alternatives considered**:
- 失败即清空（当前实现）：数据丢失，不可接受
- 有限次数重试：增加复杂度，且定时器本身已是重试机制

### Decision 5: MapStyle JSON 外置方案 — rawfile + 同步读取

**Decision**: 将 MapStyleTest.ets 中的 JSON 字符串移至 `entry/src/main/resources/rawfile/map_style_test.json`，在 MapOverlayManager.applyMapStyle() 中通过 `getContext().resourceManager.getRawFileContentSync()` 同步读取并转为字符串。

**Rationale**: getRawFileContentSync 为同步 API，不会阻塞地图初始化时序；rawfile 资源不参与编译期 .ets 文件解析，减小编译负担；596 行 JSON 从 .ets 中移出显著降低源文件体积。

**Alternatives considered**:
- 异步读取 getRawFileContent：需处理异步时序，地图初始化阶段可能尚未加载完毕
- 保持内联：编译体积大、.ets 文件臃肿

### Decision 6: 服务目录迁移 — location/ + map/ + util/ → service/ + common/

**Decision**: 将 `location/TrackLocationService.ets` 和 `location/PermissionService.ets` 迁入 `service/`，将 `map/MapOverlayManager.ets` 迁入 `service/`，将 `util/TrackUtils.ets` 迁入 `common/`。删除旧目录 location/、map/、util/。

**Rationale**: 现有 location/ 和 map/ 目录各只有 1-2 个文件，且它们本质是业务服务而非 UI 页面或数据模型。统一收入 service/ 更符合 MVVM 职责划分。TrackUtils 是纯函数工具集，归入 common/ 语义更清晰。

**Alternatives considered**:
- 保持原有目录结构：目录过碎（2文件/目录），职责语义不清
- 全部迁入 viewmodel/：这些是服务/工具而非 UI 状态编排

### Decision 7: Mine 占位代码处理 — 全部移除

**Decision**: 移除 Mine 中的全部占位/未实现功能项：字体大小、页面跳转、Web页面、关于我们、检测版本、我的订单、意见反馈、退出登录、自定义开关(customSwitchOn)、自定义下拉(customSelectIndex/customSelectOptions)。同时移除 Index 中对应的 @State 变量（customSwitchOn、customSelectIndex）。

**Rationale**: 占位代码增加维护负担、误导开发者、扩大组件接口（Mine 与 Index 之间多了不必要的 @Link）。移除后 Mine 接口精简、职责清晰。

**Alternatives considered**:
- 保留占位框架：无实际价值，徒增复杂度
- 标记 TODO 但保留：仍需维护接口，且未来实现时可能完全不同

## Data Model

### 现有实体（不变）

- **TrackPointRecord**: 轨迹点记录 { latitude, longitude, timestamp, accuracy, speed } — 数据库表 track_points
- **StatDayItem**: 统计日聚合 { label, distance, count }
- **StatResult**: 全量统计指标 { totalDistance, trackCount, activeDays, avgDailyDist, maxDailyDist, firstTs, lastTs, recent7 }
- **RecordMode**: 定位模式枚举 { POWER_SAVING=0, BALANCED=1, HIGH_POWER=2 }
- **RecordModeConfig**: 模式参数 { timeInterval, distanceInterval, maxAccuracy, label }
- **PermissionState**: 权限状态快照 { hasApproximatelyLocation, hasLocation, hasBackgroundLocation }
- **VisibleData**: 可见集数据 { trackPoints, footprintPoints, totalDistance, lastFootprintPoint }
- **VisibleRange**: 可见时间范围 { start, end }

### 新增实体

- **MapStyleViewModel**: 地图样式偏好管理
  - 属性：mapStyleIndex (number), context (UIAbilityContext)
  - 方法：saveMapStyle(index), loadMapStyle(): number
  - 偏好键：PREF_KEY_MAP_STYLE (复用 TrackTypes 现有常量)

### 数据流

```
定位采样 → TrackLocationService.onSample → FootprintTab.onLocationSample
  → recordTrackPoint → TimeModel.addPoint + DB.enqueue
  → 可见集更新 → MapOverlayManager.refreshOverlayOptimized

时间视图切换 → FootprintTab.onTimeViewSelected → TimeModel.onTimeViewSelected(回调)
  → 页面弹出DatePicker → 结果回传TimeModel → refreshVisibleView → rebuildOverlay

地图样式切换 → FootprintTab.switchMapStyle → MapStyleViewModel.saveMapStyle
  → MapOverlayManager.applyMapStyle

统计页 → StatsTab.aboutToAppear → computeStats → 渲染
```

## Contracts & Interfaces

### Index 编排层接口

Index 对外暴露给 Tab 组件的服务实例与状态：

| 属性/方法 | 类型 | 说明 |
|---|---|---|
| db | TrackDatabase | 数据库服务 |
| permSvc | PermissionService | 权限服务 |
| locationSvc | TrackLocationService | 定位服务 |
| mapManager | MapOverlayManager | 地图覆盖物管理 |
| timeModel | TimeViewModel | 时间视图状态 |
| mapStyleVM | MapStyleViewModel | 地图样式偏好 |
| statusBarHeight | number | 状态栏高度 |
| navBarHeight | number | 导航条高度 |

### FootprintTab 组件接口

| 属性 | 装饰器 | 类型 | 说明 |
|---|---|---|---|
| db | 普通 prop | TrackDatabase | 数据库实例 |
| permSvc | 普通 prop | PermissionService | 权限服务 |
| locationSvc | 普通 prop | TrackLocationService | 定位服务 |
| mapManager | 普通 prop | MapOverlayManager | 地图管理器 |
| timeModel | 普通 prop | TimeViewModel | 时间视图 |
| mapStyleVM | 普通 prop | MapStyleViewModel | 地图样式偏好 |
| statusBarHeight | @Prop | number | 状态栏高度 |
| navBarHeight | @Prop | number | 导航条高度 |
| currentMode | @Link | RecordMode | 定位模式（双向同步 Mine） |
| isStationary | @Link | boolean | 驻留状态（双向同步 Mine） |
| immersive | @State | boolean | 沉浸模式（Footprint 内部状态） |

### StatsTab 组件接口

| 属性 | 装饰器 | 类型 | 说明 |
|---|---|---|---|
| timeModel | 普通 prop | TimeViewModel | 时间视图（用于 computeStats） |
| navBarHeight | @Prop | number | 导航条高度 |
| statusBarHeight | @Prop | number | 状态栏高度 |
| trackCount | @Link | number | 当前可见轨迹点数 |
| totalDistance | @Link | number | 当前可见里程 |
| isStationary | @Link | boolean | 驻留状态 |
| timeViewIndex | @Link | number | 时间视图索引 |

### MineTab 组件接口（精简后）

| 属性 | 装饰器 | 类型 | 说明 |
|---|---|---|---|
| permSvc | 普通 prop | PermissionService | 权限服务 |
| locationSvc | 普通 prop | TrackLocationService | 定位服务 |
| navBarHeight | @Prop | number | 导航条高度 |
| statusBarHeight | @Prop | number | 状态栏高度 |
| recordMode | @Link | RecordMode | 定位模式 |
| hasApproximatelyLocation | @Link | boolean | 大致位置授权 |
| hasLocation | @Link | boolean | 精确位置授权 |
| hasBackgroundLocation | @Link | boolean | 后台定位授权 |
| nightModeIndex | @Link | number | 日夜模式 |
| shakeFloorIndex | @Link | number | 抖动地板档位 |
| trackCount | @Link | number | 轨迹点数 |
| onClearTrack | 回调 | () => void | 删除轨迹 |
| onRefreshPermission | 回调 | () => void | 刷新权限 |
| onNightModeChange | 回调 | (index: number) => void | 日夜模式切换 |

对比原 Mine 接口：移除了 pushSwitchOn、customSwitchOn、customSelectIndex 三个 @Link（占位项），onRequestPermissions/onOpenPermissionSettings/onRequestBackgroundPermission 三个回调合并为 onRefreshPermission（面板内部直接调 permSvc），接口从 9@Link+7回调 精简为 7@Link+3回调。

### TimeViewModel 变更

| 原方法 | 变更 | 说明 |
|---|---|---|
| onTimeViewSelected(index, onComplete) | 移除 onComplete，改为返回 boolean | 不再直接弹 DatePickerDialog，返回 true 表示需要弹日期选择 |
| openCustomDatePicker(onComplete) | 删除 | 日期选择由页面层负责 |
| + setCustomRange(start, end) | 新增 | 页面层弹完 DatePicker 后调用此方法设置范围 |

### MapStyleViewModel 新增

| 方法 | 签名 | 说明 |
|---|---|---|
| setContext | (ctx: UIAbilityContext) => void | 设置上下文 |
| saveMapStyle | (index: number) => void | 保存地图样式偏好 |
| loadMapStyle | () => number | 加载地图样式偏好，默认 0 |

### TrackDatabase 变更

| 原方法/行为 | 变更 | 说明 |
|---|---|---|
| queryByRange | 查询列补全为 [latitude, longitude, timestamp, accuracy, speed] | 修复 accuracy/speed 丢失 |
| flushBatch | 写入失败时不清空 pendingPoints | 保留缓冲待重试 |

### TrackLocationService 变更

| 原方法/行为 | 变更 | 说明 |
|---|---|---|
| calculateCentroidDistance | 删除，改调 TrackUtils.calculateDistance | 消除重复实现 |
| startLocation | 先调用 stopLocation 防重复注册 | 修复潜在泄漏 |

### MapOverlayManager 变更

| 依赖 | 变更 | 说明 |
|---|---|---|
| 导入 MapStyleTest | 改为从 rawfile 读取 JSON | MapStyleTest.ets 删除 |
| applyMapStyle(index=3) | getRawFileContentSync('map_style_test.json') | 同步读取 rawfile |
