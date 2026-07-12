---
name: 全自动轨迹记录系统优化（类一生足迹）
overview: 对当前App进行全面优化，使其更像"一生足迹"/"灵敢足迹"类App——保持全自动后台记录不变，重点优化数据模型、全局展示效果（渐变足迹线/城市点亮/热度可视化）、百万级性能、低功耗、统计分析。
todos:
  - id: model-define
    content: 定义数据模型 TrackData.ets：TrackPoint/CityInfo/RecordMode 类型接口
    status: pending
  - id: database-layer
    content: 实现 TrackDatabase.ets：建表升级/批量写入/按时间范围查询/聚合统计/数据迁移
    status: pending
    dependencies:
      - model-define
  - id: recorder-layer
    content: 实现 TrackRecorder.ets：自动记录器状态管理/多档定位频率切换/批量写入调度
    status: pending
    dependencies:
      - model-define
  - id: stats-city-layer
    content: 实现 StatisticsCalculator.ets 和 CityDetector.ets：里程计算/天数统计/城市聚类识别与逆地理编码
    status: pending
    dependencies:
      - model-define
  - id: refactor-index
    content: 重构 Index.ets：接入 Service 层替换原轨迹逻辑，实现渐变折线渲染和城市点亮效果
    status: pending
    dependencies:
      - database-layer
      - recorder-layer
      - stats-city-layer
  - id: update-mine
    content: 改造 Mine.ets：顶部增加统计卡片(总里程/天数/城市数/点数)，替换无关健身菜单
    status: pending
    dependencies:
      - stats-city-layer
---

## 产品概述

将当前 App 升级为类似"一生足迹"/"灵敢足迹"的全自动足迹记录应用。核心特征是全程无感自动记录，无需用户任何操作，在后台静默运行。聚焦于全球足迹在地图上的优雅展示和统计数据呈现。

## 核心功能

1. **全自动足迹记录（保持现有）**：App 启动即自动开始记录，无需开始/暂停按钮。优化低功耗策略。
2. **全球足迹渐变渲染**：所有轨迹在地图上以渐变颜色展示——新轨迹亮色（红/橙），旧轨迹暗色（灰/蓝），形成"一生足迹"的视觉效果。
3. **城市点亮**：自动识别用户到过的城市，在地图上以城市标记高亮显示，显示城市名称。
4. **足迹统计总览**：总里程、累计天数、到访城市数、总点数等核心指标，在"我的"页面顶部以统计卡片展示。
5. **百万级数据性能**：缩放级别相关抽稀（低缩放时降采样）、分页加载、按时间范围加载非全量。
6. **低功耗策略**：多档定位模式（省电/标准/运动）、夜间自动降频、智能静止检测降频。
7. **足迹壁纸生成**：将当前地图+足迹渲染为图片，用于分享或设置壁纸。

## 技术方案

### 技术栈

- 框架：HarmonyOS NEXT (API 12+) / ArkTS
- 地图：@kit.MapKit
- 定位：@kit.LocationKit
- 数据库：@kit.ArkData (relationalStore)
- 后台：@kit.BackgroundTasksKit
- UI：ArkUI 声明式组件 + @kit.UIDesignKit
- 图片生成：@kit.ImageKit (用于壁纸截图)

### 实现思路

将 Index.ets 约 2137 行中的轨迹逻辑拆分为独立的 Service 层，保持页面专注于 UI 编排。整体分三步：

1. **Service 层建立**：数据模型 + 数据库 + 记录器 + 统计计算器，独立于 UI
2. **Index.ets 重构**：接入 Service 层，替换原轨迹逻辑，增加渐变折线渲染和城市识别
3. **Mine.ets 改造**：顶部添加统计卡片，替换无关的健身菜单项

### 关键设计决策

#### 1. 数据模型升级

数据库从 `(id, lat, lng)` 升级到含时间戳和精度的完整模型。通过 ALTER TABLE 兼容旧数据。

