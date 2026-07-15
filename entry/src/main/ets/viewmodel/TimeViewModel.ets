/**
 * TimeViewModel.ets —— 时间视图与全量轨迹状态管理
 *
 * 从 Index 原 allTrackPoints / visibleStartTs / visibleEndTs / timeViewIndex /
 * customStartTs / customEndTs / currentDayKey / dayCheckTimer 及 getVisibleRange /
 * applyTimeView / isInVisibleRange / onTimeViewSelected / openCustomDatePicker /
 * startDayCheck / onDayChange / saveTimeViewPrefs / loadTimeViewPrefs 抽取。
 * 负责全量轨迹点的唯一缓存、按时间范围过滤出可见集（轨迹点 / 足迹点 / 里程），
 * 跨日检测与偏好持久化；地图覆盖物重绘由页面在拿到可见集后驱动。
 */

import { mapCommon } from '@kit.MapKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TrackPointRecord, VisibleRange, StatResult, TIME_VIEW_OVERVIEW, TIME_VIEW_CUSTOM, TIME_VIEW_TODAY, PREF_NAME, PREF_KEY_TIME_VIEW, PREF_KEY_CUSTOM_START, PREF_KEY_CUSTOM_END, TAG } from '../model/TrackTypes';
import { getDayStartTs, getDayEndTs, getDayKey, calculateDistance, computeStats as computeStatsUtil } from '../common/TrackUtils';

const TAG_LOG: string = 'TimeVM';

// applyTimeView 计算出的可见集（纯数据，供页面写入 @State 并驱动地图重绘）
export interface VisibleData {
  trackPoints: mapCommon.LatLng[];
  footprintPoints: mapCommon.LatLng[];
  totalDistance: number;
  lastFootprintPoint: mapCommon.LatLng | null;
}

export class TimeViewModel {
  // allTrackPoints 为唯一全量数据源（含 timestamp），启动时从 DB 一次性载入并随实时记录增量追加；
  // 其余 overlay / 统计均基于「当前可见集」（trackPoints / footprintPoints）派生。
  private allTrackPoints: TrackPointRecord[] = [];
  private visibleStartTs: number = 0;
  private visibleEndTs: number = Number.MAX_SAFE_INTEGER;
  private timeViewIndex: number = TIME_VIEW_TODAY;
  private customStartTs: number = 0;
  private customEndTs: number = 0;
  private currentDayKey: string = '';
  private dayCheckTimer: number | null = null;
  private context?: common.UIAbilityContext;
  private cachedStats: StatResult | null = null;
  private lastComputeCount: number = 0;

  setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  get allPoints(): TrackPointRecord[] {
    return this.allTrackPoints;
  }

  get timeView(): number {
    return this.timeViewIndex;
  }

  get customStart(): number {
    return this.customStartTs;
  }

  get customEnd(): number {
    return this.customEndTs;
  }

  // 增量追加一条全量记录（实时记录时调用）
  addPoint(rec: TrackPointRecord): void {
    this.allTrackPoints.push(rec);
  }

  // 用数据库全量结果一次性替换缓存（启动时载入）
  setAllPoints(records: TrackPointRecord[]): void {
    this.allTrackPoints = records;
  }

  clearAll(): void {
    this.allTrackPoints = [];
    this.cachedStats = null;
    this.lastComputeCount = 0;
  }

  // 增量计算统计：若全量点数未变则直接返回缓存，否则全量重算并更新缓存
  computeStats(): StatResult {
    if (this.cachedStats !== null && this.allTrackPoints.length === this.lastComputeCount) {
      return this.cachedStats;
    }
    const result = computeStatsUtil(this.allTrackPoints);
    this.cachedStats = result;
    this.lastComputeCount = this.allTrackPoints.length;
    return result;
  }

  // 计算当前时间视图对应的可见时间范围 [startTs, endTs]
  getVisibleRange(): VisibleRange {
    if (this.timeViewIndex === TIME_VIEW_OVERVIEW) {
      return { start: 0, end: Number.MAX_SAFE_INTEGER };
    } else if (this.timeViewIndex === TIME_VIEW_CUSTOM) {
      return { start: this.customStartTs, end: this.customEndTs };
    } else {
      return { start: getDayStartTs(Date.now()), end: getDayEndTs(Date.now()) };
    }
  }

  // 判断时间戳是否落在当前可见时间范围内
  isInVisibleRange(ts: number): boolean {
    return ts >= this.visibleStartTs && ts <= this.visibleEndTs;
  }

