/**
 * TrackLocationService.ets —— 实时定位与轨迹采样服务
 *
 * 职责：WGS84→GCJ02 转换、距离触发采样、静止检测（静止不打点），
 * 最终把「干净采样点」通过回调 onSample 交给页面做后续记录。
 * 不持有地图 controller 与轨迹点数组，保持与 UI / 地图解耦。
 *
 * 已删除策略：漂移过滤、轮询模式（所有模式统一走距离触发）
 */

import { geoLocationManager } from '@kit.LocationKit';
import { map, mapCommon } from '@kit.MapKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  RecordMode,
  MODE_CONFIG,
  STATIONARY_WINDOW,
  STATIONARY_RADIUS,
  STATIONARY_EXIT_RADIUS,
  SLEEP_START_HOUR,
  SLEEP_END_HOUR,
  SLEEP_MOVEMENT_TREND_COUNT,
  SLEEP_MOVEMENT_CUMULATIVE_DIST,
  SLEEP_MIN_ACTIVE_DURATION,
  TAG
} from '../model/TrackTypes';
import { calculateDistance, getDayKey } from '../common/TrackUtils';
import { AppLogger } from '../common/logger/AppLogger';

export interface LocationHandlers {
  onSample: (latLng: mapCommon.LatLng, accuracy: number, speed: number, timestamp?: number, isInitial?: boolean) => void;
}

export class TrackLocationService {
  private recentPoints: mapCommon.LatLng[] = [];
  private isStationary: boolean = false;
  private currentMode: RecordMode = RecordMode.BALANCED;
  private locationCallback?: (location: geoLocationManager.Location) => void;
  private lastRecordedPoint: mapCommon.LatLng | null = null;
  private lastRecordedDay: string = '';

  setLastRecordedPoint(point: mapCommon.LatLng | null, dayKey: string = ''): void {
    this.lastRecordedPoint = point;
    this.lastRecordedDay = dayKey;
  }

  private sleepModeEnabled: boolean = false;
  private stationaryEnabled: boolean = true;
  private userMode: RecordMode = RecordMode.BALANCED;
  private isInSleepMode: boolean = false;
  private sleepOriginPoint: mapCommon.LatLng | null = null;
  private sleepDistances: number[] = [];
  private sleepExitTime: number = 0;

