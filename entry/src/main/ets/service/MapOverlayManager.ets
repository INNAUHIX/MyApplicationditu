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
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  TIME_VIEW_OVERVIEW,
  MAP_STYLE_DARK_ID,
  MAP_STYLE_LIGHT_ID,
  TRACK_COLORS,
  TAG
} from '../model/TrackTypes';

const TAG_LOG: string = 'MapOverlay';

export class MapOverlayManager {
  private mapController?: map.MapComponentController;
  private trackPolyline: map.MapPolyline | null = null;
  private massPointOverlay: map.MassPointOverlay | null = null;
  private redDotIcon: image.PixelMap | null = null;
  private mapEventManager?: map.MapEventManager;

  private navBarHeight: number = 0;
  private statusBarHeight: number = 0;
  private initialMapStyleIndex: number = 0;
  private currentTrackColor: number = TRACK_COLORS[0].color;
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
      pixelFormat: image.PixelMapFormat.BGRA_8888,
      size: imageSize
    };
    const initBuffer: ArrayBuffer = new ArrayBuffer(size * size * 4);
    const pixelMap = await image.createPixelMap(initBuffer, imageOptions);
    const buffer: ArrayBuffer = new ArrayBuffer(size * size * 4);
    const imageData = new Uint8Array(buffer);
    const center = size / 2;
    const radius = size / 2 - 1;
    // 将传入的 ARGB 颜色（0xAARRGGBB）拆分为 R/G/B/A 分量
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
          // 地图渲染管线内部将 PixelMap 数据以 RGBA 顺序上传纹理，
          // 此处写入 RGBA 顺序：R, G, B, A，补偿渲染管线的通道解译差异
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

  buildMapOptions(mapStyleIndex: number): mapCommon.MapOptions {
    const initialDayNight: mapCommon.DayNightMode =
      (mapStyleIndex === 2 || mapStyleIndex === 3) ? mapCommon.DayNightMode.DAY : mapCommon.DayNightMode.NIGHT;
    const initialStyleId: string | undefined =
      mapStyleIndex === 1 ? MAP_STYLE_DARK_ID :
      mapStyleIndex === 2 ? MAP_STYLE_LIGHT_ID : undefined;
    return {
      position: {
        target: {
          latitude: 39.9,
          longitude: 116.4
        },
        zoom: 15
      },
      myLocationControlsEnabled: false,
      scaleControlsEnabled: true,
      compassControlsEnabled: false,
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
  buildMapCallback(onMapReady: () => void, onMapClick: () => void, onCameraGesture: () => void): AsyncCallback<map.MapComponentController> {
    return async (err: BusinessError | undefined, mapController: map.MapComponentController) => {
      if (!err) {
        this.mapController = mapController;

        this.mapController.setPadding({
          left: 0,
          top: 0,
          right: 0,
          bottom: this.navBarHeight + 90
        });

        this.mapController.setZoomControlsEnabled(false);

        try {
          this.mapController.setApproveNumberEnabled(false);
        } catch (e) {
          hilog.error(0x0000, TAG_LOG, 'setApproveNumberEnabled failed: %{public}s', JSON.stringify(e));
        }

        hilog.info(0x0000, TAG_LOG, 'Map initialized successfully');

        this.mapEventManager = this.mapController.getEventManager();
        this.mapEventManager.on('mapClick', () => {
          onMapClick();
        });
        this.mapEventManager.on('cameraMoveStart', (reason: number) => {
          if (reason === 1) {
            onCameraGesture();
          }
        });

        this.enable3DBuilding();
        this.applyMapStyle(this.initialMapStyleIndex);
        onMapReady();
      } else {
        hilog.error(0x0000, TAG_LOG, 'Failed to initialize the map, code: %{public}s, message: %{public}s', err.code.toString(), err.message.toString());
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
      hilog.info(0x0000, TAG_LOG, '3D building enabled');
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'Failed to enable 3D building, code: %{public}s, message: %{public}s', error.code.toString(), error.message.toString());
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

  // 应用轨迹颜色：重新生成海量点图标 + 重建折线颜色
  async applyTrackColor(colorIndex: number, displayMode: number,
    trackPoints: mapCommon.LatLng[], footprintPoints: mapCommon.LatLng[]): Promise<void> {
    this.currentTrackColor = TRACK_COLORS[colorIndex].color;
    await this.createRedDotIcon(this.currentTrackColor);
    this.rebuildOverlay(displayMode, trackPoints, footprintPoints);
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
        width: 6,
        color: this.currentTrackColor,
        geodesic: false
      };
      this.mapController?.addPolyline(polylineOption).then((polyline) => {
        if (polyline) {
          this.trackPolyline = polyline;
        }
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, TAG_LOG, 'addPolyline failed, code: %{public}s, message: %{public}s', err.code.toString(), err.message.toString());
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
      hilog.warn(0x0000, TAG_LOG, 'redDotIcon is not ready');
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
        hilog.error(0x0000, TAG_LOG, 'addMassPointOverlay failed, code: %{public}s, message: %{public}s', err.code.toString(), err.message.toString());
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
      hilog.warn(0x0000, TAG_LOG, 'mapController is null, night mode applies after map ready');
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
      hilog.info(0x0000, TAG_LOG, 'Day night mode set to %{public}s', mode.toString());
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'Failed to set day night mode, code: %{public}s, message: %{public}s', error.code.toString(), error.message.toString());
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
        hilog.info(0x0000, TAG_LOG, 'Dark night map style applied');
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, TAG_LOG, 'setCustomMapStyle failed, code: %{public}s, message: %{public}s', err.code.toString(), err.message.toString());
      });
    } else if (index === 2) {
      // 浅白样式：固定白天模式 + 套用自定义浅白样式
      controller.setDayNightMode(mapCommon.DayNightMode.DAY);
      const param: mapCommon.CustomMapStyleOptions = {
        styleId: MAP_STYLE_LIGHT_ID
      };
      controller.setCustomMapStyle(param).then(() => {
        hilog.info(0x0000, TAG_LOG, 'Light map style applied');
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, TAG_LOG, 'setCustomMapStyle failed, code: %{public}s, message: %{public}s', err.code.toString(), err.message.toString());
      });
    } else if (index === 3) {
      // 大白样式：固定白天模式 + 套用本地自定义浅色极简样式（从 rawfile 读取 JSON 字符串注入）
      controller.setDayNightMode(mapCommon.DayNightMode.DAY);
      const styleContent: string = this.readMapStyleTestJson();
      const param: mapCommon.CustomMapStyleOptions = { styleContent: styleContent };
      controller.setCustomMapStyle(param).then(() => {
        hilog.info(0x0000, TAG_LOG, 'Dabai map style applied');
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, TAG_LOG, 'setCustomMapStyle failed, code: %{public}s, message: %{public}s', err.code.toString(), err.message.toString());
      });
    } else {
      // 经典样式：清空自定义样式（空内容覆盖），退回内置样式
      const param: mapCommon.CustomMapStyleOptions = { styleContent: '[]' };
      controller.setCustomMapStyle(param).then(() => {
        hilog.info(0x0000, TAG_LOG, 'Classic map style applied');
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, TAG_LOG, 'setCustomMapStyle failed, code: %{public}s, message: %{public}s', err.code.toString(), err.message.toString());
      });
    }
  }

  // 从 rawfile 同步读取地图大白样式 JSON 字符串
  private readMapStyleTestJson(): string {
    if (!this.context) {
      hilog.error(0x0000, TAG_LOG, 'readMapStyleTestJson: context is null');
      return '[]';
    }
    try {
      const rawContent: Uint8Array = this.context.resourceManager.getRawFileContentSync('map_style_test.json');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(rawContent);
    } catch (e) {
      hilog.error(0x0000, TAG_LOG, 'readMapStyleTestJson failed: %{public}s', JSON.stringify(e));
      return '[]';
    }
  }
}
