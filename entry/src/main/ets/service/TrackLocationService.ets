/**
 * TrackLocationService.ets —— 实时定位与轨迹采样服务
 *
 * 从 Index 原 enableMyLocation 的定位订阅回调、detectStationary / getRecentCentroid /
 * getModeInterval / switchMode / switchLocationInterval 抽取。
 * 职责：WGS84→GCJ02 转换、最近窗口驻留检测（静止降频）、按档位切换定位频率，
 * 最终把「干净采样点」通过回调 onSample 交给页面做后续记录。
 * 不持有地图 controller 与轨迹点数组，保持与 UI / 地图解耦。
 *
 * 已删除策略：漂移过滤（maxAccuracy 精度门槛过滤已移除）
 */

import { geoLocationManager } from '@kit.LocationKit';
import { map, mapCommon } from '@kit.MapKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  RecordMode,
  MODE_CONFIG,
  STATIONARY_WINDOW,
  STATIONARY_RADIUS,
  STATIONARY_INTERVAL,
  STATIONARY_EXIT_RADIUS,
  STATIONARY_SPEED,
  TAG
} from '../model/TrackTypes';
import { calculateDistance } from '../common/TrackUtils';

export interface LocationHandlers {
  onSample: (latLng: mapCommon.LatLng, accuracy: number, speed: number) => void;
}

export class TrackLocationService {
  private recentPoints: mapCommon.LatLng[] = [];
  private isStationary: boolean = false;
  private currentMode: RecordMode = RecordMode.BALANCED;
  private locationCallback?: (location: geoLocationManager.Location) => void;
  private lastRecordedPoint: mapCommon.LatLng | null = null;
  private lastRecordedTime: number = 0;

  get stationary(): boolean {
    return this.isStationary;
  }

  get mode(): RecordMode {
    return this.currentMode;
  }

  getModeInterval(): number {
    return MODE_CONFIG[this.currentMode].timeInterval;
  }

  private isDistanceTriggered(): boolean {
    return MODE_CONFIG[this.currentMode].distanceInterval > 0;
  }

  private buildLocationRequest(interval?: number): geoLocationManager.LocationRequest {
    let config = MODE_CONFIG[this.currentMode];
    let scenario: geoLocationManager.LocationRequestScenario;
    if (this.currentMode === RecordMode.HIGH_POWER) {
      scenario = geoLocationManager.LocationRequestScenario.NAVIGATION; // 导航级高频上报
    } else if (this.currentMode === RecordMode.POWER_SAVING || this.currentMode === RecordMode.SMART) {
      scenario = geoLocationManager.LocationRequestScenario.DAILY_LIFE_SERVICE; // 日常服务低频上报
    } else {
      scenario = geoLocationManager.LocationRequestScenario.TRAJECTORY_TRACKING; // 轨迹追踪按间隔上报
    }
    if (this.isDistanceTriggered()) {
      return {
        priority: geoLocationManager.LocationRequestPriority.ACCURACY,
        scenario: scenario,
        timeInterval: config.timeInterval,
        distanceInterval: 0,
        maxAccuracy: 0
      };
    }
    return {
      priority: geoLocationManager.LocationRequestPriority.ACCURACY,
      scenario: scenario,
      timeInterval: interval ?? config.timeInterval,
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
    this.lastRecordedTime = 0;
    this.locationCallback = (location: geoLocationManager.Location) => {
      map.convertCoordinate(
        mapCommon.CoordinateType.WGS84,
        mapCommon.CoordinateType.GCJ02,
        { latitude: location.latitude, longitude: location.longitude }
      ).then((gcj02: mapCommon.LatLng) => {
        if (this.isDistanceTriggered()) {
          this.handleDistanceTriggeredFix(gcj02, location.accuracy, location.speed, handlers);
        } else {
          this.handlePollingModeFix(gcj02, location.accuracy, location.speed, handlers);
        }
      });
    };
    geoLocationManager.on('locationChange', this.buildLocationRequest(), this.locationCallback);
    console.info(TAG, 'Location change listener registered');
  }

  private handleDistanceTriggeredFix(
    gcj02: mapCommon.LatLng, accuracy: number, speed: number | undefined,
    handlers: LocationHandlers
  ): void {
    let now: number = Date.now();
    let speedVal: number = speed !== undefined ? speed : 0;
    if (speedVal < STATIONARY_SPEED && this.lastRecordedPoint !== null) {
      return;
    }
    if (this.lastRecordedPoint === null) {
      this.lastRecordedPoint = gcj02;
      this.lastRecordedTime = now;
      handlers.onSample(gcj02, accuracy, speedVal);
      return;
    }
    let dist: number = calculateDistance(gcj02, this.lastRecordedPoint);
    let elapsed: number = now - this.lastRecordedTime;
    let config = MODE_CONFIG[this.currentMode];
    if (dist >= config.distanceInterval || elapsed >= config.timeInterval * 1000) {
      this.lastRecordedPoint = gcj02;
      this.lastRecordedTime = now;
      handlers.onSample(gcj02, accuracy, speedVal);
    }
  }

  private handlePollingModeFix(
    gcj02: mapCommon.LatLng, accuracy: number, speed: number | undefined,
    handlers: LocationHandlers
  ): void {
    this.recentPoints.push(gcj02);
    if (this.recentPoints.length > STATIONARY_WINDOW) {
      this.recentPoints.shift();
    }
    if (this.detectStationary()) {
      if (!this.isStationary) {
        this.isStationary = true;
        this.switchLocationInterval(Math.max(STATIONARY_INTERVAL, this.getModeInterval()));
      }
      return;
    }
    if (this.isStationary) {
      let centroid: mapCommon.LatLng | null = this.getRecentCentroid();
      if (centroid !== null && calculateDistance(gcj02, centroid) < STATIONARY_EXIT_RADIUS) {
        return;
      }
      this.isStationary = false;
      this.switchLocationInterval(this.getModeInterval());
    }
    let speedVal: number = speed !== undefined ? speed : 0;
    handlers.onSample(gcj02, accuracy, speedVal);
  }

  // 停止定位订阅：注销监听
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
  }

  switchMode(mode: number): void {
    if (mode < 0 || mode >= MODE_CONFIG.length) {
      return;
    }
    this.currentMode = mode as RecordMode;
    if (!this.isStationary) {
      this.switchLocationInterval(this.getModeInterval());
    }
    console.info(TAG, `Record mode switched to ${MODE_CONFIG[this.currentMode].label}`);
  }

  private switchLocationInterval(interval: number): void {
    if (!this.locationCallback) {
      return;
    }
    try {
      geoLocationManager.off('locationChange', this.locationCallback);
      geoLocationManager.on('locationChange', this.buildLocationRequest(interval), this.locationCallback);
      console.info(TAG, `Location interval switched to ${interval}s`);
    } catch (err) {
      let error = err as BusinessError;
      console.error(`switchLocationInterval failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 静止检测：最近窗口内所有点到质心的最大距离 < STATIONARY_RADIUS 则判定为静止
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
    let centroid: mapCommon.LatLng = {
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

  // 计算最近定位窗口的质心（用于静止退出迟滞与簇心过滤），窗口不足 2 点时返回 null
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
