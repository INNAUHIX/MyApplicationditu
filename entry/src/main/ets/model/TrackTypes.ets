/**
 * TrackTypes.ets —— 轨迹模块的公共类型、枚举与常量
 *
 * 集中管理 Index 原先散落在文件顶部的接口、枚举与模块级常量，
 * 供 data / location / map / state / util 各层共享，避免重复定义。
 */

// 日志 TAG：默认值 'Index'，各模块可自行定义局部 TAG 常量替代此共享常量
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
  BALANCED = 0,     // 均衡（默认）
  HIGH_POWER = 1,   // 耗电
  SLEEP = 2         // 睡眠
}

export interface RecordModeConfig {
  timeInterval: number;
  distanceInterval: number;
  label: string;
}

export const MODE_CONFIG: RecordModeConfig[] = [
  { timeInterval: 20, distanceInterval: 100, label: '均衡' },
  { timeInterval: 5,  distanceInterval: 30,  label: '耗电' },
  { timeInterval: 60, distanceInterval: 200, label: '睡眠' },
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
// 轻量偏好存储：持久化记录规则（0=均衡 / 1=耗电）
export const PREF_KEY_RECORD_MODE: string = 'recordModeIndex';
// 轻量偏好存储：持久化夜间模式（0=跟随系统 / 1=普通模式 / 2=夜间模式）
export const PREF_KEY_NIGHT_MODE: string = 'nightModeIndex';
// 轻量偏好存储：持久化睡眠模式开关
export const PREF_KEY_SLEEP_MODE: string = 'sleepModeEnabled';


// 时间范围视图索引常量
export const TIME_VIEW_OVERVIEW: number = 0; // 总览（仅海量点）
export const TIME_VIEW_CUSTOM: number = 1;   // 自定义日期
export const TIME_VIEW_TODAY: number = 2;    // 今日（默认）

// 一天的毫秒数
export const ONE_DAY_MS: number = 24 * 60 * 60 * 1000;

// 自定义地图样式 ID（在 Petal Maps Studio 发布）：暗夜 / 浅白
export const MAP_STYLE_DARK_ID: string = '1992208612130395136';
export const MAP_STYLE_LIGHT_ID: string = '1992216939216384896';

// ===== 防漂移 / 静止检测阈值 =====
// 静止检测：最近窗口大小
export const STATIONARY_WINDOW: number = 10;
// 静止检测：窗口内所有点到质心距离 < 15米则判定为静止
export const STATIONARY_RADIUS: number = 15;

// 静止退出半径（米）：已判定为常驻后，仅当新点明显远离常驻簇超过此值才视为真正离开并恢复记录
// （迟滞，防止抖动误把常驻点判成「在动」而漏记飘线）
export const STATIONARY_EXIT_RADIUS: number = 30;

// ===== 睡眠模式阈值 =====
// 睡眠模式时段：0点~6点
export const SLEEP_START_HOUR: number = 0;
export const SLEEP_END_HOUR: number = 6;
// 睡眠模式活动判定：连续N个点距睡眠起点距离持续单调递增且累计超过此值，判定为真实移动
export const SLEEP_MOVEMENT_TREND_COUNT: number = 3;
export const SLEEP_MOVEMENT_CUMULATIVE_DIST: number = 100;
// 退出睡眠后最短活动持续时间（毫秒）：防止抖动导致反复进出睡眠
export const SLEEP_MIN_ACTIVE_DURATION: number = 5 * 60 * 1000;

