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
import { calculateDistance } from '../common/TrackUtils';

export interface LocationHandlers {
  onSample: (latLng: mapCommon.LatLng, accuracy: number, speed: number, timestamp?: number) => void;
}

export interface SleepMonitorPoint {
  gcj02: mapCommon.LatLng;
  accuracy: number;
  speed: number;
  timestamp: number;
}

export class TrackLocationService {
  private recentPoints: mapCommon.LatLng[] = [];
  private isStationary: boolean = false;
  private currentMode: RecordMode = RecordMode.BALANCED;
  private locationCallback?: (location: geoLocationManager.Location) => void;
  private lastRecordedPoint: mapCommon.LatLng | null = null;

  private sleepModeEnabled: boolean = false;
  private userMode: RecordMode = RecordMode.BALANCED;
  private isInSleepMode: boolean = false;
  private sleepOriginPoint: mapCommon.LatLng | null = null;
  private sleepMonitorPoints: SleepMonitorPoint[] = [];
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

  setSleepModeEnabled(enabled: boolean, handlers?: LocationHandlers): void {
    this.sleepModeEnabled = enabled;
    if (!enabled && this.isInSleepMode) {
      this.exitSleepMode(handlers);
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
    if (SLEEP_START_HOUR === 0 && SLEEP_END_HOUR > 0) {
      return hour < SLEEP_END_HOUR;
    }
    return hour >= SLEEP_START_HOUR || hour < SLEEP_END_HOUR;
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
    this.sleepOriginPoint = this.lastRecordedPoint;
    this.sleepMonitorPoints = [];
    this.sleepDistances = [];
    this.currentMode = RecordMode.SLEEP;
    this.reSubscribe();
    console.info(TAG, 'Sleep mode entered');
  }

  private exitSleepMode(handlers?: LocationHandlers): void {
    if (!this.isInSleepMode) {
      return;
    }
    this.backfillSleepPoints(handlers);
    this.isInSleepMode = false;
    this.sleepOriginPoint = null;
    this.sleepMonitorPoints = [];
    this.sleepDistances = [];
    this.sleepExitTime = Date.now();
    this.currentMode = this.userMode;
    this.reSubscribe();
    console.info(TAG, 'Sleep mode exited');
  }

  private backfillSleepPoints(handlers?: LocationHandlers): void {
    if (this.sleepMonitorPoints.length === 0 || !this.lastRecordedPoint || !handlers) {
      this.sleepMonitorPoints = [];
      return;
    }
    const config = MODE_CONFIG[this.userMode];
    let refPoint: mapCommon.LatLng = this.lastRecordedPoint;
    for (const mp of this.sleepMonitorPoints) {
      const dist: number = calculateDistance(refPoint, mp.gcj02);
      if (dist >= config.distanceInterval) {
        refPoint = mp.gcj02;
        this.lastRecordedPoint = mp.gcj02;
        handlers.onSample(mp.gcj02, mp.accuracy, mp.speed, mp.timestamp);
      }
    }
    this.sleepMonitorPoints = [];
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
      this.sleepMonitorPoints = [];
      this.sleepDistances = [];
      this.sleepExitTime = 0;
      this.currentMode = this.userMode;
      this.reSubscribe();
      console.info(TAG, 'Sleep mode exited on time');
    }
  }

  private reSubscribe(): void {
    if (this.locationCallback) {
      try {
        geoLocationManager.off('locationChange', this.locationCallback);
        geoLocationManager.on('locationChange', this.buildLocationRequest(), this.locationCallback);
        console.info(TAG, `Record mode switched to ${MODE_CONFIG[this.currentMode].label}`);
      } catch (err) {
        const error = err as BusinessError;
        console.error(`switchMode failed, code: ${error.code}, message: ${error.message}`);
      }
    }
  }

  private buildLocationRequest(): geoLocationManager.LocationRequest {
    const config = MODE_CONFIG[this.currentMode];
    let scenario: geoLocationManager.LocationRequestScenario;
    if (this.currentMode === RecordMode.HIGH_POWER) {
      scenario = geoLocationManager.LocationRequestScenario.NAVIGATION;
    } else {
      scenario = geoLocationManager.LocationRequestScenario.TRAJECTORY_TRACKING;
    }
    return {
      priority: geoLocationManager.LocationRequestPriority.ACCURACY,
      scenario: scenario,
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
    this.lastRecordedPoint = null;
    this.locationCallback = (location: geoLocationManager.Location) => {
      map.convertCoordinate(
        mapCommon.CoordinateType.WGS84,
        mapCommon.CoordinateType.GCJ02,
        { latitude: location.latitude, longitude: location.longitude }
      ).then((gcj02: mapCommon.LatLng) => {
        this.handleFix(gcj02, location.accuracy, location.speed, handlers);
      }).catch((err: BusinessError) => {
        console.error(`convertCoordinate failed, code: ${err.code}, message: ${err.message}`);
      });
    };
    geoLocationManager.on('locationChange', this.buildLocationRequest(), this.locationCallback);
    console.info(TAG, 'Location change listener registered');
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
      this.handleSleepFix(gcj02, accuracy, speedVal, now, handlers);
      return;
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
      handlers.onSample(gcj02, accuracy, speedVal, now);
      return;
    }

    if (this.detectStationary()) {
      if (!this.isStationary) {
        this.isStationary = true;
      }
      return;
    }

    if (this.isStationary) {
      const centroid: mapCommon.LatLng | null = this.getRecentCentroid();
      if (centroid !== null && calculateDistance(gcj02, centroid) < STATIONARY_EXIT_RADIUS) {
        return;
      }
      this.isStationary = false;
    }

    const dist: number = calculateDistance(gcj02, this.lastRecordedPoint);
    const config = MODE_CONFIG[this.currentMode];
    if (dist >= config.distanceInterval) {
      this.lastRecordedPoint = gcj02;
      handlers.onSample(gcj02, accuracy, speedVal, now);
    }
  }

  private handleSleepFix(
    gcj02: mapCommon.LatLng, accuracy: number, speed: number, timestamp: number,
    handlers: LocationHandlers
  ): void {
    this.sleepMonitorPoints.push({ gcj02: gcj02, accuracy: accuracy, speed: speed, timestamp: timestamp } as SleepMonitorPoint);

    if (this.detectSleepMovement(gcj02)) {
      this.exitSleepMode(handlers);
      return;
    }

    if (!this.isInSleepTimeWindow()) {
      this.exitSleepMode(handlers);
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
    this.sleepMonitorPoints = [];
    this.sleepDistances = [];
    this.sleepExitTime = 0;
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
