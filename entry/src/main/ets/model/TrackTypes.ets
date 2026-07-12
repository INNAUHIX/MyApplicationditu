/**
 * TrackTypes.ets —— 轨迹模块的公共类型、枚举与常量
 *
 * 集中管理 Index 原先散落在文件顶部的接口、枚举与模块级常量，
 * 供 data / location / map / state / util 各层共享，避免重复定义。
 */

// 日志 TAG：组件名为 Index，早期原型曾叫 MapPage，此处统一为 Index 以消除歧义
export const TAG: string = 'Index';

// 定位模式面板「防漂移与性能策略」展示项结构
export interface RecordStrategyItem {
  title: string;
  desc: string;
}

// 时间视图的可见时间范围（含上/下界），用于从全量缓存过滤出可见轨迹点
export interface VisibleRange {
  start: number;
  end: number;
}

// ===== 定位记录模式（按功耗分级，Option B）=====
export enum RecordMode {
  POWER_SAVING = 0, // 省电
  BALANCED = 1,     // 平衡（默认）
  HIGH_POWER = 2    // 耗电
}

// 各档参数：timeInterval=定位回调间隔(秒)；distanceInterval=足迹点记录距离门槛(米，仅控海量点稀疏度)；
//          maxAccuracy=精度门槛(米，超出则丢弃漂移点)
export interface RecordModeConfig {
  timeInterval: number;
  distanceInterval: number;
  maxAccuracy: number;
  label: string;
}

// 三档参数：省电 / 平衡(默认) / 耗电
// 折线防漂：timeInterval 采样 + 精度过滤 + 5m 位移地板 + 速度门槛(静止判定) + 30m 静止迟滞；distanceInterval 仅用来给足迹点(海量点)降密度
export const MODE_CONFIG: RecordModeConfig[] = [
  { timeInterval: 60, distanceInterval: 200, maxAccuracy: 200, label: '省电' },
  { timeInterval: 15, distanceInterval: 50,  maxAccuracy: 100, label: '平衡' },
  { timeInterval: 5,  distanceInterval: 20,  maxAccuracy: 30,  label: '耗电' }
];

// 待写入数据库的轨迹点记录（含精度/速度/时间戳）
export interface TrackPointRecord {
  latitude: number;
  longitude: number;
  timestamp: number;
  accuracy: number;
  speed: number;
}

// 统计面板「最近 7 天」每日聚合数据（ArkTS 禁止对象字面量作为类型注解，需显式接口）
export interface StatDayItem {
  label: string;
  distance: number;
  count: number;
}

// computeStats 的输出结构（从全量 allTrackPoints 派生的统计指标集合）
export interface StatResult {
  totalDistance: number;
  trackCount: number;
  activeDays: number;
  avgDailyDist: number;
  maxDailyDist: number;
  firstTs: number;
  lastTs: number;
  recent7: StatDayItem[];
}

// ===== 本地数据库（ArkData RdbStore）配置 =====
export const DB_NAME: string = 'footprint.db';    // 数据库文件名，存于应用沙箱
export const TABLE_NAME: string = 'track_points'; // 轨迹点表名
// 建表语句：新装直接带全字段；旧库通过 initDatabase 里的 ALTER TABLE 兼容升级
export const CREATE_TABLE_SQL: string =
  `CREATE TABLE IF NOT EXISTS ${TABLE_NAME} (id INTEGER PRIMARY KEY AUTOINCREMENT, latitude REAL, longitude REAL, timestamp INTEGER DEFAULT 0, accuracy REAL DEFAULT 0, speed REAL DEFAULT 0)`;
// 不兼容旧轨迹数据：若检测到旧表（缺新字段），直接删表重建，旧数据不保留
export const DROP_TABLE_SQL: string = `DROP TABLE IF EXISTS ${TABLE_NAME}`;
export const CREATE_INDEX_SQL: string = `CREATE INDEX IF NOT EXISTS idx_ts ON ${TABLE_NAME}(timestamp)`;

// 轻量偏好存储：持久化地图样式（经典/暗夜/浅白），避免每次重进都被重置为经典
export const PREF_NAME: string = 'app_prefs';
export const PREF_KEY_MAP_STYLE: string = 'mapStyleIndex';
// 轻量偏好存储：持久化「时间范围」视图选择（0=总览 / 1=自定义 / 2=今日）与自定义起止日期
export const PREF_KEY_TIME_VIEW: string = 'timeViewIndex';
export const PREF_KEY_CUSTOM_START: string = 'customStartTs';
export const PREF_KEY_CUSTOM_END: string = 'customEndTs';

// 时间范围视图索引常量
export const TIME_VIEW_OVERVIEW: number = 0; // 总览（仅海量点）
export const TIME_VIEW_CUSTOM: number = 1;   // 自定义日期
export const TIME_VIEW_TODAY: number = 2;    // 今日（默认）

// 一天的毫秒数
export const ONE_DAY_MS: number = 24 * 60 * 60 * 1000;

// 自定义地图样式 ID（在 Petal Maps Studio 发布）：暗夜 / 浅白
export const MAP_STYLE_DARK_ID: string = '1992208612130395136';
export const MAP_STYLE_LIGHT_ID: string = '1992216939216384896';

// ===== 防漂移 / 落库 / 绘制节流阈值（原 Index 的 private static readonly 提升为模块常量）=====
// 折线轨迹距离地板：新点与上一个轨迹点距离 < 阈值时丢弃，过滤GPS漂移导致的原地锯齿线
export const MIN_TRACK_DISTANCE: number = 5;
// 抖动地板可选阈值（米）：默认 5 米，支持在策略实验室面板切换为 10 / 15 米
export const SHAKE_FLOOR_OPTIONS: number[] = [5, 10, 15];
// 静止检测：最近窗口大小
export const STATIONARY_WINDOW: number = 10;
// 静止检测：窗口内所有点到质心距离 < 15米则判定为静止
export const STATIONARY_RADIUS: number = 15;
// 静止时定位频率（秒），降低频率减少漂移点产生（覆盖各模式间隔）
export const STATIONARY_INTERVAL: number = 30;
// 静止速度门槛（米/秒）：定位上报速度低于此值视为原地未移动（≈3.6km/h，低于步行），
// 用于过滤静止时的位置漂移（室内网络定位/弱信号下位置会原地乱跳，但速度常近似 0）
export const STATIONARY_SPEED: number = 1.0;
// 静止退出半径（米）：已判定为常驻后，仅当新点明显远离常驻簇超过此值才视为真正离开并恢复记录
// （迟滞，防止抖动误把常驻点判成「在动」而漏记飘线）
export const STATIONARY_EXIT_RADIUS: number = 30;
// 批量落库：缓冲积累点数达此值立即落库
export const BATCH_SIZE: number = 15;
// 批量落库：定时落库间隔（毫秒）
export const FLUSH_INTERVAL: number = 8000;
// 覆盖物最多每30秒刷新一次
export const OVERLAY_UPDATE_INTERVAL: number = 30;
// 每新增50个折线点刷新折线
export const POLYLINE_UPDATE_POINT_GAP: number = 50;
// 每新增20个足迹点刷新海量点
export const FOOTPRINT_UPDATE_POINT_GAP: number = 20;
