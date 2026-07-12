/**
 * MapOverlayManager.ets —— 地图覆盖物与样式管理服务
 *
 * 从 Index 原 createRedDotIcon / initMapOptions / initMapCallback / enable3DBuilding /
 * rebuildOverlay / updatePolyline / updateLivePolyline / buildMassPointItems /
 * updateMassPointOverlay / refreshOverlayOptimized / switchDisplayMode / applyNightMode /
 * applyMapStyleToMap 抽取。
 * 持有 mapController 与全部覆盖物引用、红点图标、绘制节流计数，提供纯数据入参的覆盖物
 * 刷新与样式/昼夜切换接口；沉浸模式、Tab 动画等 UI 行为通过回调交还页面处理。
 */

import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { MAP_STYLE_TEST } from '../pages/MapStyleTest';
import {
  TIME_VIEW_OVERVIEW,
  MAP_STYLE_DARK_ID,
  MAP_STYLE_LIGHT_ID,
  POLYLINE_UPDATE_POINT_GAP,
  FOOTPRINT_UPDATE_POINT_GAP,
  OVERLAY_UPDATE_INTERVAL,
  TAG
} from '../model/TrackTypes';

export class MapOverlayManager {
  private mapController?: map.MapComponentController;
  private trackPolyline: map.MapPolyline | null = null;
  private massPointOverlay: map.MassPointOverlay | null = null;
  // 实时位置连线：把已确认折线末端连到当前实时位置，消除「已确认点 → 真实位置」之间的空白与终点断点
  private livePolyline: map.MapPolyline | null = null;
  private redDotIcon: image.PixelMap | null = null;
  private mapEventManager?: map.MapEventManager;

  // 页面侧展示相关尺寸，供初始回调内 setPadding / 指南针定位使用
  private navBarHeight: number = 0;
  private statusBarHeight: number = 0;
  private initialMapStyleIndex: number = 0;

  // 覆盖物节流刷新计数/时间戳
  private lastPolylineUpdatePointCount: number = 0;
  private lastFootprintUpdateCount: number = 0;
  private lastOverlayUpdateTs: number = 0;

  get controller(): map.MapComponentController | undefined {
    return this.mapController;
  }

  get redDot(): image.PixelMap | null {
    return this.redDotIcon;
  }

  setLayoutMeta(navBarHeight: number, statusBarHeight: number): void {
    this.navBarHeight = navBarHeight;
    this.statusBarHeight = statusBarHeight;
  }

  setInitialMapStyle(index: number): void {
    this.initialMapStyleIndex = index;
  }

  setController(controller: map.MapComponentController): void {
    this.mapController = controller;
  }

