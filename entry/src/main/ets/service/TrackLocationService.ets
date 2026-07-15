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
import {
  RecordMode,
  MODE_CONFIG,
  STATIONARY_WINDOW,
  STATIONARY_RADIUS,
  SLEEP_END_HOUR,
  SLEEP_MIN_ACTIVE_DURATION,
  TAG
} from '../model/TrackTypes';
import { calculateDistance, getDayKey } from '../common/TrackUtils';

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
  private lastRecordedDay: string = '';

  private sleepModeEnabled: boolean = false;
  private userMode: RecordMode = RecordMode.BALANCED;
  private isInSleepMode: boolean = false;
  private sleepExitTime: number = 0;
  private sleepExitTimer: number | null = null;


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
      } catch (err) {
        const error = err as BusinessError;
        hilog.error(0x0000, TAG_LOG, 'switchMode failed, code: %{public}d, message: %{public}s', error.code, error.message);
      }
    }
  }

  private buildLocationRequest(): geoLocationManager.LocationRequest {
    const config = MODE_CONFIG[this.currentMode];
    return {
      priority: geoLocationManager.LocationRequestPriority.ACCURACY,
      scenario: geoLocationManager.LocationRequestScenario.UNSET,
      timeInterval: config.timeInterval,
      distanceInterval: 0,
      maxAccuracy: 0
    };
  }

  startLocation(handlers: LocationHandlers): void {
    // 检查定位开关是否开启
    try {
      if (!geoLocationManager.isLocationEnabled()) {
        hilog.warn(0x0000, TAG_LOG, 'Location switch is off, cannot start tracking');
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

    this.lastRecordedPoint = null;

    // 订阅持续定位错误（权限被撤销、开关被关闭、网络不可用等）
    this.locationErrorCallback = (errCode: geoLocationManager.LocationError): void => {
      hilog.warn(0x0000, TAG_LOG, `Location error: ${errCode}`);
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
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'startLocation failed, code: %{public}d, message: %{public}s', error.code, error.message);
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
      return;
    }

    const todayKey: string = getDayKey(now);
    if (todayKey !== this.lastRecordedDay) {
      this.lastRecordedPoint = gcj02;
      this.lastRecordedDay = todayKey;
      handlers.onSample(gcj02, accuracy, speedVal, now, true);
      return;
    }

    const dist: number = calculateDistance(gcj02, this.lastRecordedPoint);
    const config = MODE_CONFIG[this.currentMode];
    if (dist >= config.distanceInterval) {
      this.lastRecordedPoint = gcj02;
      handlers.onSample(gcj02, accuracy, speedVal, now);
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
  }

  switchMode(mode: number): void {
    if (mode < 0 || mode >= MODE_CONFIG.length) {
      return;
    }
    this.userMode = mode as RecordMode;
    if (this.isInSleepMode) {
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
