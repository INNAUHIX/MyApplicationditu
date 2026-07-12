/**
 * TrackLocationService.ets —— 实时定位与轨迹采样服务
 *
 * 从 Index 原 enableMyLocation 的定位订阅回调、detectStationary / getRecentCentroid /
 * getModeInterval / switchMode / switchLocationInterval 抽取。
 * 职责：WGS84→GCJ02 转换、最近窗口驻留检测（防漂移）、按档位切换定位频率、
 * 精度过滤，最终把「干净采样点」通过回调 onSample 交给页面做后续记录。
 * 不持有地图 controller 与轨迹点数组，保持与 UI / 地图解耦。
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
  TAG
} from '../model/TrackTypes';

// 干净采样点回调：经转换 / 驻留 / 精度过滤后的点（accuracy / speed 原样透传）
export interface LocationHandlers {
  onSample: (latLng: mapCommon.LatLng, accuracy: number, speed: number) => void;
}

export class TrackLocationService {
  private recentPoints: mapCommon.LatLng[] = [];
  private isStationary: boolean = false;
  private currentMode: RecordMode = RecordMode.BALANCED;
  private locationCallback?: (location: geoLocationManager.Location) => void;

  get stationary(): boolean {
    return this.isStationary;
  }

  get mode(): RecordMode {
    return this.currentMode;
  }

  // 获取当前模式对应的定位回调间隔（秒）
  getModeInterval(): number {
    return MODE_CONFIG[this.currentMode].timeInterval;
  }

  // 开启定位订阅：注册 locationChange，回调内完成转换 / 驻留 / 精度过滤后回调 onSample
  startLocation(handlers: LocationHandlers): void {
    let locationRequest: geoLocationManager.LocationRequest = {
      priority: geoLocationManager.LocationRequestPriority.ACCURACY,
      scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
      timeInterval: this.getModeInterval(),
      distanceInterval: 0,
      maxAccuracy: 0
    };
    this.locationCallback = (location: geoLocationManager.Location) => {
      map.convertCoordinate(
        mapCommon.CoordinateType.WGS84,
        mapCommon.CoordinateType.GCJ02,
        { latitude: location.latitude, longitude: location.longitude }
      ).then((gcj02: mapCommon.LatLng) => {
        this.recentPoints.push(gcj02);
        if (this.recentPoints.length > STATIONARY_WINDOW) {
          this.recentPoints.shift();
        }
        // 静止检测：持续落在小范围内判定为静止，降频省电并停止记录
        if (this.detectStationary()) {
          if (!this.isStationary) {
            this.isStationary = true;
            // 静止降频：降到 30 秒或更慢，取二者较大值，避免省电档(60秒)反而变快
            this.switchLocationInterval(Math.max(STATIONARY_INTERVAL, this.getModeInterval()));
          }
          return;
        }
        // 静止退出迟滞：抖动常使 detectStationary 短暂失效，不应立刻恢复记录；
        // 仅当新点明显远离常驻簇（超过退出半径）才判为真正离开，否则仍视为原地抖动
        if (this.isStationary) {
          let centroid: mapCommon.LatLng | null = this.getRecentCentroid();
          if (centroid !== null && this.calculateCentroidDistance(gcj02, centroid) < STATIONARY_EXIT_RADIUS) {
            return;
          }
          this.isStationary = false;
          this.switchLocationInterval(this.getModeInterval());
        }
        // 精度过滤：超出当前模式精度门槛的漂移点整体丢弃（折线/足迹点都不记）
        if (location.accuracy > MODE_CONFIG[this.currentMode].maxAccuracy) {
          return;
        }
        let speed: number = location.speed !== undefined ? location.speed : 0;
        handlers.onSample(gcj02, location.accuracy, speed);
      });
    };
    geoLocationManager.on('locationChange', locationRequest, this.locationCallback);
    console.info(TAG, 'Location change listener registered');
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

  // 切换定位记录模式：更新 currentMode 并重新注册定位监听（静止状态下保持静止间隔，避免打断降频）
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

  // 切换定位频率：注销旧监听，以新间隔重新注册
  private switchLocationInterval(interval: number): void {
    if (!this.locationCallback) {
      return;
    }
    try {
      geoLocationManager.off('locationChange', this.locationCallback);
      let locationRequest: geoLocationManager.LocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.ACCURACY,
        scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
        timeInterval: interval,
        distanceInterval: 0,
        maxAccuracy: 0
      };
      geoLocationManager.on('locationChange', locationRequest, this.locationCallback);
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
      if (this.calculateCentroidDistance(point, centroid) >= STATIONARY_RADIUS) {
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

  // 两点距离（Haversine），用于静止簇心判断
  private calculateCentroidDistance(from: mapCommon.LatLng, to: mapCommon.LatLng): number {
    let R: number = 6371000;
    let dLat: number = (to.latitude - from.latitude) * Math.PI / 180;
    let dLon: number = (to.longitude - from.longitude) * Math.PI / 180;
    let a: number = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(from.latitude * Math.PI / 180) * Math.cos(to.latitude * Math.PI / 180) *
      Math.sin(dLon / 2) * Math.sin(dLon / 2);
    let c: number = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
  }
}
