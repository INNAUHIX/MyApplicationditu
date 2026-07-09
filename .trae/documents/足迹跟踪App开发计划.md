# 鸿蒙版足迹跟踪App开发计划

## 一、项目概述

### 1.1 项目背景
开发一款类似于"一生足迹"的鸿蒙版足迹跟踪App，用于记录用户的行走轨迹、统计里程数据、展示历史足迹。

### 1.2 技术栈
- **开发语言**: ArkTS
- **UI框架**: ArkUI
- **地图服务**: 华为Map Kit
- **定位服务**: 华为Location Kit
- **数据存储**: 鸿蒙关系型数据库 (RDB)
- **开发工具**: DevEco Studio

### 1.3 当前项目状态
- 项目已初始化，为标准鸿蒙应用结构
- 包名: `com.example.myapplicationditu`
- 仅包含默认Hello World页面

---

## 二、分阶段开发计划

### 第一阶段：地图基础显示（当前阶段）

**目标**: 集成华为Map Kit，成功显示地图

#### 2.1.1 需要修改/新增的文件

| 文件路径 | 操作 | 说明 |
|---------|------|------|
| `entry/src/main/module.json5` | 修改 | 添加地图权限、定位权限 |
| `entry/src/main/ets/pages/Index.ets` | 修改 | 替换为地图页面 |
| `entry/src/main/ets/pages/MapPage.ets` | 新增 | 地图主页面组件 |
| `entry/build-profile.json5` | 检查/修改 | 确认SDK版本支持 |

#### 2.1.2 具体实现步骤

1. **权限配置**
   - 在 `module.json5` 中添加定位权限 `ohos.permission.APPROXIMATELY_LOCATION`
   - 添加精确位置权限 `ohos.permission.LOCATION`
   - 添加网络权限（如需要）

2. **地图页面开发**
   - 导入Map Kit模块: `import { MapComponent, mapCommon, map } from '@kit.MapKit'`
   - 创建 `MapOptions` 配置，设置中心点和缩放级别
   - 使用 `MapComponent` 组件渲染地图
   - 获取 `MapComponentController` 控制器
   - 实现地图生命周期管理（show/hide）
   - 启用我的位置按钮 `myLocationControlsEnabled`
   - 启用比例尺 `scaleControlsEnabled`

3. **页面布局**
   - 地图占满全屏
   - 底部预留操作栏空间（为后续阶段做准备）

#### 2.1.3 验证标准
- 应用启动后正常显示华为地图
- 地图可以手势缩放、拖动
- 点击"我的位置"按钮可以定位（需要在真机上验证）
- 应用前后台切换地图正常显示

#### 2.1.4 注意事项
- 华为Map Kit需要在AppGallery Connect中配置API Key
- 地图功能建议在真机上测试，模拟器可能不支持
- 参考文档: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/map-presenting

---

### 第二阶段：定位与当前位置显示

**目标**: 实现实时定位，在地图上显示当前位置

#### 2.2.1 需要修改/新增的文件

| 文件路径 | 操作 | 说明 |
|---------|------|------|
| `entry/src/main/ets/utils/LocationManager.ets` | 新增 | 定位管理工具类 |
| `entry/src/main/ets/pages/MapPage.ets` | 修改 | 集成分位功能 |

#### 2.2.2 具体实现步骤

1. **定位权限申请**
   - 运行时动态申请定位权限
   - 处理权限授予/拒绝的不同情况

2. **LocationManager封装**
   - 集成 `@kit.LocationKit`
   - 实现单次定位获取当前位置
   - 实现连续位置更新监听
   - 封装位置回调接口

3. **地图与位置联动**
   - 获取当前位置后移动地图相机到当前位置
   - 在地图上显示当前位置Marker
   - 实现位置跟随模式

#### 2.2.3 验证标准
- 首次启动请求定位权限
- 授权后可获取当前经纬度
- 地图自动移动到当前位置
- 位置变化时地图Marker同步更新

---

### 第三阶段：轨迹记录功能

**目标**: 开始/停止轨迹记录，在地图上绘制实时轨迹线

