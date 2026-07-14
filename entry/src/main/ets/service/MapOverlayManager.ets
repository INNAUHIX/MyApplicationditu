/**
 * MapOverlayManager.ets —— 地图覆盖物与样式管理服务
 *
 * 从 Index 原 createRedDotIcon / initMapOptions / initMapCallback / enable3DBuilding /
 * rebuildOverlay / updatePolyline / buildMassPointItems /
 * updateMassPointOverlay / refreshOverlay / switchDisplayMode / applyNightMode /
 * applyMapStyleToMap 抽取。
 * 持有 mapController 与全部覆盖物引用、红点图标、绘制节流计数，提供纯数据入参的覆盖物
 * 刷新与样式/昼夜切换接口；沉浸模式、Tab 动画等 UI 行为通过回调交还页面处理。
 *
 * 已删除策略：实时连线（livePolyline + updateLivePolyline 已移除）
 */

import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import {
  TIME_VIEW_OVERVIEW,
  MAP_STYLE_DARK_ID,
  MAP_STYLE_LIGHT_ID,

  TAG
} from '../model/TrackTypes';

export class MapOverlayManager {
  private mapController?: map.MapComponentController;
  private trackPolyline: map.MapPolyline | null = null;
  private massPointOverlay: map.MassPointOverlay | null = null;
  private redDotIcon: image.PixelMap | null = null;
  private mapEventManager?: map.MapEventManager;

  private navBarHeight: number = 0;
  private statusBarHeight: number = 0;
  private initialMapStyleIndex: number = 0;
  private context?: common.UIAbilityContext;


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

  setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  setController(controller: map.MapComponentController): void {
    this.mapController = controller;
  }

