# Feature Specification: 地图轨迹应用架构重构

**Created**: 2026-07-13  
**Status**: Draft  
**Input**: 项目架构排查发现 Index.ets(1210行) 和 Mine.ets(1223行) 巨石组件、职责越界、重复实现、数据不一致等 14 项问题

## Overview

对现有地图轨迹记录应用进行架构重构，将巨石组件 Index.ets（1210行）和 Mine.ets（1223行）按职责拆分为独立、可维护的模块，统一基础设施（距离计算、偏好存储、数据库查询），修复数据一致性与潜在 Bug，消除占位代码，使应用各模块可独立开发、测试和演进。

## User Scenarios & Testing *(mandatory)*

### User Story 1 - 拆分 Index 巨石组件为独立 Tab 组件 (Priority: P1)

将 Index.ets 从 1210 行的上帝对象拆分为编排层 + 3 个独立 Tab 组件（足迹地图 Tab / 统计 Tab / 我的 Tab）。Index 仅持有服务实例、生命周期管理与跨 Tab 编排逻辑；各 Tab 组件各自管理自己的 UI 状态与交互，通过回调和 @Link 与 Index 通信。

**Why this priority**: Index.ets 是所有问题的根源，拆分后才能为后续优化（Mine 瘦身、基础设施统一等）提供独立的修改空间，避免牵一发动全身。

**Independent Test**: 拆分后应用功能与拆分前完全一致（行为等价），3 个 Tab 页正常切换、地图正常显示、轨迹正常记录、统计正常展示、我的页面正常交互。

**Acceptance Scenarios**:

1. **Given** 应用启动, **When** 进入足迹 Tab, **Then** 地图正常显示，实时定位与轨迹记录功能与拆分前一致
2. **Given** 应用运行中, **When** 切换到统计 Tab, **Then** 统计数据正确展示，与拆分前一致
3. **Given** 应用运行中, **When** 切换到我的 Tab, **Then** 我的页面所有功能与拆分前一致
4. **Given** 拆分后的代码, **When** 检查 Index.ets 行数, **Then** 不超过 300 行（仅编排层）
5. **Given** 拆分后的代码, **When** 检查各 Tab 组件, **Then** 每个组件行数不超过 400 行

---

### User Story 2 - 瘦身 Mine 组件与拆分面板 (Priority: P2)

将 Mine.ets 中的 4 个半模态面板（定位模式/定位权限/设置/策略实验室）拆为独立 @Builder 子组件，移除所有占位/未实现功能（字体大小、页面跳转、Web页面、关于我们、检测版本、我的订单、意见反馈、退出登录、自定义开关/下拉等演示项），修复硬编码问题（隐私设置 Toggle isOn: true）。

**Why this priority**: Mine.ets 1223 行是第二大巨石，大量占位代码增加维护负担并误导开发者，拆分后 Mine 本体可控制在 200 行以内。

**Independent Test**: 我的 Tab 功能完整可用，定位模式/权限/设置/策略实验室面板正常弹出和交互，无任何空壳/占位项。

**Acceptance Scenarios**:

1. **Given** 我的 Tab, **When** 点击「定位模式」, **Then** 面板弹出且三档可切换、功能正常
2. **Given** 我的 Tab, **When** 点击「定位权限」, **Then** 面板弹出且三项权限状态正确、可跳转设置
3. **Given** 我的 Tab, **When** 点击「设置」, **Then** 面板弹出，仅包含已实现功能（夜间模式/通知开关/删除轨迹/隐私设置）
4. **Given** 我的 Tab, **When** 点击「策略实验室」, **Then** 面板弹出且各项策略正确展示、抖动地板可切换
5. **Given** 设置面板, **When** 进入隐私设置, **Then** Toggle 状态与实际值绑定（非硬编码 true）
6. **Given** 拆分后的 Mine.ets, **When** 检查行数, **Then** 不超过 200 行

---

### User Story 3 - 统一基础设施 (Priority: P2)

