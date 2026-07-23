/**
 * FootprintTab.ets —— 足迹地图主页面
 *
 * 全屏地图 + 浮层按钮（地图工具/统计/我的）
 * 统计和"我的"功能从底部 Tab 改为右侧胶囊入口
 */

import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, hdsMaterial, HdsAnimationMode, HdsNavDestination, HdsNavigation, HdsNavigationMenuContentOptions } from '@kit.UIDesignKit';


import { TrackDatabase } from '../data/TrackDatabase';
import { PermissionService } from '../service/PermissionService';
import { TrackLocationService } from '../service/TrackLocationService';
import { LogService } from '../service/LogService';
import { MapOverlayManager } from '../service/MapOverlayManager';
import { TimeViewModel } from '../viewmodel/TimeViewModel';
import { MapStyleViewModel } from '../viewmodel/MapStyleViewModel';
import { CardItem } from '../components/CardItem';
import { RecordModePanel } from '../components/RecordModePanel';
import { LocationPermPanel } from '../components/LocationPermPanel';
import { SettingPanel } from '../components/SettingPanel';
import { LogPanel } from '../components/LogPanel';
import { PrivacyPanel } from '../components/PrivacyPanel';
import { StrategyLabPanel } from '../components/StrategyLabPanel';
import {
  RecordMode, MODE_CONFIG, TrackPointRecord,
  TIME_VIEW_OVERVIEW, TIME_VIEW_CUSTOM, TIME_VIEW_TODAY,
  ONE_DAY_MS, TRACK_COLORS, TrackColorConfig
} from '../model/TrackTypes';
import { calculateDistance, formatDistance, getDayStartTs, getDayEndTs, formatStatDate, formatLongDate } from '../common/TrackUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vibrator } from '@kit.SensorServiceKit';

const TAG_LOG: string = 'FootprintTab';

interface MapStyleGridItem {
  index: number;
  label: string;
  icon: Resource;
}

@Component
export struct FootprintTab {
  // ===== 服务实例（由 Index 传入，共享同一实例）=====
  db: TrackDatabase = new TrackDatabase();
  permSvc: PermissionService = new PermissionService();
  locationSvc: TrackLocationService = new TrackLocationService();
  logSvc: LogService = new LogService();
  mapManager: MapOverlayManager = new MapOverlayManager();
  timeModel: TimeViewModel = new TimeViewModel();
  mapStyleVM: MapStyleViewModel = new MapStyleViewModel();

  private static readonly CALENDAR_ICONS: Resource[] = [
    $r('sys.symbol.calendar_01'), $r('sys.symbol.calendar_02'),
    $r('sys.symbol.calendar_03'), $r('sys.symbol.calendar_04'),
    $r('sys.symbol.calendar_05'), $r('sys.symbol.calendar_06'),
    $r('sys.symbol.calendar_07'), $r('sys.symbol.calendar_08'),
    $r('sys.symbol.calendar_09'), $r('sys.symbol.calendar_10'),
    $r('sys.symbol.calendar_11'), $r('sys.symbol.calendar_12'),
    $r('sys.symbol.calendar_13'), $r('sys.symbol.calendar_14'),
    $r('sys.symbol.calendar_15'), $r('sys.symbol.calendar_16'),
    $r('sys.symbol.calendar_17'), $r('sys.symbol.calendar_18'),
    $r('sys.symbol.calendar_19'), $r('sys.symbol.calendar_20'),
    $r('sys.symbol.calendar_21'), $r('sys.symbol.calendar_22'),
    $r('sys.symbol.calendar_23'), $r('sys.symbol.calendar_24'),
    $r('sys.symbol.calendar_25'), $r('sys.symbol.calendar_26'),
    $r('sys.symbol.calendar_27'), $r('sys.symbol.calendar_28'),
    $r('sys.symbol.calendar_29'), $r('sys.symbol.calendar_30'),
    $r('sys.symbol.calendar_31'),
  ];

  // ===== 布局参数（@Watch 确保窗口尺寸异步获取后更新 padding）=====
  @Prop @Watch('onLayoutMetaChange') statusBarHeight: number = 0;
  @Prop @Watch('onLayoutMetaChange') navBarHeight: number = 0;

  // ===== 跨页面双向状态 ====
  @Link currentMode: RecordMode;
  mainNavStack: NavPathStack | null = null;

  @Link trackCount: number;
  @Link totalDistance: number;

  @Link timeViewIndex: number;
  @Link hasApproximatelyLocation: boolean;
  @Link hasLocation: boolean;
  @Link hasBackgroundLocation: boolean;
  @Link nightModeIndex: number;
  @Link sleepModeEnabled: boolean;

  // ===== 回调（由 Index 传入，触发副作用）=====
  onRefreshPermission: () => void = () => {};
  onNightModeChange: (index: number) => void = () => {};
  onRecordModeChange: (mode: number) => void = () => {};
  onSleepModeChange: (enabled: boolean) => void = () => {};

  // ===== 地图内部状态（仅 FootprintTab 使用）=====
  private mapOptions?: mapCommon.MapOptions;
  private callback?: AsyncCallback<map.MapComponentController>;
  @State trackPoints: mapCommon.LatLng[] = [];
  @State footprintPoints: mapCommon.LatLng[] = [];
  private lastKnownLocation: mapCommon.LatLng | null = null;
  private savedUserPosition: mapCommon.LatLng | null = null;
  @State displayMode: number = 0;
  @State selectedTabIndex: number = 2;
  @Link immersive: boolean;

  @State myLocationOn: boolean = false;
  @State myLocationDisplayType: mapCommon.MyLocationDisplayType = mapCommon.MyLocationDisplayType.DEFAULT;
  @State cameraOffset: boolean = false;
  private isResetting: boolean = false;
  @State mapStyleIndex: number = 0;
  @State timeViewSelectedIndexes: number[] = [TIME_VIEW_TODAY];
  @State trackColorIndex: number = 0;
  @State buildingEnabled: boolean = true;
  @State poiVisible: boolean = true;
  @State roadLabelVisible: boolean = true;
  @State transitVisible: boolean = true;

  // ===== 右侧浮层面板状态 ====
  @State pushSwitchOn: boolean = false;