#### 2.3.1 需要修改/新增的文件

| 文件路径 | 操作 | 说明 |
|---------|------|------|
| `entry/src/main/ets/model/TrackPoint.ets` | 新增 | 轨迹点数据模型 |
| `entry/src/main/ets/model/Track.ets` | 新增 | 轨迹数据模型 |
| `entry/src/main/ets/utils/TrackRecorder.ets` | 新增 | 轨迹记录器 |
| `entry/src/main/ets/pages/MapPage.ets` | 修改 | 添加记录控制UI和轨迹绘制 |

#### 2.3.2 具体实现步骤

1. **数据模型定义**
   - TrackPoint: 经纬度、时间、速度、海拔
   - Track: 轨迹ID、名称、开始时间、结束时间、总里程、轨迹点列表

2. **轨迹记录器**
   - 开始记录、暂停、继续、停止方法
   - 位置变化时自动采集轨迹点
   - 计算实时里程（使用Haversine公式计算两点距离）
   - 计算运动时间、平均速度等统计数据

3. **地图轨迹绘制**
   - 使用 `MapPolyline` 绘制轨迹线
   - 实时更新轨迹线路径
   - 设置轨迹线样式（颜色、宽度）

4. **记录控制UI**
   - 底部悬浮操作栏
   - 开始/停止记录按钮
   - 实时显示: 里程、时长、当前速度

#### 2.3.3 验证标准
- 点击开始按钮后开始记录轨迹
- 地图上实时绘制行走路线
- 里程和时间数据实时更新
- 停止记录后轨迹数据完整保存到内存

---

### 第四阶段：数据持久化与足迹列表

**目标**: 使用RDB数据库保存足迹数据，展示历史足迹列表

#### 2.4.1 需要修改/新增的文件

| 文件路径 | 操作 | 说明 |
|---------|------|------|
| `entry/src/main/ets/database/DatabaseHelper.ets` | 新增 | 数据库帮助类 |
| `entry/src/main/ets/database/TrackRepository.ets` | 新增 | 轨迹数据访问层 |
| `entry/src/main/ets/pages/TrackListPage.ets` | 新增 | 足迹列表页 |
| `entry/src/main/ets/pages/TrackDetailPage.ets` | 新增 | 足迹详情页 |
| `entry/src/main/resources/base/profile/main_pages.json` | 修改 | 添加页面路由 |
| `entry/src/main/ets/pages/MapPage.ets` | 修改 | 跳转到列表页入口 |

#### 2.4.2 具体实现步骤

1. **数据库设计**
   - tracks表: id, name, start_time, end_time, distance, duration, avg_speed, max_speed, cal_burned
   - track_points表: id, track_id, latitude, longitude, time, speed, altitude

2. **DatabaseHelper封装**
   - 使用 `@kit.ArkData` 的关系型数据库
   - 数据库创建、表结构初始化
   - 数据库版本管理

3. **TrackRepository数据访问**
   - 保存轨迹（包含所有轨迹点）
   - 查询所有轨迹列表（分页）
   - 根据ID查询轨迹详情（含所有轨迹点）
   - 删除轨迹

4. **足迹列表页**
   - 列表展示所有历史足迹
   - 每项显示: 名称、日期、里程、时长
   - 按时间倒序排列
   - 点击进入详情页
   - 下拉刷新、上拉加载更多

5. **页面路由**
   - 配置Tab导航（地图页 + 列表页）
   - 列表页跳转到详情页

#### 2.4.3 验证标准
- 记录的足迹可保存到数据库
- 重启App后历史足迹依然存在
- 足迹列表正确显示所有记录
- 点击列表项可查看详情

---

### 第五阶段：足迹详情与统计

**目标**: 展示单条足迹详情，包括轨迹回放和详细统计

#### 2.5.1 需要修改/新增的文件

| 文件路径 | 操作 | 说明 |
|---------|------|------|
| `entry/src/main/ets/pages/TrackDetailPage.ets` | 修改 | 完善详情页功能 |
| `entry/src/main/ets/components/TrackMapView.ets` | 新增 | 轨迹地图组件（可复用） |
| `entry/src/main/ets/components/StatCard.ets` | 新增 | 统计卡片组件 |

