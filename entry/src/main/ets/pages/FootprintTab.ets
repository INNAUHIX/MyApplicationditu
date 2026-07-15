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
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';

import { TrackDatabase } from '../data/TrackDatabase';
import { PermissionService } from '../service/PermissionService';
import { TrackLocationService, LocationHandlers } from '../service/TrackLocationService';
import { MapOverlayManager } from '../service/MapOverlayManager';
import { TimeViewModel } from '../viewmodel/TimeViewModel';
import { MapStyleViewModel } from '../viewmodel/MapStyleViewModel';
import { MapToolSheet } from '../components/MapToolSheet';
import { CardItem } from '../components/CardItem';
import { RecordModePanel } from '../components/RecordModePanel';
import { LocationPermPanel } from '../components/LocationPermPanel';
import { SettingPanel } from '../components/SettingPanel';
import { StrategyLabPanel } from '../components/StrategyLabPanel';
import {
  TAG, RecordMode, MODE_CONFIG, TrackPointRecord, StatDayItem,
  TIME_VIEW_OVERVIEW, TIME_VIEW_CUSTOM, TIME_VIEW_TODAY,
  ONE_DAY_MS
} from '../model/TrackTypes';
import { calculateDistance, formatDistance, getDayStartTs, getDayEndTs, computeStats as computeStatsUtil, formatStatDate } from '../common/TrackUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG_LOG: string = 'FootprintTab';

@Component
export struct FootprintTab {
  // ===== 服务实例（由 Index 传入，共享同一实例）=====
  db: TrackDatabase = new TrackDatabase();
  permSvc: PermissionService = new PermissionService();
  locationSvc: TrackLocationService = new TrackLocationService();
  mapManager: MapOverlayManager = new MapOverlayManager();
  timeModel: TimeViewModel = new TimeViewModel();
  mapStyleVM: MapStyleViewModel = new MapStyleViewModel();

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
  private lastFootprintPoint: mapCommon.LatLng | null = null;
  @State displayMode: number = 0;
  @Link immersive: boolean;
  @State isShowMapToolSheet: boolean = false;

  @State myLocationOn: boolean = false;
  @State mapStyleIndex: number = 0;
  @State timeViewSelectedIndexes: number[] = [TIME_VIEW_TODAY];
  @State display2SelectedIndexes: number[] = [0];
  @State mapStyle2SelectedIndexes: number[] = [0];

  // ===== 右侧浮层面板状态 ====
  @State isShowStatsSheet: boolean = false;
  @State isShowMineSheet: boolean = false;
  // Mine 面板子视图模式（''=主列表, recordMode/location/setting/strategyLab=子视图）
  @State mineSubviewMode: string = '';
  @State pushSwitchOn: boolean = false;

  // ===== HdsTabs 底部悬浮页签 =====
  private hdsTabsController: HdsTabsController = new HdsTabsController();
  @State tabOptions: string[] = ['总览', '自定义', '今日', '昨日'];

  // ===== 统计缓存 ====
  @State statTotalDistance: number = 0;
  @State statTrackCount: number = 0;
  @State statActiveDays: number = 0;
  @State statAvgDailyDist: number = 0;
  @State statMaxDailyDist: number = 0;
  @State statFirstTs: number = 0;
  @State statLastTs: number = 0;
  @State statRecent7: StatDayItem[] = [];

  private recordModeNames: string[] = ['均衡', '耗电'];

  // ===== 生命周期 =====
  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;

    // 恢复上次选择的地图样式，避免每次进入都被重置为经典
    this.mapStyleVM.setContext(ctx);
    const style: number = this.mapStyleVM.loadMapStyle();
    this.mapStyleIndex = style;
    this.mapStyle2SelectedIndexes = [style];

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
    this.mapOptions = this.mapManager.buildMapOptions(this.mapStyleIndex);
    this.callback = this.mapManager.buildMapCallback(
      () => { this.onMapReady(); },
      () => { this.onMapClick(); }
    );

