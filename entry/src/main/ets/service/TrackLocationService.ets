/**
 * TrackLocationService.ets —— 实时定位与轨迹采样服务
 *
 * 职责：WGS84→GCJ02 转换、距离触发采样、静止检测（静止不打点），
 * 最终把「干净采样点」通过回调 onSample 交给页面做后续记录。
 * 不持有地图 controller 与轨迹点数组，保持与 UI / 地图解耦。
 *
 * 已删除策略：漂移过滤、轮询模式（所有模式统一走距离触发）
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { geoLocationManager } from '@kit.LocationKit';
import { map, mapCommon } from '@kit.MapKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LogService } from './LogService';
import {
  RecordMode,
  MODE_CONFIG,
  STATIONARY_WINDOW,
  STATIONARY_RADIUS,
  SPIKE_DEVIATION_METERS,
  SLEEP_END_HOUR,
  SLEEP_MIN_ACTIVE_DURATION,
  TAG,
  PREF_NAME,
  PREF_KEY_LAST_LAT,
  PREF_KEY_LAST_LON,
  PREF_KEY_LAST_DAY,
  LogLevel
} from '../model/TrackTypes';
import { calculateDistance, getDayKey, pointToSegmentDistance } from '../common/TrackUtils';

const TAG_LOG: string = 'TrackLocSvc';

export interface LocationHandlers {
  onSample: (latLng: mapCommon.LatLng, accuracy: number, speed: number, timestamp?: number, isInitial?: boolean) => void;
  onLocationError?: (error: geoLocationManager.LocationError) => void;
  onLocationEnabledChange?: (enabled: boolean) => void;
}

export class TrackLocationService {
  private recentPoints: mapCommon.LatLng[] = [];

  private currentMode: RecordMode = RecordMode.BALANCED;
  private locationCallback?: (location: geoLocationManager.Location) => void;
  private locationErrorCallback?: (error: geoLocationManager.LocationError) => void;
  private locationEnabledCallback?: (state: boolean) => void;
  private lastRecordedPoint: mapCommon.LatLng | null = null;
  private prevRecordedPoint: mapCommon.LatLng | null = null;
  private lastRecordedDay: string = '';

  private sleepModeEnabled: boolean = false;
  private userMode: RecordMode = RecordMode.BALANCED;
  private isInSleepMode: boolean = false;
  private sleepExitTime: number = 0;
  private sleepExitTimer: number | null = null;
  private appContext?: common.UIAbilityContext;
  private logSvc: LogService = new LogService();

  setLogService(svc: LogService): void {
    this.logSvc = svc;
  }

  init(context: common.UIAbilityContext): void {
    this.appContext = context;
    this.restoreLastRecorded();
  }


  get mode(): RecordMode {
    return this.currentMode;
  }

  get sleepActive(): boolean {
    return this.isInSleepMode;
  }

  setSleepModeEnabled(enabled: boolean): void {
    this.sleepModeEnabled = enabled;
    if (!enabled && this.isInSleepMode) {
      this.exitSleepMode();
    }
    if (enabled && !this.isInSleepMode) {
      this.checkAndEnterSleep();
    }
  }

  setUserMode(mode: RecordMode): void {
    this.userMode = mode;
  }

  private isInSleepTimeWindow(): boolean {
    const hour: number = new Date().getHours();
    return hour < SLEEP_END_HOUR;
  }

  checkAndEnterSleep(): void {
    if (!this.sleepModeEnabled || this.isInSleepMode || !this.isInSleepTimeWindow()) {
      return;
    }
    if (this.recentPoints.length >= STATIONARY_WINDOW && this.detectStationary()) {
      this.enterSleepMode();
    }
  }

  private enterSleepMode(): void {
    this.isInSleepMode = true;
    this.currentMode = RecordMode.SLEEP;
    this.reSubscribe();
    this.scheduleSleepExit();
    hilog.info(0x0000, TAG_LOG, 'Sleep mode entered');
    this.logSvc.log(LogLevel.INFO, '睡眠', '进入睡眠模式');
  }

  private exitSleepMode(): void {
    if (!this.isInSleepMode) {
      return;
    }
    this.clearSleepExitTimer();
    this.isInSleepMode = false;
    this.sleepExitTime = Date.now();
    this.currentMode = this.userMode;
    this.reSubscribe();
    hilog.info(0x0000, TAG_LOG, 'Sleep mode exited');
    this.logSvc.log(LogLevel.INFO, '睡眠', '退出睡眠模式');
  }

  private scheduleSleepExit(): void {
    this.clearSleepExitTimer();
    const now: Date = new Date();
    const exitTime: Date = new Date(now);
    exitTime.setHours(SLEEP_END_HOUR, 0, 0, 0);
    const delay: number = exitTime.getTime() - now.getTime();
    if (delay <= 0) {
      return;
    }
    this.sleepExitTimer = setTimeout(() => {
      this.sleepExitTimer = null;
      this.exitSleepMode();
    }, delay);
  }

  private clearSleepExitTimer(): void {
    if (this.sleepExitTimer !== null) {
      clearTimeout(this.sleepExitTimer);
      this.sleepExitTimer = null;
    }
  }

  private reSubscribe(): void {
    if (this.locationCallback) {
      try {
        geoLocationManager.off('locationChange', this.locationCallback);
        geoLocationManager.on('locationChange', this.buildLocationRequest(), this.locationCallback);
        hilog.info(0x0000, TAG_LOG, `Record mode switched to ${MODE_CONFIG[this.currentMode].label}`);
        this.logSvc.log(LogLevel.INFO, '模式', `切换为${MODE_CONFIG[this.currentMode].label}模式`);
      } catch (err) {
        const error = err as BusinessError;
        hilog.error(0x0000, TAG_LOG, 'switchMode failed, code: %{public}d, message: %{public}s', error.code, error.message);
      }
    }
  }

  private buildLocationRequest(): geoLocationManager.LocationRequest {
    const config = MODE_CONFIG[this.currentMode];
    return {
      // 使用轨迹跟踪场景时优先级设为 UNSET，由 scenario 字段控制定位策略；
      // 否则使用 ACCURACY（精度优先），确保 GPS 定位精度最高
      priority: config.useTrajectoryScenario
        ? geoLocationManager.LocationRequestPriority.UNSET
        : geoLocationManager.LocationRequestPriority.ACCURACY,
      // 轨迹跟踪场景（TRAJECTORY_TRACKING）由系统优化定位频率与功耗；
      // 非轨迹跟踪场景设为 UNSET，由 priority 字段控制
      scenario: config.useTrajectoryScenario
        ? geoLocationManager.LocationRequestScenario.TRAJECTORY_TRACKING
        : geoLocationManager.LocationRequestScenario.UNSET,
      // 最小上报时间间隔（秒）：系统不会比此间隔更频繁地上报定位
      // 注意：在 TRAJECTORY_TRACKING 等场景下，系统可能忽略此值，
      // 此时 distanceInterval 是控制回调频率的关键参数
      timeInterval: config.timeInterval,
      // 最小上报距离间隔（米）：系统仅当位置变化距离 ≥ 此值时才回调
      // 设为 0 表示不限制距离，系统会在每次位置变化时都回调（约1次/秒），
      // 导致 GPS 硬件持续高频运行、耗电暴增。
      // 因此必须从配置读取（均衡模式=90米），让系统在底层就按距离过滤，
      // 而非每秒都回调后再由 App 层的 handleFix 距离判断来丢弃无效点
      distanceInterval: config.distanceInterval,
      // 精度过滤阈值（米）：设为0表示不过滤，均衡模式信任TRAJECTORY_TRACKING场景优化，避免地铁等信号差场景丢点
      // 设为0表示不过滤精度，所有定位点都会回调
      maxAccuracy: config.maxAccuracy
    };
  }

  startLocation(handlers: LocationHandlers): void {
    // 检查定位开关是否开启
    try {
      if (!geoLocationManager.isLocationEnabled()) {
        hilog.warn(0x0000, TAG_LOG, 'Location switch is off, cannot start tracking');
        this.logSvc.log(LogLevel.ERROR, '中断', '定位开关未开启');
        if (handlers.onLocationError) {
          handlers.onLocationError(geoLocationManager.LocationError.LOCATING_FAILED_LOCATION_SWITCH_OFF);
        }
        return;
      }
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'isLocationEnabled check failed, code: %{public}d, message: %{public}s', error.code, error.message);
    }

    // 清理旧订阅
    if (this.locationCallback) {
      try {
        geoLocationManager.off('locationChange', this.locationCallback);
      } catch (err) {
        hilog.warn(0x0000, TAG_LOG, 'Failed to unsubscribe old locationChange listener');
      }
      this.locationCallback = undefined;
    }
    if (this.locationErrorCallback) {
      try {
        geoLocationManager.off('locationError', this.locationErrorCallback);
      } catch (err) {
        hilog.warn(0x0000, TAG_LOG, 'Failed to unsubscribe old locationError listener');
      }
      this.locationErrorCallback = undefined;
    }
    if (this.locationEnabledCallback) {
      try {
        geoLocationManager.off('locationEnabledChange', this.locationEnabledCallback);
      } catch (err) {
        hilog.warn(0x0000, TAG_LOG, 'Failed to unsubscribe old locationEnabledChange listener');
      }
      this.locationEnabledCallback = undefined;
    }

    // 订阅持续定位错误（权限被撤销、开关被关闭、网络不可用等）
    this.locationErrorCallback = (errCode: geoLocationManager.LocationError): void => {
      hilog.warn(0x0000, TAG_LOG, `Location error: ${errCode}`);
      this.logSvc.log(LogLevel.ERROR, '中断', `定位错误: ${errCode}`);
      if (handlers.onLocationError) {
        handlers.onLocationError(errCode);
      }
    };
    try {
      geoLocationManager.on('locationError', this.locationErrorCallback);
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'Failed to subscribe locationError, code: %{public}d, message: %{public}s', error.code, error.message);
    }

    // 订阅定位开关状态变化（用户手动开关定位时通知调用方）
    this.locationEnabledCallback = (enabled: boolean): void => {
      hilog.info(0x0000, TAG_LOG, `Location enabled changed: ${enabled}`);
      this.logSvc.log(enabled ? LogLevel.INFO : LogLevel.ERROR,
        enabled ? '恢复' : '中断',
        enabled ? '定位已开启' : '定位已关闭');
      if (handlers.onLocationEnabledChange) {
        handlers.onLocationEnabledChange(enabled);
      }
    };
    try {
      geoLocationManager.on('locationEnabledChange', this.locationEnabledCallback);
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'Failed to subscribe locationEnabledChange, code: %{public}d, message: %{public}s', error.code, error.message);
    }

    // 订阅位置变化
    this.locationCallback = (location: geoLocationManager.Location) => {
      map.convertCoordinate(
        mapCommon.CoordinateType.WGS84,
        mapCommon.CoordinateType.GCJ02,
        { latitude: location.latitude, longitude: location.longitude }
      ).then((gcj02: mapCommon.LatLng) => {
        this.handleFix(gcj02, location.accuracy, location.speed, handlers);
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, TAG_LOG, 'convertCoordinate failed, code: %{public}d, message: %{public}s', err.code, err.message);
      });
    };
    try {
      geoLocationManager.on('locationChange', this.buildLocationRequest(), this.locationCallback);
      hilog.info(0x0000, TAG_LOG, 'Location change listener registered');
      this.logSvc.log(LogLevel.INFO, '模式', '开始定位');
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'startLocation failed, code: %{public}d, message: %{public}s', error.code, error.message);
      this.logSvc.log(LogLevel.ERROR, '中断', `启动定位失败: ${error.code}`);
    }
  }

  private handleFix(
    gcj02: mapCommon.LatLng, accuracy: number, speed: number | undefined,
    handlers: LocationHandlers
  ): void {
    const speedVal: number = speed !== undefined ? speed : 0;
    const now: number = Date.now();

    this.recentPoints.push(gcj02);
    if (this.recentPoints.length > STATIONARY_WINDOW) {
      this.recentPoints.shift();
    }

    if (this.isInSleepMode) {
      if (this.lastRecordedPoint !== null) {
        const sleepDist: number = calculateDistance(gcj02, this.lastRecordedPoint);
        const userConfig = MODE_CONFIG[this.userMode];
        if (sleepDist >= userConfig.distanceInterval) {
          this.exitSleepMode();
          this.logSvc.log(LogLevel.INFO, '恢复', `睡眠中移动${sleepDist.toFixed(0)}m，退出睡眠`);
        } else {
          return;
        }
      } else {
        return;
      }
    }

    if (this.sleepModeEnabled && this.isInSleepTimeWindow() && !this.isInSleepMode) {
      if (this.sleepExitTime > 0 && (now - this.sleepExitTime) < SLEEP_MIN_ACTIVE_DURATION) {
        // 退出睡眠后未满最短活动持续时间，不重新进入
      } else {
        if (this.recentPoints.length >= STATIONARY_WINDOW && this.detectStationary()) {
          this.enterSleepMode();
          return;
        }
      }
    }

    if (this.lastRecordedPoint === null) {
      this.lastRecordedPoint = gcj02;
      this.lastRecordedDay = getDayKey(now);
      handlers.onSample(gcj02, accuracy, speedVal, now, true);
      this.persistLastRecorded();
      this.logSvc.log(LogLevel.INFO, '打点', '首点记录');
      return;
    }

    const todayKey: string = getDayKey(now);
    if (todayKey !== this.lastRecordedDay) {
      this.lastRecordedPoint = gcj02;
      this.lastRecordedDay = todayKey;
      handlers.onSample(gcj02, accuracy, speedVal, now, true);
      this.persistLastRecorded();
      this.logSvc.log(LogLevel.INFO, '打点', `新日首点 ${todayKey}`);
      return;
    }

    const dist: number = calculateDistance(gcj02, this.lastRecordedPoint);
    const config = MODE_CONFIG[this.currentMode];
    if (dist >= config.distanceInterval) {
      this.checkAndLogSpike(gcj02);
      this.prevRecordedPoint = this.lastRecordedPoint;
      this.lastRecordedPoint = gcj02;
      this.lastRecordedDay = getDayKey(now);
      handlers.onSample(gcj02, accuracy, speedVal, now);
      this.persistLastRecorded();
      this.logSvc.log(LogLevel.INFO, '打点', `采样点 距上次${dist.toFixed(0)}m`);
    }
  }

  private checkAndLogSpike(currentPoint: mapCommon.LatLng): void {
    if (this.prevRecordedPoint === null || this.lastRecordedPoint === null) {
      return;
    }
    const A: mapCommon.LatLng = this.prevRecordedPoint;
    const B: mapCommon.LatLng = this.lastRecordedPoint;
    const C: mapCommon.LatLng = currentPoint;
    const dAC: number = calculateDistance(A, C);
    const deviation: number = dAC < 1
      ? calculateDistance(B, A)
      : pointToSegmentDistance(B, A, C);
    if (deviation >= SPIKE_DEVIATION_METERS) {
      hilog.info(0x0000, TAG_LOG,
        `Spike detected: deviation=${deviation.toFixed(1)}m dAC=${dAC.toFixed(1)}m`);
      this.logSvc.log(LogLevel.INFO, '尖刺',
        `检测 偏离${deviation.toFixed(0)}m dAC=${dAC.toFixed(0)}m`);
    }
  }

  stopLocation(): void {
    try {
      if (this.locationCallback) {
        geoLocationManager.off('locationChange', this.locationCallback);
      }
    } catch (err) {
      hilog.warn(0x0000, TAG_LOG, 'Failed to unsubscribe locationChange');
    }
    try {
      if (this.locationErrorCallback) {
        geoLocationManager.off('locationError', this.locationErrorCallback);
      }
    } catch (err) {
      hilog.warn(0x0000, TAG_LOG, 'Failed to unsubscribe locationError');
    }
    try {
      if (this.locationEnabledCallback) {
        geoLocationManager.off('locationEnabledChange', this.locationEnabledCallback);
      }
    } catch (err) {
      hilog.warn(0x0000, TAG_LOG, 'Failed to unsubscribe locationEnabledChange');
    }
    this.locationCallback = undefined;
    this.locationErrorCallback = undefined;
    this.locationEnabledCallback = undefined;
    this.recentPoints = [];
    this.isInSleepMode = false;
    this.sleepExitTime = 0;
    this.clearSleepExitTimer();
    this.logSvc.log(LogLevel.INFO, '模式', '停止定位');
  }

  private persistLastRecorded(): void {
    if (this.appContext === undefined || this.lastRecordedPoint === null) {
      return;
    }
    try {
      const pref = preferences.getPreferencesSync(this.appContext, { name: PREF_NAME });
      pref.putSync(PREF_KEY_LAST_LAT, this.lastRecordedPoint.latitude);
      pref.putSync(PREF_KEY_LAST_LON, this.lastRecordedPoint.longitude);
      pref.putSync(PREF_KEY_LAST_DAY, this.lastRecordedDay);
      pref.flushSync();
    } catch (e) {
      const error = e as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'persistLastRecorded failed, code: %{public}d, message: %{public}s', error.code, error.message);
    }
  }

  private restoreLastRecorded(): void {
    if (this.appContext === undefined) {
      return;
    }
    try {
      const pref = preferences.getPreferencesSync(this.appContext, { name: PREF_NAME });
      const lat: number = pref.getSync(PREF_KEY_LAST_LAT, 0) as number;
      const lon: number = pref.getSync(PREF_KEY_LAST_LON, 0) as number;
      const day: string = pref.getSync(PREF_KEY_LAST_DAY, '') as string;
      if (lat !== 0 && lon !== 0 && day !== '') {
        this.lastRecordedPoint = { latitude: lat, longitude: lon } as mapCommon.LatLng;
        this.lastRecordedDay = day;
        hilog.info(0x0000, TAG_LOG, `Restored lastRecordedPoint: ${lat}, ${lon}, day: ${day}`);
      }
    } catch (e) {
      const error = e as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'restoreLastRecorded failed, code: %{public}d, message: %{public}s', error.code, error.message);
    }
  }

  switchMode(mode: number): void {
    if (mode < 0 || mode >= MODE_CONFIG.length) {
      return;
    }
    this.userMode = mode as RecordMode;
    if (this.isInSleepMode) {
      this.logSvc.log(LogLevel.INFO, '模式', `模式切换请求(${MODE_CONFIG[mode].label})，当前睡眠中暂不切换`);
      return;
    }
    this.currentMode = this.userMode;
    this.reSubscribe();
  }

  private detectStationary(): boolean {
    if (this.recentPoints.length < STATIONARY_WINDOW) {
      return false;
    }
    let sumLat: number = 0;
    let sumLon: number = 0;
    for (let point of this.recentPoints) {
      sumLat += point.latitude;
      sumLon += point.longitude;
    }
    const centroid: mapCommon.LatLng = {
      latitude: sumLat / this.recentPoints.length,
      longitude: sumLon / this.recentPoints.length
    };
    for (let point of this.recentPoints) {
      if (calculateDistance(point, centroid) >= STATIONARY_RADIUS) {
        return false;
      }
    }
    return true;
  }


}