#### 2.5.2 具体实现步骤

1. **详情页布局**
   - 顶部: 地图显示完整轨迹
   - 中部: 统计数据卡片网格
     - 总里程
     - 运动时长
     - 平均速度
     - 最高速度
     - 累计爬升（如有海拔数据）
   - 底部: 轨迹信息（日期、开始/结束时间）

2. **轨迹回放**
   - 播放/暂停按钮
   - 进度条拖动
   - 轨迹动画逐步绘制
   - Marker沿轨迹移动

3. **轨迹编辑**
   - 修改轨迹名称
   - 删除轨迹

#### 2.5.3 验证标准
- 详情页完整展示轨迹和统计数据
- 轨迹回放动画流畅
- 修改和删除功能正常

---

### 第六阶段：统计总览与优化

**目标**: 添加总统计页面，优化用户体验

#### 2.6.1 需要修改/新增的文件

| 文件路径 | 操作 | 说明 |
|---------|------|------|
| `entry/src/main/ets/pages/StatsPage.ets` | 新增 | 统计总览页 |
| `entry/src/main/ets/components/WeeklyChart.ets` | 新增 | 周统计图表 |
| `entry/src/main/ets/database/TrackRepository.ets` | 修改 | 添加统计查询方法 |

#### 2.6.2 具体实现步骤

1. **底部Tab导航**
   - Tab1: 地图（记录）
   - Tab2: 足迹（历史列表）
   - Tab3: 统计（数据总览）

2. **统计总览页**
   - 总里程、总次数、总时长
   - 本周/本月统计
   - 日历热力图（显示哪些天有记录）
   - 周/月里程趋势图

3. **体验优化**
   - 记录中锁屏后继续记录
   - 低功耗定位策略
   - 离线地图支持（如需要）

---

## 三、关键技术点

### 3.1 地图相关
- `MapComponent` 地图组件
- `MapComponentController` 地图控制器
- `MapPolyline` 轨迹线绘制
- `MapMarker` 位置标记
- 地图生命周期管理（show/hide）

### 3.2 定位相关
- `@kit.LocationKit` 定位服务
- 单次定位与连续定位
- 定位权限动态申请
- 定位精度配置

### 3.3 数据库相关
- `@kit.ArkData` 关系型数据库 (RDB)
- SQL语句操作
- 数据库事务（批量插入轨迹点）
- 异步查询

### 3.4 距离计算
- Haversine公式计算两点间距离（考虑地球曲率）
- 累计里程计算

---

## 四、风险与应对

| 风险 | 影响 | 应对措施 |
|-----|------|---------|
| 华为Map Kit需要API Key配置 | 地图无法显示 | 提前在AppGallery Connect注册应用，获取API Key并配置 |
| 模拟器不支持地图/定位 | 无法调试 | 准备鸿蒙真机进行测试 |
| 后台定位限制 | 后台无法记录轨迹 | 申请后台定位权限，使用后台任务 |
| 耗电问题 | 用户体验差 | 优化定位频率，使用智能省电策略 |
| 数据库性能 | 大量轨迹点时卡顿 | 使用事务批量插入，分页查询 |

---

## 五、当前阶段（第一阶段）执行清单

- [ ] 1. 配置module.json5权限
- [ ] 2. 创建MapPage.ets地图页面
- [ ] 3. 集成MapComponent组件
- [ ] 4. 实现地图生命周期管理
- [ ] 5. 配置地图初始属性（我的位置、比例尺等）
- [ ] 6. 替换Index.ets入口页面
- [ ] 7. 编译验证，确认地图正常显示

---

## 六、参考文档

1. 华为Map Kit显示地图: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/map-presenting
2. 华为Map Kit API参考: https://developer.huawei.com/consumer/cn/doc/harmonyos-references/map-mapcomponent
3. 鸿蒙关系型数据库: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/relational-store-migration
4. 位置服务开发指南: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/location-service