  @State isShowThemeSheet: boolean = false;
  @State isShowSettingSheet: boolean = false;
  private settingNavStack: NavPathStack = new NavPathStack();
  private settingScroller: Scroller = new Scroller();

  // ===== HdsTabs 底部悬浮页签 =====
  private hdsTabsController: HdsTabsController = new HdsTabsController();
  @State tabOptions: string[] = ['总览', '自定义', '今日', '昨日'];

  // ===== 生命周期 =====
  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;

    // 恢复上次选择的地图样式，避免每次进入都被重置为经典
    this.mapStyleVM.setContext(ctx);
    const style: number = this.mapStyleVM.loadMapStyle();
    this.mapStyleIndex = style;

    // 恢复上次选择的轨迹颜色
    this.trackColorIndex = this.mapStyleVM.loadTrackColor();

    // 恢复3D建筑和地名标注开关状态
    this.buildingEnabled = this.mapStyleVM.loadBuildingEnabled();
    this.poiVisible = this.mapStyleVM.loadPoiVisible();
    this.roadLabelVisible = this.mapStyleVM.loadRoadLabelVisible();
    this.transitVisible = this.mapStyleVM.loadTransitVisible();

    // 恢复「时间范围」视图选择（默认今日）与自定义起止日期
    this.timeModel.setContext(ctx);
    this.timeModel.loadPrefs();
    // 默认 Tab 为今日（index=2），强制设为今日视图
    this.timeModel.onTimeViewSelected(TIME_VIEW_TODAY);
    this.timeViewIndex = TIME_VIEW_TODAY;
    this.timeViewSelectedIndexes = [this.timeViewIndex];

    // 地图管理器的尺寸/样式元信息 + 初始参数与回调
    this.mapManager.setContext(ctx);
    this.mapManager.setLayoutMeta(this.navBarHeight, this.statusBarHeight);
    this.mapManager.setInitialMapStyle(this.mapStyleIndex);
    this.mapManager.setInitialBuildingEnabled(this.buildingEnabled);
    this.mapManager.setInitialPoiVisible(this.poiVisible);
    this.mapManager.setInitialRoadLabelVisible(this.roadLabelVisible);
    this.mapManager.setInitialTransitVisible(this.transitVisible);
    this.mapOptions = this.mapManager.buildMapOptions(this.mapStyleIndex);
    this.callback = this.mapManager.buildMapCallback(
      () => { this.onMapReady(); },
      () => { this.onMapClick(); },
      () => { this.onCameraGesture(); }
    );

