/**
 * FootprintTab.ets —— 足迹地图 Tab 组件
 *
 * 从 Index 拆出的独立 Tab 组件，承载：
 *   - 全屏地图（MapComponent + 覆盖物）
 *   - 左上角统计胶囊（足迹点 / 轨迹线里程）
 *   - 右上角时间范围切换（总览 / 自定义 / 今日）
 *   - 右下角地图工具入口胶囊（轨迹切换 / 地图样式 / 我的位置）
 *   - 定位采样回调 + 权限流程 + 日期选择 + 地图样式切换
 */

import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { SymbolGlyphModifier, SegmentButton, SegmentButtonOptions, ItemRestriction, SegmentButtonTextItem } from '@kit.ArkUI';
import { TrackDatabase } from '../data/TrackDatabase';
import { PermissionService } from '../service/PermissionService';
import { TrackLocationService, LocationHandlers } from '../service/TrackLocationService';
import { MapOverlayManager } from '../service/MapOverlayManager';
import { TimeViewModel } from '../viewmodel/TimeViewModel';
import { MapStyleViewModel } from '../viewmodel/MapStyleViewModel';
import { MapToolSheet } from '../components/MapToolSheet';
import {
  TAG, RecordMode, MODE_CONFIG, TrackPointRecord,
  TIME_VIEW_OVERVIEW, TIME_VIEW_CUSTOM, TIME_VIEW_TODAY,
  ONE_DAY_MS
} from '../model/TrackTypes';
import { calculateDistance, formatDistance, getDayStartTs, getDayEndTs, getDayKey } from '../common/TrackUtils';

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

  // ===== 跨 Tab 双向状态（与 Index @State 双向同步，Mine/StatsTab 共享）=====
  @Link currentMode: RecordMode;
  @Link isStationary: boolean;
  @Link trackCount: number;
  @Link totalDistance: number;

  @Link timeViewIndex: number;
  @Link hasApproximatelyLocation: boolean;
  @Link hasLocation: boolean;
  @Link hasBackgroundLocation: boolean;
  @Link nightModeIndex: number;

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

  // 时间视图分段按钮选项（保留在 FootprintTab 内，因为是顶部浮层直接使用的）
  @State timeViewSegmentOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [
      { text: '总览' },
      { text: '自定义' },
      { text: '今日' }
    ] as ItemRestriction<SegmentButtonTextItem>,
    selectedBackgroundColor: $r('sys.color.ohos_id_color_activated'),
    fontColor: $r('sys.color.font_secondary'),
    selectedFontColor: $r('sys.color.ohos_id_color_primary_contrary'),
    fontSize: 14, selectedFontSize: 14,
    fontWeight: FontWeight.Regular, selectedFontWeight: FontWeight.Medium,
    buttonPadding: { top: 8, right: 10, bottom: 8, left: 10 }
  });

  // ===== 生命周期 =====
  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;

    // 恢复上次选择的地图样式，避免每次进入都被重置为经典
    this.mapStyleVM.setContext(ctx);
    const style: number = this.mapStyleVM.loadMapStyle();
    this.mapStyleIndex = style;
    this.mapStyle2SelectedIndexes = [style];

    // 恢复「时间范围」视图选择（默认今日）与自定义起止日期
    this.timeModel.setContext(ctx);
    this.timeModel.loadPrefs();
    this.timeViewIndex = this.timeModel.timeView;
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

  private onLayoutMetaChange(): void {
    this.mapManager.setLayoutMeta(this.navBarHeight, this.statusBarHeight);
    if (this.mapManager.controller) {
      this.mapManager.setBottomPadding(this.immersive);
    }
  }

  // ===== 核心方法 =====
  private async onMapReady(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await this.db.init(ctx);
    const records = await this.db.loadAll();
    this.timeModel.setAllPoints(records);
    if (records.length > 0) {
      const last = records[records.length - 1];
      this.locationSvc.setLastRecordedPoint(
        { latitude: last.latitude, longitude: last.longitude },
        getDayKey(last.timestamp)
      );
    }

    await this.mapManager.createRedDotIcon();
    this.refreshVisibleView();
    await this.permissionFlow(ctx);
  }

  private onMapClick(): void {
    const next: boolean = !this.immersive;
    animateTo({ duration: 300, curve: Curve.EaseInOut }, () => { this.immersive = next; });
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
      const res = await this.permSvc.requestPermissions(ctx);
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
      console.error(`Failed to set my location style, code: ${error.code}, message: ${error.message}`);
      this.myLocationOn = false;
    }
    try {
      const currentLocation = await geoLocationManager.getCurrentLocation();
      const gcj02Location = await map.convertCoordinate(
        mapCommon.CoordinateType.WGS84, mapCommon.CoordinateType.GCJ02,
        { latitude: currentLocation.latitude, longitude: currentLocation.longitude }
      );
      controller?.moveCamera(map.newCameraPosition({ target: gcj02Location, zoom: 15 }));
    } catch (err) {
      const error = err as BusinessError;
      console.warn(`Failed to move camera to current location, code: ${error.code}, message: ${error.message}`);
    }
    this.locationSvc.startLocation({
      onSample: (latLng: mapCommon.LatLng, accuracy: number, speed: number, timestamp?: number) => { this.onLocationSample(latLng, accuracy, speed, timestamp); }
    });
    this.isStationary = this.locationSvc.stationary;
  }

  private onLocationSample(latLng: mapCommon.LatLng, accuracy: number, speed: number, timestamp?: number, isInitial?: boolean): void {
    this.isStationary = this.locationSvc.stationary;

    this.recordTrackPoint(latLng, accuracy, speed, timestamp, isInitial);
  }

  private recordTrackPoint(latLng: mapCommon.LatLng, accuracy: number, speed: number, timestamp?: number, isInitial?: boolean): void {
    const ts: number = timestamp ?? Date.now();
    const rec: TrackPointRecord = { latitude: latLng.latitude, longitude: latLng.longitude, timestamp: ts, accuracy: accuracy, speed: speed };
    this.timeModel.addPoint(rec);
    if (this.timeModel.isInVisibleRange(ts)) {
      const prevLast: mapCommon.LatLng | null = this.trackPoints.length > 0 ? this.trackPoints[this.trackPoints.length - 1] : null;
      if (!isInitial) {
        this.trackPoints.push(latLng);
      }
      this.trackCount = this.trackPoints.length;
      if (!isInitial && prevLast) { this.totalDistance += calculateDistance(prevLast, latLng); }
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

  // T023: 时间视图切换 + 日期选择
  private onTimeViewSelected(index: number): void {
    this.timeViewIndex = index;
    this.timeViewSelectedIndexes = [index];
    if (this.timeModel.onTimeViewSelected(index)) { this.showCustomDatePicker(); } else { this.refreshVisibleView(); }
  }

  private showCustomDatePicker(): void {
    const todayStart: number = getDayStartTs(Date.now());
    const yesterdayStart: number = getDayStartTs(Date.now() - ONE_DAY_MS);
    const yesterdayEnd: number = getDayEndTs(Date.now() - ONE_DAY_MS);
    DatePickerDialog.show({
      start: new Date(todayStart - 365 * ONE_DAY_MS), end: new Date(yesterdayEnd), selected: new Date(this.timeModel.customStart > 0 ? this.timeModel.customStart : yesterdayStart),
      onAccept: (value: DatePickerResult) => {
        const s: number = getDayStartTs(new Date(value.year, value.month ?? 0, value.day ?? 1).getTime());
        const e: number = getDayEndTs(s);
        this.timeModel.setCustomRange(s, e);
        this.refreshVisibleView();
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

  // 组件销毁：停止定位、落库定时器、跨日检测
  aboutToDisappear(): void {
    this.locationSvc.stopLocation();

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
        if (this.isStationary) {
          Row() {
            SymbolGlyph($r('sys.symbol.local_fill')).fontSize(16).fontColor([$r('sys.color.font_primary')])
            Text('常驻点激活').fontSize(13).fontColor($r('sys.color.font_primary')).fontWeight(FontWeight.Medium).margin({ left: 4 })
          }
          .padding({ left: 10, right: 12, top: 6, bottom: 6 }).borderRadius(16).clip(true).backdropBlur(12)
          .backgroundColor('rgba(255,255,255,0.1)').border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
          .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
        }
      }
      .alignItems(HorizontalAlign.Start).position({ x: 12, y: 12 + this.statusBarHeight })

      // 右上角时间范围切换
      if (!this.immersive) {
        Row() {
          SegmentButton({ options: this.timeViewSegmentOptions, selectedIndexes: $timeViewSelectedIndexes,
            onItemClicked: (index: number) => { this.onTimeViewSelected(index); }
          }).width(210).backgroundColor('rgba(0,0,0,0)')
        }
        .padding({ left: 4, right: 4, top: 4, bottom: 4 }).borderRadius(20).clip(true).backdropBlur(12)
        .backgroundColor('rgba(255,255,255,0.1)').border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
        .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
        .position({ x: '100%', y: 12 + this.statusBarHeight }).markAnchor({ x: '100%', y: 0 }).offset({ x: -16, y: 0 })
        .transition({ type: TransitionType.All, opacity: 0, translate: { x: 0, y: -16 } })
      }

      // 右侧地图工具入口
      if (!this.immersive) {
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
        .position({ x: '100%', y: '60%' }).markAnchor({ x: '100%', y: '50%' }).translate({ x: -16 })
        .transition({ type: TransitionType.All, opacity: 0, translate: { x: 16, y: 0 } })
      }

      // 右侧新增胶囊（地图工具入口胶囊下方），纯图标，暂不绑定点击
      if (!this.immersive) {
        Row() {
          SymbolGlyph($r('sys.symbol.Investment_stable_value_add')).fontSize(20).fontColor([$r('sys.color.font_primary')])
        }
        .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(16).clip(true).backdropBlur(12)
        .backgroundColor('rgba(255,255,255,0.1)').border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
        .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
        .position({ x: '100%', y: '60%' }).markAnchor({ x: '100%', y: '50%' }).translate({ x: -16, y: 50 })  // 紧贴画板正下方 10vp（两胶囊半高各约20 + 间距10）
        .transition({ type: TransitionType.All, opacity: 0, translate: { x: 16, y: 0 } })
      }
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
}
