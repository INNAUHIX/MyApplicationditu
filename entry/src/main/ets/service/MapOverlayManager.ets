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
import { display } from '@kit.ArkUI';
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
  private initialBuildingEnabled: boolean = true;
  private initialPoiVisible: boolean = true;
  private initialRoadLabelVisible: boolean = true;
  private initialTransitVisible: boolean = true;
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

  setInitialBuildingEnabled(enabled: boolean): void {
    this.initialBuildingEnabled = enabled;
  }

  setInitialPoiVisible(visible: boolean): void {
    this.initialPoiVisible = visible;
  }

  setInitialRoadLabelVisible(visible: boolean): void {
    this.initialRoadLabelVisible = visible;
  }

  setInitialTransitVisible(visible: boolean): void {
    this.initialTransitVisible = visible;
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

        this.mapController.setScaleControlsEnabled(true);
        try {
          const disp = display.getDefaultDisplaySync();
          const density = disp.densityPixels;
          const screenHeightPx = disp.height;
          const scaleHeight = this.mapController.getScaleControlsHeight();
          const point: mapCommon.MapPoint = {
            positionX: 16 * density,
            positionY: screenHeightPx / 2 - scaleHeight / 2
          };
          this.mapController.setScalePosition(point);
          hilog.info(0x0000, TAG_LOG, 'Scale position set: x=%{public}d y=%{public}d', point.positionX, point.positionY);
        } catch (e) {
          hilog.error(0x0000, TAG_LOG, 'setScalePosition failed: %{public}s', JSON.stringify(e));
        }

        this.mapEventManager = this.mapController.getEventManager();
        this.mapEventManager.on('mapClick', () => {
          onMapClick();
        });
        this.mapEventManager.on('cameraMoveStart', (reason: number) => {
          if (reason === 1) {
            onCameraGesture();
          }
        });

        this.setBuildingEnabled(this.initialBuildingEnabled);
        this.applyMapStyle(this.initialMapStyleIndex);
        this.applyLabelVisibility(this.initialPoiVisible, this.initialRoadLabelVisible, this.initialMapStyleIndex, this.initialTransitVisible, this.initialBuildingEnabled);
        onMapReady();
      } else {
        hilog.error(0x0000, TAG_LOG, 'Failed to initialize the map, code: %{public}s, message: %{public}s', err.code.toString(), err.message.toString());
      }
    };
  }

  setBuildingEnabled(enabled: boolean): void {
    if (!this.mapController) {
      return;
    }
    try {
      this.mapController.setBuildingEnabled(enabled);
      hilog.info(0x0000, TAG_LOG, '3D building %{public}s', enabled ? 'enabled' : 'disabled');
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'Failed to set building enabled, code: %{public}s, message: %{public}s', error.code.toString(), error.message.toString());
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
      // 暗夜样式：固定夜间模式 + 套用本地自定义暗夜样式（从 rawfile 读取 JSON 字符串注入）
      controller.setDayNightMode(mapCommon.DayNightMode.NIGHT);
      const styleContent: string = this.readMapStyleDarkJson();
      const param: mapCommon.CustomMapStyleOptions = { styleContent: styleContent };
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

  private readMapStyleDarkJson(): string {
    if (!this.context) {
      hilog.error(0x0000, TAG_LOG, 'readMapStyleDarkJson: context is null');
      return '[]';
    }
    try {
      const rawContent: Uint8Array = this.context.resourceManager.getRawFileContentSync('map_style_dark.json');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(rawContent);
    } catch (e) {
      hilog.error(0x0000, TAG_LOG, 'readMapStyleDarkJson failed: %{public}s', JSON.stringify(e));
      return '[]';
    }
  }

  applyLabelVisibility(poiVisible: boolean, roadLabelVisible: boolean, mapStyleIndex: number,
    transitVisible: boolean, buildingEnabled: boolean): void {
    if (!this.mapController) {
      return;
    }
    if (mapStyleIndex === 2) {
      return;
    }
    const controller: map.MapComponentController = this.mapController;
    if (mapStyleIndex === 0) {
      const poiAllOn: boolean = poiVisible && roadLabelVisible;
      if (poiAllOn) {
        const param: mapCommon.CustomMapStyleOptions = { styleContent: '[]' };
        controller.setCustomMapStyle(param).then(() => {
          hilog.info(0x0000, TAG_LOG, 'Classic style all labels restored');
        }).catch((err: BusinessError) => {
          hilog.error(0x0000, TAG_LOG, 'applyLabelVisibility classic restore failed, code: %{public}s, message: %{public}s', err.code.toString(), err.message.toString());
        });
        return;
      }
      const rules: string[] = [];
      if (!poiVisible) {
        rules.push('{"mapFeature":"poi","options":"all","visibility":false}');
        rules.push('{"mapFeature":"administrative.locality","options":"all","visibility":false}');
        rules.push('{"mapFeature":"administrative.house number","options":"labels.text","visibility":false}');
        rules.push('{"mapFeature":"landcover.human-made.address area","options":"labels.text","visibility":false}');
        rules.push('{"mapFeature":"landcover.business.shopping center","options":"labels.text","visibility":false}');
        rules.push('{"mapFeature":"landcover.college","options":"labels.text","visibility":false}');
        rules.push('{"mapFeature":"landcover.business.business district","options":"labels.text","visibility":false}');
        rules.push('{"mapFeature":"landcover.business_park","options":"labels.text","visibility":false}');
        rules.push('{"mapFeature":"landcover.human-made.hotel","options":"labels.text","visibility":false}');
      }
      if (!roadLabelVisible) {
        rules.push('{"mapFeature":"road","options":"labels","visibility":false}');
        rules.push('{"mapFeature":"road","options":"labels.icon","visibility":false}');
      }
      if (!transitVisible) {
        rules.push('{"mapFeature":"transit","options":"all","visibility":false}');
      }
      const param: mapCommon.CustomMapStyleOptions = { styleContent: '[' + rules.join(',') + ']' };
      controller.setCustomMapStyle(param).then(() => {
        hilog.info(0x0000, TAG_LOG, 'Classic style labels applied: poi=%{public}s, road=%{public}s', poiVisible.toString(), roadLabelVisible.toString());
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, TAG_LOG, 'applyLabelVisibility classic failed, code: %{public}s, message: %{public}s', err.code.toString(), err.message.toString());
      });
    } else if (mapStyleIndex === 1) {
      const styleContent: string = this.readMapStyleDarkJson();
      let modifiedContent: string = this.modifyLabelVisibility(styleContent, poiVisible, roadLabelVisible, transitVisible, buildingEnabled);
      const extraRules: string[] = [];
      if (!poiVisible) {
        extraRules.push('{"mapFeature":"poi","options":"labels.icon","visibility":false}');
      }
      if (!roadLabelVisible) {
        extraRules.push('{"mapFeature":"road","options":"labels.icon","visibility":false}');
      }
      if (!transitVisible) {
        extraRules.push('{"mapFeature":"transit","options":"labels.icon","visibility":false}');
      }
      if (extraRules.length > 0) {
        modifiedContent = modifiedContent.substring(0, modifiedContent.length - 1) + ',' + extraRules.join(',') + ']';
      }
      const param: mapCommon.CustomMapStyleOptions = { styleContent: modifiedContent };
      controller.setCustomMapStyle(param).then(() => {
        hilog.info(0x0000, TAG_LOG, 'Dark style labels applied: poi=%{public}s, road=%{public}s, transit=%{public}s', poiVisible.toString(), roadLabelVisible.toString(), transitVisible.toString());
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, TAG_LOG, 'applyLabelVisibility dark failed, code: %{public}s, message: %{public}s', err.code.toString(), err.message.toString());
      });
    } else if (mapStyleIndex === 3) {
      const styleContent: string = this.readMapStyleTestJson();
      let modifiedContent: string = this.modifyLabelVisibility(styleContent, poiVisible, roadLabelVisible, transitVisible, buildingEnabled);
      const extraRules: string[] = [];
      if (!poiVisible) {
        extraRules.push('{"mapFeature":"poi","options":"labels.icon","visibility":false}');
      }
      if (!roadLabelVisible) {
        extraRules.push('{"mapFeature":"road","options":"labels.icon","visibility":false}');
      }
      if (!transitVisible) {
        extraRules.push('{"mapFeature":"transit","options":"labels.icon","visibility":false}');
      }
      if (extraRules.length > 0) {
        modifiedContent = modifiedContent.substring(0, modifiedContent.length - 1) + ',' + extraRules.join(',') + ']';
      }
      const param: mapCommon.CustomMapStyleOptions = { styleContent: modifiedContent };
      controller.setCustomMapStyle(param).then(() => {
        hilog.info(0x0000, TAG_LOG, 'Dabai style labels applied: poi=%{public}s, road=%{public}s, transit=%{public}s', poiVisible.toString(), roadLabelVisible.toString(), transitVisible.toString());
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, TAG_LOG, 'applyLabelVisibility dabai failed, code: %{public}s, message: %{public}s', err.code.toString(), err.message.toString());
      });
    }
  }

  private modifyLabelVisibility(jsonStr: string, poiVisible: boolean, roadLabelVisible: boolean,
    transitVisible: boolean, buildingEnabled: boolean): string {
    try {
      const arr: Object[] = JSON.parse(jsonStr) as Object[];
      const poiFeatures: string[] = [
        'poi',
        'administrative.locality',
        'administrative.house number',
        'landcover.human-made.address area',
        'landcover.business.shopping center',
        'landcover.college',
        'landcover.business.business district',
        'landcover.business_park',
        'landcover.human-made.hotel'
      ];
      const result: Object[] = [];
      for (let i = 0; i < arr.length; i++) {
        const item: Record<string, Object> = arr[i] as Record<string, Object>;
        const feature: string = (item['mapFeature'] ?? '') as string;
        const options: string = (item['options'] ?? '') as string;
        const isLabelOption: boolean = options.indexOf('labels') === 0;
        const isTransit: boolean = feature.indexOf('transit') === 0;
        const isPoi: boolean = feature.indexOf('poi') === 0;
        const isPoiLabel: boolean = poiFeatures.indexOf(feature) >= 0 && isLabelOption;
        const isRoad: boolean = feature.indexOf('road') === 0;
        const isRoadLabel: boolean = isRoad && isLabelOption;
        const isBuilding: boolean = feature.indexOf('landcover.human-made.building') === 0 ||
          feature === 'landcover.human-made.Public building' ||
          feature === 'landcover.human_made';
        if (isTransit) {
          const newItem: Record<string, Object> = {} as Record<string, Object>;
          const keys: string[] = Object.keys(item);
          for (let k = 0; k < keys.length; k++) {
            newItem[keys[k]] = item[keys[k]];
          }
          newItem['visibility'] = transitVisible;
          result.push(newItem as Object);
        } else if (isPoi || isPoiLabel) {
          const newItem: Record<string, Object> = {} as Record<string, Object>;
          const keys: string[] = Object.keys(item);
          for (let k = 0; k < keys.length; k++) {
            newItem[keys[k]] = item[keys[k]];
          }
          newItem['visibility'] = poiVisible;
          result.push(newItem as Object);
        } else if (isRoadLabel) {
          const newItem: Record<string, Object> = {} as Record<string, Object>;
          const keys: string[] = Object.keys(item);
          for (let k = 0; k < keys.length; k++) {
            newItem[keys[k]] = item[keys[k]];
          }
          newItem['visibility'] = roadLabelVisible;
          result.push(newItem as Object);
        } else if (isBuilding) {
          const newItem: Record<string, Object> = {} as Record<string, Object>;
          const keys: string[] = Object.keys(item);
          for (let k = 0; k < keys.length; k++) {
            newItem[keys[k]] = item[keys[k]];
          }
          newItem['visibility'] = buildingEnabled;
          result.push(newItem as Object);
        } else {
          result.push(item);
        }
      }
      return JSON.stringify(result);
    } catch (e) {
      hilog.error(0x0000, TAG_LOG, 'modifyLabelVisibility failed: %{public}s', JSON.stringify(e));
      return jsonStr;
    }
  }
}