    this.timeModel.startDayCheck(() => { this.onDayChange(); });
  }

  onLayoutMetaChange(): void {
    this.mapManager.setLayoutMeta(this.navBarHeight, this.statusBarHeight);
    if (this.mapManager.controller) {
      this.mapManager.setBottomPadding(this.immersive);
    }
  }

  // ===== 核心方法 =====
  private async onMapReady(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await this.db.init(ctx);
    if (this.db.store !== null) {
      this.logSvc.init(this.db.store);
      this.locationSvc.setLogService(this.logSvc);
    }
    const records = await this.db.loadAll();
    this.timeModel.setAllPoints(records);
    await this.mapManager.createRedDotIcon(TRACK_COLORS[this.trackColorIndex].color);
    this.refreshVisibleView();
    await this.permissionFlow(ctx);
  }

  private onMapClick(): void {
    const next: boolean = !this.immersive;
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => { this.immersive = next; });
    this.mapManager.setBottomPadding(next);
    const controller = this.mapManager.controller;
    if (controller) {
      controller.setMyLocationEnabled(next ? false : this.myLocationOn);
      if (!next && this.myLocationOn) {
        controller.setMyLocationControlsEnabled(false);
        controller.setMyLocationStyle({ displayType: this.myLocationDisplayType });
      }
    }
    if (next) {
      this.hdsTabsController.applyHideAnimation(HdsAnimationMode.CLICK_ANIMATION);
    } else {
      this.hdsTabsController.applyShowAnimation(HdsAnimationMode.CLICK_ANIMATION);
    }
  }

  private onCameraGesture(): void {
    if (this.isResetting) {
      return;
    }
    if (this.myLocationDisplayType === mapCommon.MyLocationDisplayType.FOLLOW_ROTATE) {
      const controller = this.mapManager.controller;
      if (controller) {
        this.savedUserPosition = controller.getCameraPosition().target;
        controller.setMyLocationStyle({
          anchorU: 0.5,
          anchorV: 0.5,
          radiusFillColor: 0x224085F4,
          displayType: mapCommon.MyLocationDisplayType.TRACK_ROTATE
        });
      }
      this.myLocationDisplayType = mapCommon.MyLocationDisplayType.TRACK_ROTATE;
      this.cameraOffset = true;
    }
  }

  private async onMyLocationClick(): Promise<void> {
    const controller = this.mapManager.controller;
    if (!controller) { return; }
    // @SuppressWarnings permission
            // @SuppressWarnings compatibility
            try {
              vibrator.startVibration({
                type: 'preset', effectId: 'haptic.clock.timer', count: 1
              }, {
                usage: 'touch'
              }).then(() => {
              }, (error: BusinessError) => {
                hilog.warn(0x0000, TAG_LOG, 'vibrator failed: %{public}d', error.code);
              });
            } catch (err) {
              let e: BusinessError = err as BusinessError;
              hilog.warn(0x0000, TAG_LOG, 'vibrator error: %{public}d', e.code);
            }

    if (!this.myLocationOn) {
      controller.setMyLocationEnabled(true);
      controller.setMyLocationControlsEnabled(false);
      this.myLocationOn = true;
      this.myLocationDisplayType = mapCommon.MyLocationDisplayType.FOLLOW_ROTATE;
      await controller.setMyLocationStyle({
        anchorU: 0.5,
        anchorV: 0.5,
        radiusFillColor: 0x224085F4,
        displayType: mapCommon.MyLocationDisplayType.FOLLOW_ROTATE
      });
      try {
        const singleRequest: geoLocationManager.SingleLocationRequest = {
          locatingTimeoutMs: 10000,
          locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_ACCURACY
        };
        const currentLocation = await geoLocationManager.getCurrentLocation(singleRequest);
        const gcj02Location = await map.convertCoordinate(
          mapCommon.CoordinateType.WGS84, mapCommon.CoordinateType.GCJ02,
          { latitude: currentLocation.latitude, longitude: currentLocation.longitude }
        );
        controller.moveCamera(map.newCameraPosition({ target: gcj02Location, zoom: 15 }));
        this.lastKnownLocation = gcj02Location;
      } catch (err) {
        const error = err as BusinessError;
        hilog.warn(0x0000, TAG_LOG, 'Failed to move camera to current location, code: %{public}d', error.code);
      }
      return;
    }

    if (this.cameraOffset) {
      this.cameraOffset = false;
      this.isResetting = true;
      // 第一步：切到 DEFAULT 模式（组件不管理相机，允许外部移动）
      this.myLocationDisplayType = mapCommon.MyLocationDisplayType.DEFAULT;
      controller.setMyLocationStyle({
        anchorU: 0.5,
        anchorV: 0.5,
        radiusFillColor: 0x224085F4,
        displayType: mapCommon.MyLocationDisplayType.DEFAULT
      });
      // 第二步：在 DEFAULT 模式下移动相机到蓝点位置
      const target: mapCommon.LatLng | null = this.lastKnownLocation;
      if (target) {
        await controller.animateCameraStatus(
          map.newCameraPosition({ target: target, zoom: 15, bearing: 0, tilt: 0 }),
          300
        ).catch(() => {});
      }
      // 第三步：相机移动完成后切回 FOLLOW_ROTATE（后续位置更新自动跟随）
      this.myLocationDisplayType = mapCommon.MyLocationDisplayType.FOLLOW_ROTATE;
      controller.setMyLocationStyle({
        anchorU: 0.5,
        anchorV: 0.5,
        radiusFillColor: 0x224085F4,
        displayType: mapCommon.MyLocationDisplayType.FOLLOW_ROTATE
      });
      this.isResetting = false;
      // 第四步：异步获取最新定位微调
      try {
        const singleRequest: geoLocationManager.SingleLocationRequest = {
          locatingTimeoutMs: 10000,
          locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_ACCURACY
        };
        const currentLocation = await geoLocationManager.getCurrentLocation(singleRequest);
        const gcj02Location = await map.convertCoordinate(
          mapCommon.CoordinateType.WGS84, mapCommon.CoordinateType.GCJ02,
          { latitude: currentLocation.latitude, longitude: currentLocation.longitude }
        );
        this.lastKnownLocation = gcj02Location;
        if (this.myLocationDisplayType === mapCommon.MyLocationDisplayType.FOLLOW_ROTATE) {
          this.myLocationDisplayType = mapCommon.MyLocationDisplayType.DEFAULT;
          controller.setMyLocationStyle({
            anchorU: 0.5,
            anchorV: 0.5,
            radiusFillColor: 0x224085F4,
            displayType: mapCommon.MyLocationDisplayType.DEFAULT
          });
          await controller.animateCameraStatus(
            map.newCameraPosition({ target: gcj02Location, zoom: 15, bearing: 0, tilt: 0 }),
            300
          ).catch(() => {});
          this.myLocationDisplayType = mapCommon.MyLocationDisplayType.FOLLOW_ROTATE;
          controller.setMyLocationStyle({
            anchorU: 0.5,
            anchorV: 0.5,
            radiusFillColor: 0x224085F4,
            displayType: mapCommon.MyLocationDisplayType.FOLLOW_ROTATE
          });
        }
      } catch (err) {
        const error = err as BusinessError;
        hilog.warn(0x0000, TAG_LOG, 'Active location refresh failed, code: %{public}d', error.code);
      }
    }
  }

  private async permissionFlow(ctx: common.UIAbilityContext): Promise<void> {
    const state = await this.permSvc.refreshPermissionState();
    this.hasApproximatelyLocation = state.hasApproximatelyLocation;
    this.hasLocation = state.hasLocation;
    this.hasBackgroundLocation = state.hasBackgroundLocation;
    if (!state.hasApproximatelyLocation || !state.hasLocation) {
      const res = await this.permSvc.requestPermissions(ctx, this.getUIContext());
      this.hasApproximatelyLocation = res.hasApproximatelyLocation;
      this.hasLocation = res.hasLocation;
      this.hasBackgroundLocation = res.hasBackgroundLocation;
      if (res.hasApproximatelyLocation && res.hasLocation) {
        if (!res.hasBackgroundLocation) { this.permSvc.requestBackgroundLocationPermission(this.getUIContext()); }
        this.enableMyLocation();
      }
    } else {
      if (!state.hasBackgroundLocation) { this.permSvc.requestBackgroundLocationPermission(this.getUIContext()); }
      this.enableMyLocation();
    }
  }

  private async enableMyLocation(): Promise<void> {
    const controller = this.mapManager.controller;
    if (!controller) { return; }
    try {
      controller.setMyLocationEnabled(true);
      controller.setMyLocationControlsEnabled(false);
      const style: mapCommon.MyLocationStyle = {
        anchorU: 0.5,
        anchorV: 0.5,
        radiusFillColor: 0x224085F4,
        displayType: mapCommon.MyLocationDisplayType.FOLLOW_ROTATE
      };
      await controller.setMyLocationStyle(style);
      this.myLocationOn = true;
      this.myLocationDisplayType = mapCommon.MyLocationDisplayType.FOLLOW_ROTATE;
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'Failed to set my location style, code: %{public}d, message: %{public}s', error.code, error.message);
      this.myLocationOn = false;
    }
    try {
      const singleRequest: geoLocationManager.SingleLocationRequest = {
        locatingTimeoutMs: 10000,
        locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_ACCURACY
      };
      const currentLocation = await geoLocationManager.getCurrentLocation(singleRequest);
      const gcj02Location = await map.convertCoordinate(
        mapCommon.CoordinateType.WGS84, mapCommon.CoordinateType.GCJ02,
        { latitude: currentLocation.latitude, longitude: currentLocation.longitude }
      );
      controller?.moveCamera(map.newCameraPosition({ target: gcj02Location, zoom: 15 }));
      this.lastKnownLocation = gcj02Location;
    } catch (err) {
      const error = err as BusinessError;
      hilog.warn(0x0000, TAG_LOG, 'Failed to move camera to current location, code: %{public}d, message: %{public}s', error.code, error.message);
    }
    this.locationSvc.startLocation({
      onSample: (latLng: mapCommon.LatLng, accuracy: number, speed: number, timestamp?: number) => { this.onLocationSample(latLng, accuracy, speed, timestamp); },
      onLocationError: (error: geoLocationManager.LocationError) => { this.onLocationError(error); },
      onLocationEnabledChange: (enabled: boolean) => { this.onLocationEnabledChange(enabled); }
    });
  }


  private onLocationSample(latLng: mapCommon.LatLng, accuracy: number, speed: number, timestamp?: number): void {
    this.lastKnownLocation = latLng;
    this.recordTrackPoint(latLng, accuracy, speed, timestamp);
  }

  private onLocationError(error: geoLocationManager.LocationError): void {
    if (error === geoLocationManager.LocationError.LOCATING_FAILED_LOCATION_SWITCH_OFF) {
      hilog.warn(0x0000, TAG_LOG, 'Location switch turned off during tracking');
      try {
        this.getUIContext().getPromptAction().showToast({ message: '定位开关已关闭，请在设置中开启' });
      } catch (e) {
        hilog.warn(0x0000, TAG_LOG, 'showToast failed');
      }
    } else if (error === geoLocationManager.LocationError.LOCATING_FAILED_LOCATION_PERMISSION_DENIED) {
      hilog.warn(0x0000, TAG_LOG, 'Location permission denied during tracking');
      try {
        this.getUIContext().getPromptAction().showToast({ message: '定位权限被拒绝，请在设置中授权' });
      } catch (e) {
        hilog.warn(0x0000, TAG_LOG, 'showToast failed');
      }
    } else if (error === geoLocationManager.LocationError.LOCATING_FAILED_BACKGROUND_PERMISSION_DENIED) {
      hilog.warn(0x0000, TAG_LOG, 'Background location permission denied during tracking');
      try {
        this.getUIContext().getPromptAction().showToast({ message: '后台定位权限被拒绝，请在设置中授权' });
      } catch (e) {
        hilog.warn(0x0000, TAG_LOG, 'showToast failed');
      }
    } else if (error === geoLocationManager.LocationError.LOCATING_FAILED_INTERNET_ACCESS_FAILURE) {
      hilog.warn(0x0000, TAG_LOG, 'Network unavailable, network positioning failed');
      try {
        this.getUIContext().getPromptAction().showToast({ message: '网络不可用，网络定位失败' });
      } catch (e) {
        hilog.warn(0x0000, TAG_LOG, 'showToast failed');
      }
    } else {
      hilog.warn(0x0000, TAG_LOG, 'Location error: %{public}s', String(error));
      try {
        this.getUIContext().getPromptAction().showToast({ message: '定位异常' });
      } catch (e) {
        hilog.warn(0x0000, TAG_LOG, 'showToast failed');
      }
    }
  }

  private onLocationEnabledChange(enabled: boolean): void {
    if (!enabled) {
      hilog.warn(0x0000, TAG_LOG, 'Location switch turned off by user');
      try {
        this.getUIContext().getPromptAction().showToast({ message: '定位开关已关闭，足迹记录已暂停' });
      } catch (e) {
        hilog.warn(0x0000, TAG_LOG, 'showToast failed');
      }
    } else {
      hilog.info(0x0000, TAG_LOG, 'Location switch turned on by user');
      try {
        this.getUIContext().getPromptAction().showToast({ message: '定位开关已开启' });
      } catch (e) {
        hilog.warn(0x0000, TAG_LOG, 'showToast failed');
      }
    }
  }

  private recordTrackPoint(latLng: mapCommon.LatLng, accuracy: number, speed: number, timestamp?: number): void {
    const ts: number = timestamp ?? Date.now();
    const rec: TrackPointRecord = { latitude: latLng.latitude, longitude: latLng.longitude, timestamp: ts, accuracy: accuracy, speed: speed };
    this.timeModel.addPoint(rec);
    if (this.timeModel.isInVisibleRange(ts)) {
      const prevLast: mapCommon.LatLng | null = this.trackPoints.length > 0 ? this.trackPoints[this.trackPoints.length - 1] : null;
      this.trackPoints.push(latLng);
      this.trackCount = this.trackPoints.length;
      if (prevLast) { this.totalDistance += calculateDistance(prevLast, latLng); }
      this.footprintPoints.push(latLng);
      this.mapManager.refreshOverlay(this.displayMode, this.trackPoints, this.footprintPoints);
    }
    this.db.insert(rec);
  }

  private refreshVisibleView(): void {
    const v = this.timeModel.applyTimeView();
    this.trackPoints = v.trackPoints;
    this.footprintPoints = v.footprintPoints;
    this.totalDistance = v.totalDistance;
    this.trackCount = v.trackPoints.length;
    if (this.timeViewIndex === TIME_VIEW_OVERVIEW) { this.displayMode = 1; }

    this.mapManager.rebuildOverlay(this.displayMode, this.trackPoints, this.footprintPoints);
  }

  private onDayChange(): void {
    if (this.timeModel.shouldRefreshOnDayChange()) { this.refreshVisibleView(); }
  }

  // HdsTabs 时间视图切换
  private onTimeViewSelected(index: number): void {
    if (index === 0) {
      this.timeModel.onTimeViewSelected(TIME_VIEW_OVERVIEW);
      this.refreshVisibleView();
    } else if (index === 1) {
      if (this.timeModel.customStart <= 0) {
        const todayStart = getDayStartTs(Date.now());
        const todayEnd = getDayEndTs(Date.now());
        this.timeModel.setCustomRange(todayStart, todayEnd);
      }
      this.timeModel.onTimeViewSelected(TIME_VIEW_CUSTOM);
      this.refreshVisibleView();
      this.showCustomDatePicker();
    } else if (index === 2) {
      this.timeModel.onTimeViewSelected(TIME_VIEW_TODAY);
      this.refreshVisibleView();
    } else if (index === 3) {
      const yesterdayStart = getDayStartTs(Date.now() - ONE_DAY_MS);
      const yesterdayEnd = getDayEndTs(Date.now() - ONE_DAY_MS);
      this.timeModel.onTimeViewSelected(TIME_VIEW_CUSTOM);
      this.timeModel.setCustomRange(yesterdayStart, yesterdayEnd);
      this.refreshVisibleView();
    }
  }

  private showCustomDatePicker(): void {
    const uiContext = this.getUIContext();
    const todayStart: number = getDayStartTs(Date.now());
    const todayEnd: number = getDayEndTs(Date.now());
    const startInit: number = this.timeModel.customStart > 0 ? this.timeModel.customStart : todayStart;
    uiContext.showDatePickerDialog({
      start: new Date(todayStart - 365 * ONE_DAY_MS), end: new Date(todayEnd), selected: new Date(startInit),
      onDateAccept: (value: Date) => {
        const s: number = getDayStartTs(value.getTime());
        const endInit: number = this.timeModel.customEnd > 0 ? this.timeModel.customEnd : Date.now();
        uiContext.showDatePickerDialog({
          start: new Date(s), end: new Date(todayEnd), selected: new Date(endInit),
          onDateAccept: (value2: Date) => {
            const e: number = getDayEndTs(value2.getTime());
            if (e < s) { getDayEndTs(s); }
            this.timeModel.setCustomRange(s, e);
            this.refreshVisibleView();
          }
        });
      }
    });
  }

  private getCustomDateText(): string {
    return formatLongDate(this.timeModel.customStart);
  }

  private prevCustomDay(): void {
    const newStart = this.timeModel.customStart - ONE_DAY_MS;
    const newEnd = this.timeModel.customEnd - ONE_DAY_MS;
    this.timeModel.setCustomRange(newStart, newEnd);
    this.refreshVisibleView();
  }

  private nextCustomDay(): void {
    const todayEnd = getDayEndTs(Date.now());
    const newEnd = this.timeModel.customEnd + ONE_DAY_MS;
    if (newEnd > todayEnd) {
      return;
    }
    const newStart = this.timeModel.customStart + ONE_DAY_MS;
    this.timeModel.setCustomRange(newStart, newEnd);
    this.refreshVisibleView();
  }

  // T024: 地图样式切换
  private switchMapStyle(index: number): void {
    if (this.mapStyleIndex === index) { return; }
    this.mapStyleIndex = index;
    this.mapStyleVM.saveMapStyle(index);
    this.mapManager.applyMapStyle(index);
    this.mapManager.applyLabelVisibility(this.poiVisible, this.roadLabelVisible, index, this.transitVisible, this.buildingEnabled);
  }

  private async switchTrackColor(index: number): Promise<void> {
    if (this.trackColorIndex === index) { return; }
    this.trackColorIndex = index;
    this.mapStyleVM.saveTrackColor(index);
    await this.mapManager.applyTrackColor(index, this.displayMode, this.trackPoints, this.footprintPoints);
  }

  private switchBuildingEnabled(enabled: boolean): void {
    this.buildingEnabled = enabled;
    this.mapStyleVM.saveBuildingEnabled(enabled);
    this.mapManager.setBuildingEnabled(enabled);
    this.mapManager.applyLabelVisibility(this.poiVisible, this.roadLabelVisible, this.mapStyleIndex, this.transitVisible, enabled);
  }

  private switchPoiVisible(visible: boolean): void {
    this.poiVisible = visible;
    this.mapStyleVM.savePoiVisible(visible);
    this.mapManager.applyLabelVisibility(visible, this.roadLabelVisible, this.mapStyleIndex, this.transitVisible, this.buildingEnabled);
  }

  private switchRoadLabelVisible(visible: boolean): void {
    this.roadLabelVisible = visible;
    this.mapStyleVM.saveRoadLabelVisible(visible);
    this.mapManager.applyLabelVisibility(this.poiVisible, visible, this.mapStyleIndex, this.transitVisible, this.buildingEnabled);
  }

  private switchTransitVisible(visible: boolean): void {
    this.transitVisible = visible;
    this.mapStyleVM.saveTransitVisible(visible);
    this.mapManager.applyLabelVisibility(this.poiVisible, this.roadLabelVisible, this.mapStyleIndex, visible, this.buildingEnabled);
  }

  private switchDisplayMode(mode: number): void {
    if (this.timeViewIndex === TIME_VIEW_OVERVIEW && mode === 0) { return; }
    if (this.displayMode === mode) { return; }
    this.displayMode = mode;
    this.mapManager.switchDisplayMode(mode, this.timeViewIndex, this.trackPoints, this.footprintPoints);
  }

  // 组件销毁：停止定位、刷新数据库缓冲区、跨日检测
  aboutToDisappear(): void {
    this.locationSvc.stopLocation();
    this.db.flushIfNeeded();
    this.timeModel.stopDayCheck();
  }

  // ===== UI 构建 =====
  build() {
    Stack() {
      MapComponent({ mapOptions: this.mapOptions, mapCallback: this.callback })
        .width('100%').height('100%').opacity(1)

      // 左上角胶囊组
      Column({ space: 10 }) {
        if (this.trackCount > 0 && !this.immersive) {
          Column({ space: 2 }) {
            Text(`足迹点 ${this.trackCount} 个`).fontSize(13).fontColor($r('sys.color.font_primary')).fontWeight(FontWeight.Medium).textAlign(TextAlign.Start)
            Text(`轨迹线 ${formatDistance(this.totalDistance)}`).fontSize(13).fontColor($r('sys.color.font_primary')).fontWeight(FontWeight.Medium).textAlign(TextAlign.Start)
          }
          .alignItems(HorizontalAlign.Start).padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .borderRadius(16).clip(true).backdropBlur(12)
          .backgroundColor('rgba(255,255,255,0.1)').border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
          .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
          .transition({ type: TransitionType.All, opacity: 0, translate: { x: 0, y: -16 } })
        }

      }
      .alignItems(HorizontalAlign.Start).position({ x: 12, y: 12 + this.statusBarHeight })

      // 右侧功能胶囊按钮
      if (!this.immersive) {
        Column({ space: 10 }) {
          Row() {
            SymbolGlyph($r('sys.symbol.brush_fill')).fontSize(20).fontColor([$r('sys.color.font_primary')])
          }
          .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(16).clip(true).backdropBlur(12)
          .backgroundColor('rgba(255,255,255,0.1)').border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
          .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
          .onClick(() => {
            // @SuppressWarnings permission
            // @SuppressWarnings compatibility
            try {
              vibrator.startVibration({
                type: 'preset', effectId: 'haptic.clock.timer', count: 1
              }, {
                usage: 'touch'
              }).then(() => {
              }, (error: BusinessError) => {
                hilog.warn(0x0000, TAG_LOG, 'vibrator failed: %{public}d', error.code);
              });
            } catch (err) {
              let e: BusinessError = err as BusinessError;
              hilog.warn(0x0000, TAG_LOG, 'vibrator error: %{public}d', e.code);
            }
            this.isShowThemeSheet = true;
          })
          .bindSheet($$this.isShowThemeSheet, this.buildThemeSheet(), {
            height: SheetSize.MEDIUM,
            dragBar: true,
            showClose: true,
            title: { title: '主题' },
            blurStyle: BlurStyle.COMPONENT_THIN,
            maskColor: '#33000000',
            backgroundColor: Color.Transparent,
            onDisappear: () => { this.isShowThemeSheet = false; }
          })

          Row() {
            SymbolGlyph($r('sys.symbol.worldclock_fill_2')).fontSize(20).fontColor([$r('sys.color.font_primary')])
          }
          .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(16).clip(true).backdropBlur(12)
          .backgroundColor('rgba(255,255,255,0.1)').border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
          .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })

          Row() {
            SymbolGlyph($r('sys.symbol.discover_fill')).fontSize(20).fontColor([$r('sys.color.font_primary')])
          }
          .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(16).clip(true).backdropBlur(12)
          .backgroundColor('rgba(255,255,255,0.1)').border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
          .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })

          Row() {
            SymbolGlyph($r('sys.symbol.gearshape')).fontSize(20).fontColor([$r('sys.color.font_primary')])
          }
          .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(16).clip(true).backdropBlur(12)
          .backgroundColor('rgba(255,255,255,0.1)').border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
          .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
          .onClick(() => {
            // @SuppressWarnings permission
            // @SuppressWarnings compatibility
            try {
              vibrator.startVibration({
                type: 'preset', effectId: 'haptic.clock.timer', count: 1
              }, {
                usage: 'touch'
              }).then(() => {
              }, (error: BusinessError) => {
                hilog.warn(0x0000, TAG_LOG, 'vibrator failed: %{public}d', error.code);
              });
            } catch (err) {
              let e: BusinessError = err as BusinessError;
              hilog.warn(0x0000, TAG_LOG, 'vibrator error: %{public}d', e.code);
            }
            this.isShowSettingSheet = true;
          })

          Row() {
            if (this.cameraOffset) {
              SymbolGlyph($r('sys.symbol.position'))
                .fontSize(20)
                .fontColor([$r('sys.color.ohos_id_color_primary')])
            } else {
              SymbolGlyph($r('sys.symbol.location_north_up_right_circle_fill'))
                .fontSize(20)
                .fontColor([$r('sys.color.ohos_id_color_activated')])
            }
          }
          .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(16).clip(true).backdropBlur(12)
          .backgroundColor(this.cameraOffset ? 'rgba(255,255,255,0.3)' : 'rgba(255,255,255,0.1)')
          .border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
          .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
          .onClick(() => { this.onMyLocationClick(); })
        }
        .position({ x: '100%', y: '60%' }).markAnchor({ x: '100%', y: '50%' }).translate({ x: -16 })
        .transition({ type: TransitionType.All, opacity: 0, translate: { x: 16, y: 0 } })
      }

      // 设置半模态宿主（独立零尺寸 Column，不与触发按钮绑定）
      Column()
        .width(0).height(0)
        .bindSheet($$this.isShowSettingSheet, this.buildSettingSheet(), {
          height: SheetSize.LARGE,
          dragBar: true,
          showClose: false,
          backgroundColor: $r('sys.color.comp_background_primary'),
          onDisappear: () => {
            this.isShowSettingSheet = false;
            this.settingNavStack.clear();
          }
        })

      // 日期胶囊（仅自定义Tab时显示）
      if (this.selectedTabIndex === 1) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(18)
            .fontColor([$r('sys.color.ohos_id_color_primary')])
            .onClick(() => { this.prevCustomDay(); })
          Text(this.getCustomDateText())
            .fontSize(15)
            .fontColor($r('sys.color.ohos_id_color_activated'))
            .onClick(() => { this.showCustomDatePicker(); })
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(18)
            .fontColor([$r('sys.color.ohos_id_color_primary')])
            .onClick(() => { this.nextCustomDay(); })
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .borderRadius(20).clip(true).backdropBlur(12)
        .backgroundColor('rgba(255,255,255,0.1)').border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
        .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
        .position({ x: '50%', y: '100%' })
        .markAnchor({ x: '50%', y: '100%' })
        .translate({ y: -100 })
        .transition({ type: TransitionType.All, opacity: 0, scale: { x: 0.8, y: 0.8 } })
      }

      // HdsTabs 底部悬浮时间选择器
      HdsTabs({ controller: this.hdsTabsController, index: 2 }) {
        TabContent() {
          Column().width('100%').height('100%')
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.figure_running'))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_primary')]),
          selected: new SymbolGlyphModifier($r('sys.symbol.figure_running'))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_activated')])
        }, '总览'))

        TabContent() {
          Column().width('100%').height('100%')
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.waveform_folder_fill'))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_primary')]),
          selected: new SymbolGlyphModifier($r('sys.symbol.waveform_folder_fill'))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_activated')])
        }, '自定义'))

        TabContent() {
          Column().width('100%').height('100%')
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier(FootprintTab.CALENDAR_ICONS[new Date().getDate() - 1])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_primary')]),
          selected: new SymbolGlyphModifier(FootprintTab.CALENDAR_ICONS[new Date().getDate() - 1])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_activated')])
        }, '今日'))

        TabContent() {
          Column().width('100%').height('100%')
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier(FootprintTab.CALENDAR_ICONS[new Date(Date.now() - ONE_DAY_MS).getDate() - 1])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_primary')]),
          selected: new SymbolGlyphModifier(FootprintTab.CALENDAR_ICONS[new Date(Date.now() - ONE_DAY_MS).getDate() - 1])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_activated')])
        }, '昨日'))
      }
      .barOverlap(true)
      .vertical(false)
      .barPosition(BarPosition.End)
      .scrollable(false)
      .onChange((index: number) => {
        this.selectedTabIndex = index;
        // @SuppressWarnings permission
        // @SuppressWarnings compatibility
        try {
          vibrator.startVibration({
            type: 'preset', effectId: 'haptic.clock.timer', count: 1
          }, {
            usage: 'touch'
          }).then(() => {
          }, (error: BusinessError) => {
            hilog.warn(0x0000, TAG_LOG, 'vibrator failed: %{public}d', error.code);
          });
        } catch (err) {
          let e: BusinessError = err as BusinessError;
          hilog.warn(0x0000, TAG_LOG, 'vibrator error: %{public}d', e.code);
        }
        this.onTimeViewSelected(index);
      })
      .barFloatingStyle({
        barBottomMargin: 28,
        miniBar: {
          miniBarBuilder: () => this.miniBarBuilder()
        },
        gradientMask: {
          maskColor: '#00000000',
          maskHeight: 92
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      })
      .width('100%').height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%').height('100%')
  }

  @Builder
  private buildSettingSheet(): void {
    HdsNavigation(this.settingNavStack) {
      Scroll(this.settingScroller) {
        Column({ space: 16 }) {
          Column() {
            CardItem({
              label: '记录规则',
              symbol: $r('sys.symbol.local_badge_gearshape'),
              statusText: MODE_CONFIG[this.currentMode].label,
              statusColor: $r('sys.color.font_secondary'),
              onClickEvent: () => { this.settingNavStack.pushPath({ name: 'recordMode' }); }
            })
            Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
            CardItem({
              label: '策略实验室',
              symbol: $r('sys.symbol.person_shield_fill'),
              onClickEvent: () => { this.settingNavStack.pushPath({ name: 'strategyLab' }); }
            })
            Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
            CardItem({
              label: '定位权限',
              symbol: $r('sys.symbol.position_badge_exclamationmark'),
              statusText: (!this.hasApproximatelyLocation || !this.hasLocation || !this.hasBackgroundLocation) ? '权限异常' : '',
              statusColor: $r('sys.color.ohos_id_color_warning'),
              onClickEvent: () => {
                this.onRefreshPermission();
                this.settingNavStack.pushPath({ name: 'location' });
              }
            })
            Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
            CardItem({
              label: '通用设置',
              symbol: $r('sys.symbol.gearshape'),
              onClickEvent: () => { this.settingNavStack.pushPath({ name: 'generalSetting' }); }
            })
            Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
            CardItem({
              label: '隐私设置',
              symbol: $r('sys.symbol.lock_fill'),
              onClickEvent: () => { this.settingNavStack.pushPath({ name: 'privacy' }); }
            })
            Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
            CardItem({
              label: '运行日志',
              symbol: $r('sys.symbol.doc_text'),
              onClickEvent: () => { this.settingNavStack.pushPath({ name: 'log' }); }
            })
          }
          .width('100%').borderRadius(16).backgroundColor($r('sys.color.comp_background_list_card'))
        }
        .width('100%').padding({ left: 16, right: 16, top: 12 })
        .margin({ bottom: 16 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.None)
      .scrollBar(BarState.Off)
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    }
    .titleBar({
      content: {
        title: { mainTitle: '设置' },
        menu: this.buildSettingCloseMenu()
      }
    })
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .navDestination(this.settingNavDestination)
    .width('100%')
    .height('100%')
  }

  // 标题栏右侧关闭按钮（home 与子页共用）
  private buildSettingCloseMenu(): HdsNavigationMenuContentOptions {
    return {
      value: [
        {
          content: {
            icon: new SymbolGlyphModifier($r('sys.symbol.xmark')).fontSize(24),
            action: () => { this.isShowSettingSheet = false; }
          }
        }
      ]
    };
  }

  @Builder
  settingNavDestination(name: string) {
    if (name === 'recordMode') {
      HdsNavDestination() {
        RecordModePanel({
          recordMode: this.currentMode,
          sleepModeEnabled: this.sleepModeEnabled,
          onRecordModeChange: (mode: number) => { this.onRecordModeChange(mode); },
          onSleepModeChange: (enabled: boolean) => { this.onSleepModeChange(enabled); }
        })
      }
      .titleBar({ content: { title: { mainTitle: '记录规则' }, menu: this.buildSettingCloseMenu() } })
      .hideBackButton(false)
    } else if (name === 'strategyLab') {
      HdsNavDestination() {
        StrategyLabPanel()
      }
      .titleBar({ content: { title: { mainTitle: '策略实验室' }, menu: this.buildSettingCloseMenu() } })
      .hideBackButton(false)
    } else if (name === 'location') {
      HdsNavDestination() {
        LocationPermPanel({
          permSvc: this.permSvc,
          hasApproximatelyLocation: $hasApproximatelyLocation,
          hasLocation: $hasLocation,
          hasBackgroundLocation: $hasBackgroundLocation,
          onRefreshPermission: () => { this.onRefreshPermission(); }
        })
      }
      .titleBar({ content: { title: { mainTitle: '定位权限' }, menu: this.buildSettingCloseMenu() } })
      .hideBackButton(false)
    } else if (name === 'generalSetting') {
      HdsNavDestination() {
        SettingPanel({
          nightModeIndex: $nightModeIndex,
          pushSwitchOn: $pushSwitchOn,
          onNightModeChange: (i: number) => { this.onNightModeChange(i); }
        })
      }
      .titleBar({ content: { title: { mainTitle: '通用设置' }, menu: this.buildSettingCloseMenu() } })
      .hideBackButton(false)
    } else if (name === 'privacy') {
      HdsNavDestination() {
        PrivacyPanel({ pushSwitchOn: $pushSwitchOn })
      }
      .titleBar({ content: { title: { mainTitle: '隐私设置' }, menu: this.buildSettingCloseMenu() } })
      .hideBackButton(false)
    } else if (name === 'log') {
      HdsNavDestination() {
        LogPanel({ logSvc: this.logSvc })
      }
      .titleBar({ content: { title: { mainTitle: '运行日志' }, menu: this.buildSettingCloseMenu() } })
      .hideBackButton(false)
    }
  }

  @Builder
  private buildThemeSheet(): void {
    Column() {
      Text('地图样式')
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ bottom: 12 })

      Scroll() {
        Row({ space: 12 }) {
          ForEach([
            { index: 0, label: '默认', icon: $r('app.media.map_style_classic') },
            { index: 1, label: '暗夜', icon: $r('app.media.map_style_dark') },
            { index: 2, label: '浅白', icon: $r('app.media.map_style_light') },
            { index: 3, label: '大白', icon: $r('app.media.map_style_dabai') }
          ] as Array<MapStyleGridItem>, (item: MapStyleGridItem) => {
            Column() {
              Stack({ alignContent: Alignment.TopEnd }) {
                Image(item.icon)
                  .width(72)
                  .height(72)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(10)
                  .border({
                    width: this.mapStyleIndex === item.index ? 2 : 0,
                    color: this.mapStyleIndex === item.index ? $r('sys.color.ohos_id_color_activated') : Color.Transparent,
                    style: BorderStyle.Solid
                  })

              }

              Text(item.label)
                .fontSize(12)
                .fontColor(this.mapStyleIndex === item.index
                  ? $r('sys.color.ohos_id_color_activated')
                  : $r('sys.color.font_primary'))
                .fontWeight(this.mapStyleIndex === item.index ? FontWeight.Medium : FontWeight.Regular)
                .margin({ top: 4 })
                .textAlign(TextAlign.Center)
            }
            .onClick(() => {
              this.switchMapStyle(item.index);
            })
          }, (item: MapStyleGridItem) => item.index.toString())
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')

      Text('轨迹颜色')
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 20, bottom: 12 })

      Row({ space: 16 }) {
        ForEach(TRACK_COLORS, (item: TrackColorConfig, index: number) => {
          Column() {
            Circle()
              .width(36)
              .height(36)
              .fill(item.color === 0xFFFFFFFF ? '#FFFFFF' : item.color === 0xFF000000 ? '#000000' : '#FF0000')
              .stroke(item.color === 0xFFFFFFFF ? '#E0E0E0' : Color.Transparent)
              .strokeWidth(item.color === 0xFFFFFFFF ? 1 : 0)
              .border({
                width: this.trackColorIndex === index ? 2 : 0,
                color: this.trackColorIndex === index ? $r('sys.color.ohos_id_color_activated') : Color.Transparent,
                style: BorderStyle.Solid
              })
              .borderRadius(20)

            Text(item.label)
              .fontSize(12)
              .fontColor(this.trackColorIndex === index
                ? $r('sys.color.ohos_id_color_activated')
                : $r('sys.color.font_primary'))
              .fontWeight(this.trackColorIndex === index ? FontWeight.Medium : FontWeight.Regular)
              .margin({ top: 4 })
              .textAlign(TextAlign.Center)
          }
          .onClick(() => {
            this.switchTrackColor(index);
          })
        }, (item: TrackColorConfig) => item.label)
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)

      Text('地图显示')
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 20, bottom: 12 })

      Column({ space: 12 }) {
        Row() {
          Text('3D建筑')
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.buildingEnabled })
            .selectedColor($r('sys.color.ohos_id_color_activated'))
            .onChange((isOn: boolean) => {
              this.switchBuildingEnabled(isOn);
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))

        Row() {
          Text('地名标注')
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.poiVisible })
            .selectedColor($r('sys.color.ohos_id_color_activated'))
            .enabled(this.mapStyleIndex !== 2)
            .onChange((isOn: boolean) => {
              this.switchPoiVisible(isOn);
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .opacity(this.mapStyleIndex !== 2 ? 1 : 0.4)

        Row() {
          Text('道路名称')
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.roadLabelVisible })
            .selectedColor($r('sys.color.ohos_id_color_activated'))
            .enabled(this.mapStyleIndex !== 2)
            .onChange((isOn: boolean) => {
              this.switchRoadLabelVisible(isOn);
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .opacity(this.mapStyleIndex !== 2 ? 1 : 0.4)

        Row() {
          Text('公共交通')
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.transitVisible })
            .selectedColor($r('sys.color.ohos_id_color_activated'))
            .enabled(this.mapStyleIndex !== 2)
            .onChange((isOn: boolean) => {
              this.switchTransitVisible(isOn);
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .opacity(this.mapStyleIndex !== 2 ? 1 : 0.4)

        Row() {
          Text('我的位置')
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.myLocationOn })
            .selectedColor($r('sys.color.ohos_id_color_activated'))
            .onChange((isOn: boolean) => {
              this.myLocationOn = isOn;
              if (this.mapManager.controller) {
                this.mapManager.controller.setMyLocationEnabled(isOn);
                this.mapManager.controller.setMyLocationControlsEnabled(false);
                if (!isOn) {
                  this.myLocationDisplayType = mapCommon.MyLocationDisplayType.DEFAULT;
                }
              }
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 4, bottom: 20 })
  }

  // HdsTabs MiniBar：折线/海量点模式切换
  @Builder
  private miniBarBuilder() {
    Row() {
      if (this.displayMode === 0) {
        SymbolGlyph($r('sys.symbol.waveform_folder_fill'))
          .fontSize(24)
          .fontColor([$r('sys.color.ohos_id_color_activated')])
          .transition(
            TransitionEffect.scale({ x: 0.5, y: 0.5 }).combine(TransitionEffect.opacity(0))
              .animation({ duration: 200, curve: Curve.Smooth })
          )
      } else {
        SymbolGlyph($r('sys.symbol.person_crop_circle_fill_1'))
          .fontSize(24)
          .fontColor([$r('sys.color.ohos_id_color_activated')])
          .transition(
            TransitionEffect.scale({ x: 0.5, y: 0.5 }).combine(TransitionEffect.opacity(0))
              .animation({ duration: 200, curve: Curve.Smooth })
          )
      }
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      // @SuppressWarnings permission
      // @SuppressWarnings compatibility
      try {
        vibrator.startVibration({
          type: 'preset', effectId: 'haptic.clock.timer', count: 1
        }, {
          usage: 'touch'
        }).then(() => {
        }, (error: BusinessError) => {
          hilog.warn(0x0000, TAG_LOG, 'vibrator failed: %{public}d', error.code);
        });
      } catch (err) {
        let e: BusinessError = err as BusinessError;
        hilog.warn(0x0000, TAG_LOG, 'vibrator error: %{public}d', e.code);
      }
      this.switchDisplayMode(this.displayMode === 0 ? 1 : 0);
    })
  }

}