统一三处重复的 Haversine 距离计算为单一实现，修复 TimeViewModel/TrackUtils 中里程计算与 Haversine 不一致的问题（统一使用 Haversine），修复数据库查询丢弃 accuracy/speed 字段的 Bug，将地图样式偏好归入统一偏好管理。

**Why this priority**: 重复实现导致维护不一致，里程计算方式差异导致统计数据与实时数据对不上，数据库字段丢失属于数据 Bug。

**Independent Test**: 全部距离计算使用同一 Haversine 实现；统计里程与实时里程数值一致；数据库加载的历史记录包含完整 accuracy/speed；地图样式偏好由统一服务管理。

**Acceptance Scenarios**:

1. **Given** 代码库, **When** 搜索 Haversine 距离计算实现, **Then** 仅在 TrackUtils 中有一处实现，其余均调用它
2. **Given** 应用运行, **When** 查看统计页里程与地图页轨迹里程, **Then** 二者计算方式一致（同使用 Haversine）
3. **Given** 数据库中有含 accuracy/speed 的记录, **When** 应用重启加载历史, **Then** 加载的记录保留 accuracy/speed 原始值
4. **Given** 用户切换地图样式, **When** 重启应用, **Then** 地图样式保持上次选择

---

### User Story 4 - 修复 TimeViewModel 职责越界与潜在 Bug (Priority: P3)

将 TimeViewModel 中的 DatePickerDialog 调用移至页面层（ViewModel 只提供数据与状态，不直接操作 UI），修复定位服务可能重复注册的问题，修复数据库 flushBatch 失败后缓冲清空导致数据丢失的问题，优化初始化时序（地图 padding 在窗口信息获取后再设置）。

**Why this priority**: ViewModel 直接操作 UI 违反关注点分离，潜在 Bug 可能导致数据丢失或定位监听泄漏，但影响面较窄，可在基础设施统一后处理。

**Independent Test**: TimeViewModel 无任何 UI 调用；定位服务不会重复注册；数据库写入失败时缓冲保留；应用启动首帧地图 padding 正确。

**Acceptance Scenarios**:

1. **Given** TimeViewModel 代码, **When** 检查是否有 UI 相关导入/调用, **Then** 无任何 DatePickerDialog/AlertDialog 等调用
2. **Given** 定位服务已运行, **When** 重复调用 startLocation, **Then** 先注销旧监听再注册新监听，不会叠加
3. **Given** 数据库批量写入失败, **When** 检查缓冲, **Then** 缓冲中数据保留未丢失
4. **Given** 应用启动, **When** 地图初始化, **Then** 首帧 padding 基于已获取的窗口尺寸（非零值）

---

### User Story 5 - MapStyle JSON 外置与冗余 SegmentButton 清理 (Priority: P3)

将 MapStyleTest.ets 中 596 行的内联 JSON 样式字符串移至 rawfile 资源按需读取，清理 Index 中未使用的 trajectorySegmentOptions/demoSelectedIndex/selectedIndexes 冗余状态。

**Why this priority**: 包体积与编译优化，代码整洁。不影响核心功能，优先级最低。

**Independent Test**: 「测试」地图样式仍可正常应用；Index 无冗余未使用的 @State 变量。

**Acceptance Scenarios**:

1. **Given** 地图工具面板, **When** 切换到「测试」样式, **Then** 地图正确应用浅色极简风格
2. **Given** Index.ets 代码, **When** 检查 @State 变量, **Then** 无未被引用的冗余状态

---

### Edge Cases