  // 根据当前 timeViewIndex 重建「可见集」：从全量缓存按时间范围过滤，
  // 重算足迹点(海量点)与里程。删除足迹降密策略后所有轨迹点都记为足迹点。
  applyTimeView(): VisibleData {
    const range = this.getVisibleRange();
    this.visibleStartTs = range.start;
    this.visibleEndTs = range.end;

    const trackPoints: mapCommon.LatLng[] = [];
    const footprintPoints: mapCommon.LatLng[] = [];
    let lastFootprintPoint: mapCommon.LatLng | null = null;
    let totalDistance: number = 0;
    let prev: mapCommon.LatLng | null = null;
    for (let i = 0; i < this.allTrackPoints.length; i++) {
      const rec = this.allTrackPoints[i];
      if (rec.timestamp < range.start || rec.timestamp > range.end) {
        continue;
      }
      const latLng: mapCommon.LatLng = { latitude: rec.latitude, longitude: rec.longitude };
      trackPoints.push(latLng);
      if (prev) {
        totalDistance += calculateDistance(prev, latLng);
      }
      prev = latLng;
      // 足迹降密已删除：所有轨迹点都记为足迹点
      footprintPoints.push(latLng);
      lastFootprintPoint = latLng;
    }
    hilog.info(0x0000, TAG_LOG, 'applyTimeView(%{public}d) -> visible %{public}d points, distance %{public}dm',
      this.timeViewIndex, trackPoints.length, Math.round(totalDistance));
    return { trackPoints, footprintPoints, totalDistance, lastFootprintPoint };
  }

  // 切换时间视图：总览 / 自定义 / 今日。自定义时返回 true 表示需要日期选择，由页面层弹 DatePicker；
  // 非自定义视图直接切换并持久化，返回 false
  onTimeViewSelected(index: number): boolean {
    this.timeViewIndex = index;
    if (index === TIME_VIEW_CUSTOM) {
      return true;
    }
    this.savePrefs();
    return false;
  }

  // 页面层弹完 DatePicker 后调用此方法设置自定义范围并持久化
  setCustomRange(start: number, end: number): void {
    this.customStartTs = start;
    this.customEndTs = end;
    this.savePrefs();
  }

  // 启动跨日检测定时器：每分钟比对日期 key，跨过午夜时刷新今日视图
  startDayCheck(onDayChange: () => void): void {
    this.currentDayKey = getDayKey(Date.now());
    this.dayCheckTimer = setInterval(() => {
      const key: string = getDayKey(Date.now());
      if (key !== this.currentDayKey) {
        this.currentDayKey = key;
        onDayChange();
      }
    }, 60 * 1000);
  }

  // 跨日回调：仅当停留在「今日」视图时返回 true，由页面重算今日范围并重绘
  shouldRefreshOnDayChange(): boolean {
    return this.timeViewIndex === TIME_VIEW_TODAY;
  }

  stopDayCheck(): void {
    if (this.dayCheckTimer !== null) {
      clearInterval(this.dayCheckTimer);
      this.dayCheckTimer = null;
    }
  }

  // 持久化「时间范围」视图选择与自定义起止日期，下次重进按上次选择恢复
  savePrefs(): void {
    if (!this.context) {
      return;
    }
    try {
      const pref = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      pref.putSync(PREF_KEY_TIME_VIEW, this.timeViewIndex);
      pref.putSync(PREF_KEY_CUSTOM_START, this.customStartTs);
      pref.putSync(PREF_KEY_CUSTOM_END, this.customEndTs);
      pref.flushSync();
    } catch (e) {
      const error = e as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'saveTimeViewPrefs failed, code: %{public}d, message: %{public}s',
        error.code, error.message);
    }
  }

  // 恢复「时间范围」视图选择与自定义起止日期（默认今日）
  loadPrefs(): void {
    if (!this.context) {
      return;
    }
    try {
      const pref = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      let idx: number = pref.getSync(PREF_KEY_TIME_VIEW, TIME_VIEW_TODAY) as number;
      // 仅允许 0/1/2 三态，非法值回退今日
      if (idx < 0 || idx > 2) {
        idx = TIME_VIEW_TODAY;
      }
      this.timeViewIndex = idx;
      let cs: number = pref.getSync(PREF_KEY_CUSTOM_START, 0) as number;
      let ce: number = pref.getSync(PREF_KEY_CUSTOM_END, 0) as number;
      // 自定义起止未设置时回退为今天，避免空范围
      if (cs <= 0 || ce <= 0) {
        cs = getDayStartTs(Date.now());
        ce = getDayEndTs(Date.now());
      }
      this.customStartTs = cs;
      this.customEndTs = ce;
    } catch (e) {
      const error = e as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'loadTimeViewPrefs failed, code: %{public}d, message: %{public}s',
        error.code, error.message);
      this.timeViewIndex = TIME_VIEW_TODAY;
    }
  }
}