  // 用 PixelMap 以代码绘制一个实心圆点，作为「足迹」海量点的图标（无需图片资源）。
  // color 为 ARGB 格式（0xAARRGGBB），size 为像素直径；均带默认值，当前为 9px 红色，
  // 未来支持用户自定义颜色/大小时直接传参即可，无需改动调用方。
  async createRedDotIcon(color: number = 0xFFFF0000, size: number = 9): Promise<void> {
    const imageSize: image.Size = { height: size, width: size };
    const imageOptions: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: imageSize
    };
    const buffer: ArrayBuffer = new ArrayBuffer(size * size * 4);
    const pixelMap = await image.createPixelMap(buffer, imageOptions);
    const imageData = new Uint8Array(buffer);
    const center = size / 2;
    const radius = size / 2 - 1;
    const alpha: number = (color >> 24) & 0xFF;
    const red: number = (color >> 16) & 0xFF;
    const green: number = (color >> 8) & 0xFF;
    const blue: number = color & 0xFF;
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const dx = x - center;
        const dy = y - center;
        const dist = Math.sqrt(dx * dx + dy * dy);
        const offset = (y * size + x) * 4;
        if (dist <= radius) {
          imageData[offset] = red;
          imageData[offset + 1] = green;
          imageData[offset + 2] = blue;
          imageData[offset + 3] = alpha;
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
    const initialDayNight: mapCommon.DayNightMode =
      (mapStyleIndex === 2 || mapStyleIndex === 3) ? mapCommon.DayNightMode.DAY : mapCommon.DayNightMode.AUTO;
    const initialStyleId: string | undefined =
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

        // 底部留白：仅避让系统导航条（状态栏/底部 Tab 由浮层与页面布局处理）
        this.mapController.setPadding({
          left: 0,
          top: 0,
          right: 0,
          bottom: this.navBarHeight
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
      const error = err as BusinessError;
      console.error(`Failed to enable 3D building, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 设置地图底部留白（仅避让系统导航条；普通/沉浸模式保持一致，避免控件跳动）
  setBottomPadding(immersive: boolean): void {
    if (!this.mapController) {
      return;
    }
    this.mapController.setPadding({
      left: 0,
      top: 0,
      right: 0,
      bottom: this.navBarHeight
    });
  }

  // 移除现有覆盖物并依据当前展示模式重建（基于可见集 trackPoints / footprintPoints）
  rebuildOverlay(displayMode: number, trackPoints: mapCommon.LatLng[], footprintPoints: mapCommon.LatLng[]): void {
    if (this.trackPolyline) {
      this.trackPolyline.remove();
      this.trackPolyline = null;
    }
    if (this.massPointOverlay) {
      this.massPointOverlay.remove();
      this.massPointOverlay = null;
    }
    if (trackPoints.length === 0) {
      return;
    }
    if (displayMode === 0) {
      this.updatePolyline(trackPoints);
    } else {
      this.updateMassPointOverlay(footprintPoints);
    }
  }

  private updatePolyline(trackPoints: mapCommon.LatLng[]): void {
    if (!this.trackPolyline) {
      const polylineOption: mapCommon.MapPolylineOptions = {
        points: trackPoints,
        width: 8,
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

  }

  // 将 footprintPoints 转换为海量点所需的 MassPointItem 数组
  private buildMassPointItems(footprintPoints: mapCommon.LatLng[]): mapCommon.MassPointItem[] {
    const items: mapCommon.MassPointItem[] = [];
    for (let i = 0; i < footprintPoints.length; i++) {
      const item: mapCommon.MassPointItem = {
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
      const params: mapCommon.MassPointOverlayParams = {
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

  }

  // 实时刷新覆盖物：每次记录新点后直接更新地图，无节流
  refreshOverlay(displayMode: number, trackPoints: mapCommon.LatLng[],
    footprintPoints: mapCommon.LatLng[]): void {
    if (displayMode === 0) {
      this.updatePolyline(trackPoints);
    } else {
      this.updateMassPointOverlay(footprintPoints);
    }
  }

  // 切换展示模式(0 折线 / 1 海量点)：移除另一种模式的覆盖物，并重建当前模式
  switchDisplayMode(mode: number, timeViewIndex: number, trackPoints: mapCommon.LatLng[],
    footprintPoints: mapCommon.LatLng[]): void {
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
      }
    } else {
      if (this.trackPolyline) {
        this.trackPolyline.remove();
        this.trackPolyline = null;
      }
      if (footprintPoints.length > 0) {
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
      const error = err as BusinessError;
      console.error(`Failed to set day night mode, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 将指定地图样式应用到地图（与 switchMapStyle 解耦，供地图就绪后按已存值强制应用）
  applyMapStyle(index: number): void {
    if (!this.mapController) {
      return;
    }
    // 用局部常量承接，避免闭包内 this.mapController 被判定为 possibly 'undefined'
    const controller: map.MapComponentController = this.mapController;
    if (index === 1) {
      // 暗夜样式：固定夜间模式 + 套用自定义暗夜样式
      controller.setDayNightMode(mapCommon.DayNightMode.NIGHT);
      const param: mapCommon.CustomMapStyleOptions = {
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
      const param: mapCommon.CustomMapStyleOptions = {
        styleId: MAP_STYLE_LIGHT_ID
      };
      controller.setCustomMapStyle(param).then(() => {
        console.info(TAG, 'Light map style applied');
      }).catch((err: BusinessError) => {
        console.error(`setCustomMapStyle failed, code: ${err.code}, message: ${err.message}`);
      });
    } else if (index === 3) {
      // 测试样式：固定白天模式 + 套用本地自定义浅色极简样式（从 rawfile 读取 JSON 字符串注入）
      controller.setDayNightMode(mapCommon.DayNightMode.DAY);
      const styleContent: string = this.readMapStyleTestJson();
      const param: mapCommon.CustomMapStyleOptions = { styleContent: styleContent };
      controller.setCustomMapStyle(param).then(() => {
        console.info(TAG, 'Test map style applied');
      }).catch((err: BusinessError) => {
        console.error(`setCustomMapStyle failed, code: ${err.code}, message: ${err.message}`);
      });
    } else {
      // 经典样式：清空自定义样式（空内容覆盖），退回内置样式
      const param: mapCommon.CustomMapStyleOptions = { styleContent: '[]' };
      controller.setCustomMapStyle(param).then(() => {
        console.info(TAG, 'Classic map style applied');
      }).catch((err: BusinessError) => {
        console.error(`setCustomMapStyle failed, code: ${err.code}, message: ${err.message}`);
      });
    }
  }

  // 从 rawfile 同步读取地图测试样式 JSON 字符串
  private readMapStyleTestJson(): string {
    if (!this.context) {
      console.error(`${TAG} readMapStyleTestJson: context is null`);
      return '[]';
    }
    try {
      const rawContent: Uint8Array = this.context.resourceManager.getRawFileContentSync('map_style_test.json');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(rawContent);
    } catch (e) {
      console.error(`${TAG} readMapStyleTestJson failed: ${JSON.stringify(e)}`);
      return '[]';
    }
  }
}