    this.timeModel.startDayCheck(() => { this.onDayChange(); });
  }

  // ===== 统计计算 =====
  private computeStats(): void {
    const result = computeStatsUtil(this.timeModel.allPoints);
    this.statTotalDistance = result.totalDistance;
    this.statTrackCount = result.trackCount;
    this.statActiveDays = result.activeDays;
    this.statAvgDailyDist = result.avgDailyDist;
    this.statMaxDailyDist = result.maxDailyDist;
    this.statFirstTs = result.firstTs;
    this.statLastTs = result.lastTs;
    this.statRecent7 = result.recent7;
  }

  private onLayoutMetaChange(): void {
    this.mapManager.setLayoutMeta(this.navBarHeight, this.statusBarHeight);
    if (this.mapManager.controller) {
      this.mapManager.setBottomPadding(this.immersive);
    }
  }

  // ===== 核心方法 =====
  private async onMapReady(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await this.db.init(ctx);
    const records = await this.db.loadAll();
    this.timeModel.setAllPoints(records);
    await this.mapManager.createRedDotIcon();
    this.refreshVisibleView();
    await this.permissionFlow(ctx);
  }

  private onMapClick(): void {
    const next: boolean = !this.immersive;
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => { this.immersive = next; });
    this.mapManager.setBottomPadding(next);
    const controller = this.mapManager.controller;
    if (controller) {
      // 进入沉浸(next=true)时仅隐藏「我的位置」标记（视觉），退出时按用户原开关意图恢复；
      // 不修改 myLocationOn，保证面板里的开关决定权完全属于用户
      controller.setMyLocationEnabled(next ? false : this.myLocationOn);
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
      const style: mapCommon.MyLocationStyle = { displayType: mapCommon.MyLocationDisplayType.FOLLOW_ROTATE };
      await controller.setMyLocationStyle(style);
      controller.setMyLocationEnabled(true);
      controller.setMyLocationControlsEnabled(true);
      this.myLocationOn = true;
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
      this.lastFootprintPoint = latLng;
      this.mapManager.refreshOverlay(this.displayMode, this.trackPoints, this.footprintPoints);
    }
    this.db.insert(rec);
  }

  private refreshVisibleView(): void {
    const v = this.timeModel.applyTimeView();
    this.trackPoints = v.trackPoints;
    this.footprintPoints = v.footprintPoints;
    this.totalDistance = v.totalDistance;
    this.lastFootprintPoint = v.lastFootprintPoint;
    this.trackCount = v.trackPoints.length;
    if (this.timeViewIndex === TIME_VIEW_OVERVIEW) { this.displayMode = 1; this.display2SelectedIndexes = [1]; }

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

  // T024: 地图样式切换
  private switchMapStyle(index: number): void {
    if (this.mapStyleIndex === index) { return; }
    this.mapStyleIndex = index;
    this.mapStyle2SelectedIndexes = [index];
    this.mapStyleVM.saveMapStyle(index);
    this.mapManager.applyMapStyle(index);
  }

  private switchDisplayMode(mode: number): void {
    if (this.timeViewIndex === TIME_VIEW_OVERVIEW && mode === 0) { return; }
    if (this.displayMode === mode) { return; }
    this.displayMode = mode;
    this.display2SelectedIndexes = [mode];
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

      // 右侧浮层按钮组（统计 / 我的 / 地图工具）
      if (!this.immersive) {
        Column({ space: 10 }) {
          // 统计
          Row() {
            SymbolGlyph($r('sys.symbol.waveform_folder_fill')).fontSize(20).fontColor([$r('sys.color.font_primary')])
          }
          .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(16).clip(true).backdropBlur(12)
          .backgroundColor('rgba(255,255,255,0.1)').border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
          .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
          .onClick(() => {
            this.computeStats();
            this.isShowStatsSheet = true;
          })
          .bindSheet($$this.isShowStatsSheet, this.buildStatsSheet(), {
            detents: [SheetSize.MEDIUM, SheetSize.LARGE], title: { title: '足迹统计' },
            dragBar: true, showClose: true, onDisappear: () => { this.isShowStatsSheet = false; }
          })

          // 我的
          Row() {
            SymbolGlyph($r('sys.symbol.person_crop_circle_fill_1')).fontSize(20).fontColor([$r('sys.color.font_primary')])
          }
          .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(16).clip(true).backdropBlur(12)
          .backgroundColor('rgba(255,255,255,0.1)').border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
          .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
          .onClick(() => { this.isShowMineSheet = true; })
          .bindSheet($$this.isShowMineSheet, this.buildMineSheet(), {
            detents: [SheetSize.MEDIUM, SheetSize.LARGE], title: { title: '我的' },
            dragBar: true, showClose: true, onDisappear: () => {
              this.isShowMineSheet = false;
              this.mineSubviewMode = '';
            }
          })

          // 地图工具
          Row() {
            SymbolGlyph($r('sys.symbol.paintpalette_fill')).fontSize(20).fontColor([$r('sys.color.font_primary')])
          }
          .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(16).clip(true).backdropBlur(12)
          .backgroundColor('rgba(255,255,255,0.1)').border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
          .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
          .onClick(() => { this.isShowMapToolSheet = true; })
          .bindSheet($$this.isShowMapToolSheet, this.buildMapToolSheet(), {
            detents: [SheetSize.MEDIUM, SheetSize.LARGE], title: { title: '地图工具' },
            dragBar: true, showClose: true, onDisappear: () => { this.isShowMapToolSheet = false; }
          })
        }
        .alignItems(HorizontalAlign.End)
        .position({ x: '100%', y: '54%' }).markAnchor({ x: '100%', y: '50%' }).translate({ x: -16 })
        .transition({ type: TransitionType.All, opacity: 0, translate: { x: 16, y: 0 } })
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
          normal: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1'))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_primary')]),
          selected: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1'))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_activated')])
        }, '今日'))

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
        }, '昨日'))
      }
      .barOverlap(true)
      .vertical(false)
      .barPosition(BarPosition.End)
      .scrollable(false)
      .onChange((index: number) => { this.onTimeViewSelected(index); })
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

  // 地图工具面板（委托给 MapToolSheet 子组件）
  @Builder
  private buildMapToolSheet(): void {
    MapToolSheet({
      displayMode: $displayMode,
      mapStyleIndex: $mapStyleIndex,
      myLocationOn: $myLocationOn,
      timeViewIndex: $timeViewIndex,
      display2SelectedIndexes: $display2SelectedIndexes,
      mapStyle2SelectedIndexes: $mapStyle2SelectedIndexes,
      onSwitchDisplayMode: (mode: number) => { this.switchDisplayMode(mode); },
      onSwitchMapStyle: (index: number) => { this.switchMapStyle(index); },
      onToggleMyLocation: (isOn: boolean) => {
        if (this.mapManager.controller) {
          this.mapManager.controller.setMyLocationEnabled(isOn);
          this.mapManager.controller.setMyLocationControlsEnabled(isOn);
        }
      }
    })
  }

  // HdsTabs MiniBar：折线/海量点模式切换
  @Builder
  private miniBarBuilder() {
    Row() {
      SymbolGlyph(this.displayMode === 0
        ? $r('sys.symbol.waveform_folder_fill')
        : $r('sys.symbol.person_crop_circle_fill_1'))
        .fontSize(24)
        .fontColor([$r('sys.color.ohos_id_color_activated')])
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.switchDisplayMode(this.displayMode === 0 ? 1 : 0);
    })
  }

  // 统计面板
  @Builder
  private buildStatsSheet(): void {
    Column() {
      if (this.statTrackCount === 0) {
        Column() {
          Text('暂无足迹数据')
            .fontSize(14).fontColor($r('sys.color.font_primary')).opacity(0.5)
        }
        .width('100%').alignItems(HorizontalAlign.Center).padding({ top: 40, bottom: 40 })
      } else {
        Scroll() {
          Column({ space: 12 }) {
            // 指标行
            Row({ space: 12 }) {
              this.buildStatItem(`${(this.statTotalDistance / 1000).toFixed(2)} km`, '累计里程')
              this.buildStatItem(`${this.statTrackCount}`, '足迹点')
              this.buildStatItem(`${this.statActiveDays} 天`, '记录天数')
            }
            .width('100%')

            Column({ space: 12 }) {
              Row({ space: 12 }) {
                this.buildStatItemFormatted(formatDistance(this.statAvgDailyDist), '平均每日')
                this.buildStatItemFormatted(formatDistance(this.statMaxDailyDist), '最长单日')
              }
              .width('100%')

              Row({ space: 12 }) {
                this.buildStatItemFormatted(formatStatDate(this.statFirstTs), '首次记录')
                this.buildStatItemFormatted(formatStatDate(this.statLastTs), '最近记录')
              }
              .width('100%')
            }
            .width('100%').backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(16).padding(16)

            // 最近 7 天
            Column({ space: 10 }) {
              Text('最近 7 天').fontSize(16).fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary')).width('100%')
              ForEach(this.statRecent7, (item: StatDayItem) => {
                Row() {
                  Text(item.label).fontSize(12).fontColor($r('sys.color.font_primary')).opacity(0.7)
                  Blank()
                  Text(`${item.count} 点 · ${formatDistance(item.distance)}`)
                    .fontSize(12).fontColor($r('sys.color.font_primary')).opacity(0.7)
                }
                .width('100%').justifyContent(FlexAlign.SpaceBetween)
              }, (item: StatDayItem) => item.label)
            }
            .width('100%').backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(16).padding(16)
          }
          .width('100%').padding({ left: 16, right: 16, top: 12 })
        }
        .layoutWeight(1)
      }
    }
    .width('100%').height('100%').backgroundColor($r('sys.color.background_secondary'))
  }

  // 我的面板（含子视图条件切换）
  @Builder
  private buildMineSheet(): void {
    Column() {
      if (this.mineSubviewMode === 'recordMode') {
        // 记录规则子视图
        this.recordModeSheet()
      } else if (this.mineSubviewMode === 'location') {
        // 定位权限子视图
        this.locationSheet()
      } else if (this.mineSubviewMode === 'setting') {
        // 设置子视图
        this.settingSheet()
      } else if (this.mineSubviewMode === 'strategyLab') {
        // 策略实验室子视图
        this.strategyLabSheet()
      } else {
        // 主列表
        Scroll() {
          Column({ space: 16 }) {
            Column() {
              CardItem({
                label: '记录规则',
                symbol: $r('sys.symbol.local_badge_gearshape'),
                statusText: this.recordModeNames[this.currentMode],
                statusColor: $r('sys.color.font_secondary'),
                onClickEvent: () => { this.mineSubviewMode = 'recordMode'; }
              })
              Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
              CardItem({
                label: '策略实验室',
                symbol: $r('sys.symbol.person_shield_fill'),
                onClickEvent: () => { this.mineSubviewMode = 'strategyLab'; }
              })
              Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
              CardItem({
                label: '定位权限',
                symbol: $r('sys.symbol.position_badge_exclamationmark'),
                statusText: (!this.hasApproximatelyLocation || !this.hasLocation || !this.hasBackgroundLocation) ? '权限异常' : '',
                statusColor: $r('sys.color.ohos_id_color_warning'),
                onClickEvent: () => {
                  this.onRefreshPermission();
                  this.mineSubviewMode = 'location';
                }
              })
              Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
              CardItem({
                label: '设置',
                symbol: $r('sys.symbol.gearshape'),
                onClickEvent: () => { this.mineSubviewMode = 'setting'; }
              })
            }
            .width('100%').borderRadius(16).backgroundColor($r('sys.color.comp_background_list_card'))
          }
          .width('100%').padding({ left: 16, right: 16, top: 12 })
          .margin({ bottom: 16 })
        }
        .layoutWeight(1)
      }
    }
    .width('100%').height('100%').backgroundColor($r('sys.color.background_secondary'))
  }

  // 统计面板内的指标项（纯数字）
  @Builder
  private buildStatItem(value: string, label: string): void {
    Column({ space: 4 }) {
      Text(value).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
      Text(label).fontSize(12).fontColor($r('sys.color.font_primary')).opacity(0.6)
    }
    .layoutWeight(1).backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius(16).padding(16).alignItems(HorizontalAlign.Center)
  }

  // 统计面板内的指标项（格式化值）
  @Builder
  private buildStatItemFormatted(value: string, label: string): void {
    Column({ space: 2 }) {
      Text(value).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
      Text(label).fontSize(12).fontColor($r('sys.color.font_primary')).opacity(0.6)
    }
    .layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  // Mine 子面板
  @Builder
  private recordModeSheet(): void {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24).fontColor([$r('sys.color.ohos_id_color_activated')])
          .margin({ left: 12 })
          .onClick(() => { this.mineSubviewMode = ''; })
        Text('记录规则').fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary')).margin({ left: 8 })
      }
      .width('100%').height(56).alignItems(VerticalAlign.Center)

      RecordModePanel({
        recordMode: this.currentMode,
        sleepModeEnabled: this.sleepModeEnabled,
        onRecordModeChange: (mode: number) => { this.onRecordModeChange(mode); },
        onSleepModeChange: (enabled: boolean) => { this.onSleepModeChange(enabled); }
      })
    }
  }

  @Builder
  private locationSheet(): void {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24).fontColor([$r('sys.color.ohos_id_color_activated')])
          .margin({ left: 12 })
          .onClick(() => { this.mineSubviewMode = ''; })
        Text('定位权限').fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary')).margin({ left: 8 })
      }
      .width('100%').height(56).alignItems(VerticalAlign.Center)

      LocationPermPanel({
        permSvc: this.permSvc,
        hasApproximatelyLocation: $hasApproximatelyLocation,
        hasLocation: $hasLocation,
        hasBackgroundLocation: $hasBackgroundLocation,
        onRefreshPermission: () => { this.onRefreshPermission(); }
      })
    }
  }

  @Builder
  private settingSheet(): void {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24).fontColor([$r('sys.color.ohos_id_color_activated')])
          .margin({ left: 12 })
          .onClick(() => { this.mineSubviewMode = ''; })
        Text('设置').fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary')).margin({ left: 8 })
      }
      .width('100%').height(56).alignItems(VerticalAlign.Center)

      SettingPanel({
        nightModeIndex: $nightModeIndex,
        pushSwitchOn: $pushSwitchOn,
        onNightModeChange: (i: number) => { this.onNightModeChange(i); }
      })
    }
  }

  @Builder
  private strategyLabSheet(): void {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24).fontColor([$r('sys.color.ohos_id_color_activated')])
          .margin({ left: 12 })
          .onClick(() => { this.mineSubviewMode = ''; })
        Text('策略实验室').fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary')).margin({ left: 8 })
      }
      .width('100%').height(56).alignItems(VerticalAlign.Center)

      StrategyLabPanel()
    }
  }
}