- 拆分组件后 @Link/@Prop 传递链路变长，需确保状态同步时序不产生中间态闪烁
- 数据库查询补全 accuracy/speed 字段时，旧数据（字段值为 DEFAULT 0）应正确加载而非报错
- MapStyle JSON 外置为 rawfile 后，首次读取可能有 IO 延迟，需确保不阻塞地图初始化
- 批量落库失败时保留缓冲，需考虑重试策略避免缓冲无限增长

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Index.ets 必须拆分为编排层 + 3 个独立 Tab 组件（FootprintTab / StatsTab / MineTab），Index 行数不超过 300 行
- **FR-002**: 每个拆分出的 Tab 组件必须可独立维护，自身行数不超过 400 行
- **FR-003**: Mine 组件必须移除所有占位/未实现功能项，仅保留已实现的业务功能
- **FR-004**: Mine 中的 4 个半模态面板必须拆为独立 @Builder 子组件，Mine 本体不超过 200 行
- **FR-005**: Haversine 距离计算必须统一为 TrackUtils.calculateDistance() 单一实现，消除重复副本
- **FR-006**: TimeViewModel.applyTimeView() 与 TrackUtils.computeStats() 的里程计算必须统一使用 Haversine 公式
- **FR-007**: TrackDatabase.queryByRange() 必须查询并返回 accuracy/speed 字段的完整值，不再硬编码为 0
- **FR-008**: 地图样式偏好必须归入统一偏好管理服务（与时间视图偏好一致），Index 不再直接调用 preferences API
- **FR-009**: TimeViewModel 不得直接调用任何 UI 组件（DatePickerDialog 等），日期选择由页面层触发
- **FR-010**: TrackLocationService.startLocation() 必须先检查并注销已有监听，防止重复注册
- **FR-011**: TrackDatabase.flushBatch() 写入失败时缓冲不得清空，需保留未落库数据
- **FR-012**: 地图初始化 padding 必须在窗口尺寸获取完成后设置，避免首帧 padding 为 0
- **FR-013**: MapStyleTest 的 JSON 样式字符串必须外置到 rawfile 资源文件
- **FR-014**: Index 中未使用的 trajectorySegmentOptions/demoSelectedIndex/selectedIndexes 冗余状态必须清理
- **FR-015**: 重构后所有现有功能必须与重构前行为等价，无功能回退
- **FR-016**: Mine 设置面板隐私设置的 Toggle 必须与实际状态绑定，不得硬编码 isOn: true

### Key Entities

- **Tab 组件**: 独立的 @Component struct，承载单个 Tab 页的 UI 与交互逻辑，通过 @Link/回调与编排层通信
- **编排层(Index)**: 仅负责服务实例持有、生命周期管理、跨 Tab 状态协调的薄层
- **偏好服务(PreferenceService)**: 统一管理地图样式、时间视图等用户偏好，替代散落的直接 preferences 调用
- **距离计算**: 由 TrackUtils.calculateDistance() 提供的唯一 Haversine 实现，供所有模块调用

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Index.ets 行数从 1210 行降至 300 行以下（降幅 >75%）
- **SC-002**: Mine.ets 行数从 1223 行降至 200 行以下（降幅 >83%）
- **SC-003**: Haversine 距离计算实现数量从 3 处降至 1 处
- **SC-004**: 数据库加载的历史记录 accuracy/speed 字段值与写入时一致（非硬编码 0）
- **SC-005**: 统计页里程与地图页实时里程使用同一计算方式，数值差异 < 1%
- **SC-006**: 重构后全部现有功能行为等价，无功能回退
- **SC-007**: 占位/未实现代码项从约 9 个降至 0 个
- **SC-008**: 应用成功编译并在设备上运行

## Assumptions

- 重构范围为现有代码的架构改善，不增加新功能特性
- 拆分组件时优先保持行为等价，不改变用户可见的交互流程
- ArkTS @Component struct 的 @Link 传递深度可接受 2 层（Index → Tab → 面板子组件）
- rawfile 读取 MapStyle JSON 在应用沙箱内的 IO 性能可满足地图初始化时序要求
- 旧数据库记录中 accuracy/speed 的 DEFAULT 0 值可被视为合法历史数据加载

## Open Questions

- 批量落库失败时的重试策略：是无限重试、有限次数重试、还是仅保留缓冲等下次定时触发？（当前倾向：保留缓冲等下次定时触发，不增加重试复杂度）