```sql
-- 轨迹点表（升级）
CREATE TABLE IF NOT EXISTS track_points (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  timestamp INTEGER NOT NULL DEFAULT 0,    -- Unix timestamp ms
  accuracy REAL DEFAULT 0,                  -- GPS精度(米)
  speed REAL DEFAULT 0                      -- 速度(m/s)
);
CREATE INDEX IF NOT EXISTS idx_timestamp ON track_points(timestamp);

-- 城市统计表（新增）
CREATE TABLE IF NOT EXISTS city_stats (
  city_id INTEGER PRIMARY KEY AUTOINCREMENT,
  city_name TEXT NOT NULL,
  country TEXT DEFAULT '',
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  first_visit INTEGER DEFAULT 0,
  last_visit INTEGER DEFAULT 0,
  visit_count INTEGER DEFAULT 1
);
```

#### 2. 渐变折线渲染（核心视觉）

不采用"按天分段"思路，而是**按时间渐变着色**：

- 最新的点：亮红/橙（0xFFFF4500）
- 中等旧的点：橙黄过渡（0xFFFFA500）
- 最旧的点：灰蓝（0xFF4A90D9）
- 通过 HSV 色相插值实现平滑渐变

实现方式：

- 依然用 MapPolyline，但分段添加多条折线，每段赋予不同颜色
- 缩放级别低时（<12），用 Douglas-Peucker 抽稀后分段渲染
- 缩放级别高时（>=14），展示全部精细折线

#### 3. 城市点亮与识别

- 基于定位点聚合：对轨迹点做空间聚类（DBSCAN 或网格化）
- 使用逆地理编码服务识别城市名（map.getAddressFromLocation）
- 缓存结果到 city_stats 表
- 海量点覆盖物 + 城市名称标注

#### 4. 低功耗策略（区分定位模式）

- **省电模式**（默认）：timeInterval=30s, distanceInterval=100m, 使用 UNCERTAIN 场景
- **标准模式**：timeInterval=10s, distanceInterval=50m, 使用 NAVIGATION 场景  
- **运动模式**（当前行为）：timeInterval=1s, distanceInterval=0, ACCURACY 优先级
- **夜间自动降频**：22:00-06:00 自动切换到省电模式，减少 GPS 漂移记录
- 在设置面板中提供模式切换

#### 5. 性能优化

- **启动时按时间分片加载**：只加载最近30天，其余按需
- **视图级别抽稀**：根据当前缩放级别动态简化折线
- **批量写入**：3秒或5个点一批次 flush，减少 DB 事务
- **生成统计时使用聚合查询**而非遍历内存
- **内存中 trackPoints 上限控制**：只保留最近 N 个点用于增量更新折线

### 目录结构

```
entry/src/main/ets/
├── model/
│   ├── TrackData.ets              # [NEW] TrackPoint/CityInfo/RecordMode 类型
├── services/
│   ├── TrackDatabase.ets          # [NEW] 数据库层+数据迁移+聚合查询
│   ├── TrackRecorder.ets          # [NEW] 自动记录器（定位管理+频率切换+批量写入）
│   ├── StatisticsCalculator.ets   # [NEW] 统计分析：里程/天数/城市
│   └── CityDetector.ets           # [NEW] 城市聚类识别+逆地理编码
└── pages/
    ├── Index.ets                  # [MODIFY] 重构：引用 Service，增加渐变折线/城市点亮
    └── Mine.ets                   # [MODIFY] 增加统计卡片，替换无关菜单
```

### 性能与功耗考量

- **内存**：启动时只加载最近30天点（约 10-50 万点），其余按需；单点约 32 字节，50 万点约 16MB
- **DB 写入**：批量写入可降低 DB 操作次数 20-60 倍
- **功耗**：NAVIGATION 场景+ACCURACY 优先级是高功耗主因；省电模式功耗可降低 10 倍
- **渲染**：MapPolyline 一次性 setPoints 大量点会卡顿，需缩放级别相关抽稀

### 兼容性

- 旧表 `track_points` 自动 ALTER TABLE ADD COLUMN timestamp/accuracy/speed，历史数据 timestamp 设为 0（标记为未知时间）
- 现有 Index.ets 的 UI 结构（地图工具面板、设置面板、沉浸模式、日/夜切换）不受影响
- Mine.ets 的底部列表保留，只替换顶部

### 扩展性

- Service 层接口设计清晰，未来可接入 iCloud/本地备份
- 城市检测可扩展为照片地理位置匹配
- 统计计算可扩展为周/月/年报告