  // 用 PixelMap 以代码绘制一个 12x12 的红色实心圆点，作为「足迹」海量点的图标（无需图片资源）
  async createRedDotIcon(): Promise<void> {
    let size: number = 12;
    let imageSize: image.Size = { height: size, width: size };
    let imageOptions: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.BGRA_8888,
      size: imageSize
    };
    let buffer: ArrayBuffer = new ArrayBuffer(size * size * 4);
    let pixelMap = await image.createPixelMap(buffer, imageOptions);
    let imageData = new Uint8Array(buffer);
    let center = size / 2;
    let radius = size / 2 - 1;
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        let dx = x - center;
        let dy = y - center;
        let dist = Math.sqrt(dx * dx + dy * dy);
        let offset = (y * size + x) * 4;
        if (dist <= radius) {
          imageData[offset] = 255;
          imageData[offset + 1] = 0;
          imageData[offset + 2] = 0;
          imageData[offset + 3] = 255;
        } else {
          imageData[offset] = 0;
          imageData[offset + 1] = 0;
          imageData[offset + 2] = 0;
          imageData[offset + 3] = 0;
        }
      }
    }
    await pixelMap.writeBufferToPixels(imageData.buffer);
    this.redDotIcon = pixelMap;
  }

  // 初始化地图初始参数：按已保存的地图样式在初始化阶段就预置 dayNightMode 与 styleId，让首帧直接对
  buildMapOptions(mapStyleIndex: number): mapCommon.MapOptions {
    let initialDayNight: mapCommon.DayNightMode =
      (mapStyleIndex === 2 || mapStyleIndex === 3) ? mapCommon.DayNightMode.DAY : mapCommon.DayNightMode.NIGHT;
    let initialStyleId: string | undefined =
      mapStyleIndex === 1 ? MAP_STYLE_DARK_ID :
      mapStyleIndex === 2 ? MAP_STYLE_LIGHT_ID : undefined;
    return {
      position: {
        target: {
          latitude: 39.9,
          longitude: 116.4
        },
        zoom: 10
      },
      myLocationControlsEnabled: true,
      scaleControlsEnabled: true,
      compassControlsEnabled: true,
      zoomControlsEnabled: false,
      tiltGesturesEnabled: true,
      rotateGesturesEnabled: true,
      sphereEnabled: true,
      dayNightMode: initialDayNight,
      styleId: initialStyleId
    };
  }

  // 构造地图初始化回调：地图就绪后保存 controller、设置留白/控件、开启 3D、定位首帧样式，
  // 并通过 onMapClick / onMapReady 把交互与后续编排交还页面
  buildMapCallback(onMapReady: () => void, onMapClick: () => void): AsyncCallback<map.MapComponentController> {
    return async (err: BusinessError | undefined, mapController: map.MapComponentController) => {
      if (!err) {
        this.mapController = mapController;

        // 底部留白：将缩放控件、"我的位置"按钮整体顶到悬浮 tab 栏上方，避免被遮挡
        this.mapController.setPadding({
          left: 0,
          top: 0,
          right: 0,
          bottom: this.navBarHeight + 90
        });

        // 关闭系统缩放控件（initMapOptions 已设 zoomControlsEnabled=false，这里再次确保运行时关闭）
        this.mapController.setZoomControlsEnabled(false);

        // 关闭地图自带的审图号
        try {
          this.mapController.setApproveNumberEnabled(false);
        } catch (e) {
          console.error(TAG, `setApproveNumberEnabled failed: ${JSON.stringify(e)}`);
        }

        console.info(TAG, 'Map initialized successfully');

        // 点击地图空白区域切换沉浸模式：交给页面处理（涉及 immersive / tabs / padding）
        this.mapEventManager = this.mapController.getEventManager();
        this.mapEventManager.on('mapClick', () => {
          onMapClick();
        });

        this.enable3DBuilding();
        // 地图就绪后按已存（或默认）的样式强制应用一次，确保重进后保持上次选择
        this.applyMapStyle(this.initialMapStyleIndex);
        onMapReady();
      } else {
        console.error(`Failed to initialize the map, code: ${err.code}, message: ${err.message}`);
      }
    };
  }

  // 开启地图 3D 建筑显示效果
  enable3DBuilding(): void {
    if (!this.mapController) {
      return;
    }
    try {
      this.mapController.setBuildingEnabled(true);
      console.info(TAG, '3D building enabled');
    } catch (err) {
      let error = err as BusinessError;
      console.error(`Failed to enable 3D building, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 设置地图底部留白（沉浸模式时仅避让导航条，否则抬到 tab 栏上方）
  setBottomPadding(immersive: boolean): void {
    if (!this.mapController) {
      return;
    }
    this.mapController.setPadding({
      left: 0,
      top: 0,
      right: 0,
      bottom: immersive ? this.navBarHeight : this.navBarHeight + 90
    });
  }

  // 移除现有覆盖物并依据当前展示模式重建（基于可见集 trackPoints / footprintPoints）
  rebuildOverlay(displayMode: number, trackPoints: mapCommon.LatLng[], footprintPoints: mapCommon.LatLng[],
    liveLocation: mapCommon.LatLng | null): void {
    if (this.trackPolyline) {
      this.trackPolyline.remove();
      this.trackPolyline = null;
    }
    if (this.massPointOverlay) {
      this.massPointOverlay.remove();
      this.massPointOverlay = null;
    }
    if (this.livePolyline) {
      this.livePolyline.remove();
      this.livePolyline = null;
    }
    if (trackPoints.length === 0) {
      return;
    }
    if (displayMode === 0) {
      this.updatePolyline(trackPoints);
      this.updateLivePolyline(liveLocation, displayMode, trackPoints);
    } else {
      this.updateMassPointOverlay(footprintPoints);
    }
  }

  private updatePolyline(trackPoints: mapCommon.LatLng[]): void {
    if (!this.trackPolyline) {
      let polylineOption: mapCommon.MapPolylineOptions = {
        points: trackPoints,
        width: 6,
        color: 0xFFFF0000,
        geodesic: false
      };
      this.mapController?.addPolyline(polylineOption).then((polyline) => {
        if (polyline) {
          this.trackPolyline = polyline;
        }
      }).catch((err: BusinessError) => {
        console.error(`addPolyline failed, code: ${err.code}, message: ${err.message}`);
      });
    } else {
      this.trackPolyline.setPoints(trackPoints);
    }
    // 同步节流计数：本次已把全部折线点刷新到地图
    this.lastPolylineUpdatePointCount = trackPoints.length;
  }

  // 实时连线：把已确认折线的末端连到当前实时位置 liveLocation，让红线始终延伸到脚下
  updateLivePolyline(liveLocation: mapCommon.LatLng | null, displayMode: number,
    trackPoints: mapCommon.LatLng[]): void {
    if (!liveLocation || displayMode !== 0) {
      return;
    }
    // 尚无任何确认点、或实时位置与末端确认点几乎重合（已停下）时不成线，避免零长线段
    if (trackPoints.length === 0) {
      return;
    }
    let lastConfirmed: mapCommon.LatLng = trackPoints[trackPoints.length - 1];
    let dx = lastConfirmed.latitude - liveLocation.latitude;
    let dy = lastConfirmed.longitude - liveLocation.longitude;
    if (Math.sqrt(dx * dx + dy * dy) * 6371000 * Math.PI / 180 < 1) {
      return;
    }
    let points: mapCommon.LatLng[] = [lastConfirmed, liveLocation];
    if (!this.livePolyline) {
      let option: mapCommon.MapPolylineOptions = {
        points: points,
        width: 6,
        color: 0xFFFF0000,
        geodesic: false
      };
      this.mapController?.addPolyline(option).then((polyline) => {
        if (polyline) {
          this.livePolyline = polyline;
        }
      }).catch((err: BusinessError) => {
        console.error(`addLivePolyline failed, code: ${err.code}, message: ${err.message}`);
      });
    } else {
      this.livePolyline.setPoints(points);
    }
  }

  // 将 footprintPoints 转换为海量点所需的 MassPointItem 数组
  private buildMassPointItems(footprintPoints: mapCommon.LatLng[]): mapCommon.MassPointItem[] {
    let items: mapCommon.MassPointItem[] = [];
    for (let i = 0; i < footprintPoints.length; i++) {
      let item: mapCommon.MassPointItem = {
        itemId: `footprint_${i}`,
        position: footprintPoints[i],
        title: `足迹${i + 1}`
      };
      items.push(item);
    }
    return items;
  }

  // 海量点模式：首次创建红色圆点覆盖物，之后仅 setItems 增量更新
  private updateMassPointOverlay(footprintPoints: mapCommon.LatLng[]): void {
    if (!this.redDotIcon) {
      console.warn(TAG, 'redDotIcon is not ready');
      return;
    }
    if (!this.massPointOverlay) {
      let params: mapCommon.MassPointOverlayParams = {
        id: 'footprint_overlay',
        items: this.buildMassPointItems(footprintPoints),
        icon: this.redDotIcon
      };
      this.mapController?.addMassPointOverlay(params).then((overlay) => {
        if (overlay) {
          this.massPointOverlay = overlay;
        }
      }).catch((err: BusinessError) => {
        console.error(`addMassPointOverlay failed, code: ${err.code}, message: ${err.message}`);
      });
    } else {
      this.massPointOverlay.setItems(this.buildMassPointItems(footprintPoints));
    }
    // 同步节流计数：本次已把全部足迹点刷新到地图
    this.lastFootprintUpdateCount = footprintPoints.length;
  }

  // 覆盖物节流刷新（折线 / 足迹点海量点）：按展示模式分别判断「新增点数」与「距上次刷新时间」，
  // 任一达标才真正刷新；MapPolyline.setPoints / MassPointOverlay.setItems 仅支持整体替换，故为降频整体刷新
  refreshOverlayOptimized(displayMode: number, trackPoints: mapCommon.LatLng[],
    footprintPoints: mapCommon.LatLng[]): void {
    let now: number = Math.floor(Date.now() / 1000);
    if (displayMode === 0) {
      let gap: number = trackPoints.length - this.lastPolylineUpdatePointCount;
      if (gap < POLYLINE_UPDATE_POINT_GAP && (now - this.lastOverlayUpdateTs) < OVERLAY_UPDATE_INTERVAL) {
        return;
      }
      this.updatePolyline(trackPoints);
    } else {
      let gap: number = footprintPoints.length - this.lastFootprintUpdateCount;
      if (gap < FOOTPRINT_UPDATE_POINT_GAP && (now - this.lastOverlayUpdateTs) < OVERLAY_UPDATE_INTERVAL) {
        return;
      }
      this.updateMassPointOverlay(footprintPoints);
    }
    this.lastOverlayUpdateTs = now;
  }

  // 重置覆盖物节流计数（applyTimeView / clearTrack 后强制整体重绘）
  resetOverlayThrottle(): void {
    this.lastPolylineUpdatePointCount = 0;
    this.lastFootprintUpdateCount = 0;
    this.lastOverlayUpdateTs = 0;
  }

  // 切换展示模式(0 折线 / 1 海量点)：移除另一种模式的覆盖物，并重建当前模式
  switchDisplayMode(mode: number, timeViewIndex: number, trackPoints: mapCommon.LatLng[],
    footprintPoints: mapCommon.LatLng[], liveLocation: mapCommon.LatLng | null): void {
    // 总览视图仅支持海量点（避免跨天连线杂乱、卡顿），禁止切到折线
    if (timeViewIndex === TIME_VIEW_OVERVIEW && mode === 0) {
      return;
    }
    if (mode === 0) {
      if (this.massPointOverlay) {
        this.massPointOverlay.remove();
        this.massPointOverlay = null;
      }
      if (trackPoints.length > 0) {
        this.updatePolyline(trackPoints);
        this.updateLivePolyline(liveLocation, mode, trackPoints);
      }
    } else {
      if (this.trackPolyline) {
        this.trackPolyline.remove();
        this.trackPolyline = null;
      }
      if (this.livePolyline) {
        this.livePolyline.remove();
        this.livePolyline = null;
      }
      if (trackPoints.length > 0) {
        this.updateMassPointOverlay(footprintPoints);
      }
    }
  }

  // 清空全部地图覆盖物
  clearOverlays(): void {
    if (this.trackPolyline) {
      this.trackPolyline.remove();
      this.trackPolyline = null;
    }
    if (this.massPointOverlay) {
      this.massPointOverlay.remove();
      this.massPointOverlay = null;
    }
    if (this.livePolyline) {
      this.livePolyline.remove();
      this.livePolyline = null;
    }
  }

  // 根据 nightModeIndex(0 跟随系统 /1 普通 /2 夜间) 设置地图日夜模式
  applyNightMode(index: number): void {
    if (!this.mapController) {
      console.warn(TAG, 'mapController is null, night mode applies after map ready');
      return;
    }
    let mode: mapCommon.DayNightMode;
    switch (index) {
      case 1:
        mode = mapCommon.DayNightMode.DAY;
        break;
      case 2:
        mode = mapCommon.DayNightMode.NIGHT;
        break;
      default:
        mode = mapCommon.DayNightMode.AUTO;
    }
    try {
      this.mapController.setDayNightMode(mode);
      console.info(TAG, `Day night mode set to ${mode}`);
    } catch (err) {
      let error = err as BusinessError;
      console.error(`Failed to set day night mode, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 将指定地图样式应用到地图（与 switchMapStyle 解耦，供地图就绪后按已存值强制应用）
  applyMapStyle(index: number): void {
    if (!this.mapController) {
      return;
    }
    // 用局部常量承接，避免闭包内 this.mapController 被判定为 possibly 'undefined'
    let controller: map.MapComponentController = this.mapController;
    if (index === 1) {
      // 暗夜样式：固定夜间模式 + 套用自定义暗夜样式
      controller.setDayNightMode(mapCommon.DayNightMode.NIGHT);
      let param: mapCommon.CustomMapStyleOptions = {
        styleId: MAP_STYLE_DARK_ID
      };
      controller.setCustomMapStyle(param).then(() => {
        console.info(TAG, 'Dark night map style applied');
      }).catch((err: BusinessError) => {
        console.error(`setCustomMapStyle failed, code: ${err.code}, message: ${err.message}`);
      });
    } else if (index === 2) {
      // 浅白样式：固定白天模式 + 套用自定义浅白样式
      controller.setDayNightMode(mapCommon.DayNightMode.DAY);
      let param: mapCommon.CustomMapStyleOptions = {
        styleId: MAP_STYLE_LIGHT_ID
      };
      controller.setCustomMapStyle(param).then(() => {
        console.info(TAG, 'Light map style applied');
      }).catch((err: BusinessError) => {
        console.error(`setCustomMapStyle failed, code: ${err.code}, message: ${err.message}`);
      });
    } else if (index === 3) {
      // 测试样式：固定白天模式 + 套用本地自定义浅色极简样式（JSON 字符串注入）
      controller.setDayNightMode(mapCommon.DayNightMode.DAY);
      let param: mapCommon.CustomMapStyleOptions = { styleContent: MAP_STYLE_TEST };
      controller.setCustomMapStyle(param).then(() => {
        console.info(TAG, 'Test map style applied');
      }).catch((err: BusinessError) => {
        console.error(`setCustomMapStyle failed, code: ${err.code}, message: ${err.message}`);
      });
    } else {
      // 经典样式：清空自定义样式（空内容覆盖），退回内置样式
      let param: mapCommon.CustomMapStyleOptions = { styleContent: '[]' };
      controller.setCustomMapStyle(param).then(() => {
        console.info(TAG, 'Classic map style applied');
      }).catch((err: BusinessError) => {
        console.error(`setCustomMapStyle failed, code: ${err.code}, message: ${err.message}`);
      });
    }
  }
}