  get stationary(): boolean {
    return this.isStationary;
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

  setStationaryEnabled(enabled: boolean): void {
    this.stationaryEnabled = enabled;
    if (!enabled) {
      this.isStationary = false;
    }
  }

  setUserMode(mode: RecordMode): void {
    this.userMode = mode;
  }

  private isInSleepTimeWindow(): boolean {
    const hour: number = new Date().getHours();
    if (SLEEP_START_HOUR === 0 && SLEEP_END_HOUR > 0) {
      return hour < SLEEP_END_HOUR;
    }
    return hour >= SLEEP_START_HOUR || hour < SLEEP_END_HOUR;
  }

  checkAndEnterSleep(): void {
    if (!this.sleepModeEnabled || this.isInSleepMode || !this.isInSleepTimeWindow()) {
      return;
    }
    if (this.sleepExitTime > 0 && (Date.now() - this.sleepExitTime) < SLEEP_MIN_ACTIVE_DURATION) {
      return;
    }
    if (this.recentPoints.length >= STATIONARY_WINDOW && this.detectStationary()) {
      this.enterSleepMode();
    }
  }

  private enterSleepMode(): void {
    this.isInSleepMode = true;
    this.sleepOriginPoint = this.lastRecordedPoint;
    this.sleepDistances = [];
    this.currentMode = RecordMode.SLEEP;
    this.reSubscribe();
    AppLogger.keyInfo('睡眠', `进入睡眠模式`);
  }

  private exitSleepMode(): void {
    if (!this.isInSleepMode) {
      return;
    }
    this.isInSleepMode = false;
    this.sleepOriginPoint = null;
    this.sleepDistances = [];
    this.sleepExitTime = Date.now();
    this.currentMode = this.userMode;
    this.reSubscribe();
    AppLogger.keyInfo('睡眠', `退出睡眠模式，恢复正常记录`);
  }

  private detectSleepMovement(gcj02: mapCommon.LatLng): boolean {
    if (!this.sleepOriginPoint) {
      return false;
    }
    const dist: number = calculateDistance(this.sleepOriginPoint, gcj02);
    this.sleepDistances.push(dist);
    if (this.sleepDistances.length > SLEEP_MOVEMENT_TREND_COUNT) {
      this.sleepDistances.shift();
    }
    if (this.sleepDistances.length < SLEEP_MOVEMENT_TREND_COUNT) {
      return false;
    }
    if (dist < SLEEP_MOVEMENT_CUMULATIVE_DIST) {
      return false;
    }
    for (let i = 1; i < this.sleepDistances.length; i++) {
      if (this.sleepDistances[i] < this.sleepDistances[i - 1]) {
        return false;
      }
    }
    return true;
  }

  checkAndExitSleepOnTime(): void {
    if (this.isInSleepMode && !this.isInSleepTimeWindow()) {
      this.isInSleepMode = false;
      this.sleepOriginPoint = null;
      this.sleepDistances = [];
      this.sleepExitTime = 0;
      this.currentMode = this.userMode;
      this.reSubscribe();
      AppLogger.keyInfo('睡眠', `定时检查：超过睡眠时段，退出睡眠`);
    }
  }


  private reSubscribe(): void {
    if (this.locationCallback) {
      try {
        geoLocationManager.off('locationChange', this.locationCallback);
        geoLocationManager.on('locationChange', this.buildLocationRequest(), this.locationCallback);
        AppLogger.info('定位', `重新订阅 间隔=${MODE_CONFIG[this.currentMode].timeInterval}s`);
      } catch (err) {
        const error = err as BusinessError;
        AppLogger.error('定位', `重新订阅失败 code=${error.code}`);
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
    if (this.locationCallback) {
      try {
        geoLocationManager.off('locationChange', this.locationCallback);
      } catch (err) {
        console.warn(TAG, 'Failed to unsubscribe old locationChange listener');
      }
      this.locationCallback = undefined;
    }

    this.locationCallback = (location: geoLocationManager.Location) => {
      map.convertCoordinate(
        mapCommon.CoordinateType.WGS84,
        mapCommon.CoordinateType.GCJ02,
        { latitude: location.latitude, longitude: location.longitude }
      ).then((gcj02: mapCommon.LatLng) => {
        this.handleFix(gcj02, location.accuracy, location.speed, handlers);
      }).catch((err: BusinessError) => {
        AppLogger.error('定位', `坐标转换失败 code=${err.code}`);
      });
    };
    geoLocationManager.on('locationChange', this.buildLocationRequest(), this.locationCallback);
    AppLogger.keyInfo('定位', `定位服务已启动 模式=${MODE_CONFIG[this.currentMode].label}`);
  }

  private handleFix(
    gcj02: mapCommon.LatLng, accuracy: number, speed: number | undefined,
    handlers: LocationHandlers
  ): void {
    const speedVal: number = speed !== undefined ? speed : 0;
    const now: number = Date.now();

    AppLogger.debug('定位', `回传 精度=${Math.round(accuracy)}m 速度=${speedVal.toFixed(1)}m/s`);

    this.recentPoints.push(gcj02);
    if (this.recentPoints.length > STATIONARY_WINDOW) {
      this.recentPoints.shift();
    }

    if (this.isInSleepMode) {
      this.handleSleepFix(gcj02, accuracy, speedVal, now, handlers);
      return;
    }

    if (this.sleepModeEnabled && this.isInSleepTimeWindow() && !this.isInSleepMode) {
      if (this.sleepExitTime > 0 && (now - this.sleepExitTime) < SLEEP_MIN_ACTIVE_DURATION) {
        AppLogger.info('定位', `退出睡眠未满5分钟，跳过睡眠入口`);
      } else {
        if (this.recentPoints.length >= STATIONARY_WINDOW && this.detectStationary()) {
          AppLogger.keyInfo('睡眠', `静止检测触发，进入睡眠模式`);
          this.enterSleepMode();
          return;
        }
      }
    }

    if (this.lastRecordedPoint === null) {
      this.lastRecordedPoint = gcj02;
      this.lastRecordedDay = getDayKey(now);
      AppLogger.keyInfo('定位', `首次打点(初始点) 精度=${Math.round(accuracy)}m 速度=${speedVal.toFixed(1)}m/s`);
      handlers.onSample(gcj02, accuracy, speedVal, now, true);
      return;
    }

    const todayKey: string = getDayKey(now);
    if (todayKey !== this.lastRecordedDay) {
      this.lastRecordedPoint = gcj02;
      this.lastRecordedDay = todayKey;
      AppLogger.keyInfo('定位', `跨天初始点 精度=${Math.round(accuracy)}m`);
      handlers.onSample(gcj02, accuracy, speedVal, now, true);
      return;
    }

    if (this.stationaryEnabled && this.detectStationary()) {
      if (!this.isStationary) {
        this.isStationary = true;
        AppLogger.keyInfo('静止', `进入静止状态`);
      }
      return;
    }

    if (this.isStationary) {
      const centroid: mapCommon.LatLng | null = this.getRecentCentroid();
      if (centroid !== null && calculateDistance(gcj02, centroid) < STATIONARY_EXIT_RADIUS) {
        return;
      }
      this.isStationary = false;
      AppLogger.keyInfo('静止', `退出静止状态`);
    }

    const dist: number = calculateDistance(gcj02, this.lastRecordedPoint);
    const config = MODE_CONFIG[this.currentMode];
    if (dist >= config.distanceInterval) {
      this.lastRecordedPoint = gcj02;
      AppLogger.keyInfo('定位', `打点 距上个点${Math.round(dist)}m 精度=${Math.round(accuracy)}m 速度=${speedVal.toFixed(1)}m/s`);
      handlers.onSample(gcj02, accuracy, speedVal, now);
    }
  }

  private handleSleepFix(
    gcj02: mapCommon.LatLng, accuracy: number, speed: number, timestamp: number,
    handlers: LocationHandlers
  ): void {
    if (this.detectSleepMovement(gcj02)) {
      AppLogger.keyInfo('睡眠', `检测到真实移动，退出睡眠`);
      this.exitSleepMode();
      return;
    }

    if (!this.isInSleepTimeWindow()) {
      AppLogger.keyInfo('睡眠', `超过睡眠时段，退出睡眠`);
      this.exitSleepMode();
    }
  }

  stopLocation(): void {
    try {
      if (this.locationCallback) {
        geoLocationManager.off('locationChange', this.locationCallback);
      } else {
        geoLocationManager.off('locationChange');
      }
    } catch (err) {
      console.warn(TAG, 'Failed to unsubscribe locationChange');
    }
    this.locationCallback = undefined;
    this.recentPoints = [];
    this.isStationary = false;
    this.isInSleepMode = false;
    this.sleepOriginPoint = null;

    this.sleepDistances = [];
    this.sleepExitTime = 0;
    AppLogger.keyInfo('定位', `定位服务已停止`);
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
    AppLogger.keyInfo('定位', `切换记录模式 → ${MODE_CONFIG[this.currentMode].label}`);
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

  private getRecentCentroid(): mapCommon.LatLng | null {
    if (this.recentPoints.length < 2) {
      return null;
    }
    let cLat: number = 0;
    let cLon: number = 0;
    for (let p of this.recentPoints) {
      cLat += p.latitude;
      cLon += p.longitude;
    }
    return {
      latitude: cLat / this.recentPoints.length,
      longitude: cLon / this.recentPoints.length
    };
  }

}
