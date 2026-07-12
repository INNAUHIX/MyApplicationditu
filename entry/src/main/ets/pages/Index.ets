/**
 * Index.ets —— 应用主页面（地图 / 轨迹记录 / 「我的」）—— 重构后的编排层
 *
 * 本文件仅负责：UI 渲染（build + 半模态面板）与跨服务编排。
 * 具体逻辑已下沉到独立模块：
 *   - model/TrackTypes.ets        公共类型与常量
 *   - util/TrackUtils.ets         纯函数（距离/日期/统计）
 *   - data/TrackDatabase.ets      本地轨迹数据库（RDB + 批量落库）
 *   - location/PermissionService  定位权限
 *   - location/TrackLocationService  实时定位采样（转换/驻留/精度过滤）
 *   - map/MapOverlayManager       地图覆盖物与样式/昼夜/3D
 *   - state/TimeViewModel         全量轨迹缓存 + 时间视图 + 跨日检测 + 偏好
 *
 * 关键数据流：
 *  定位采样 → onLocationSample → recordTrackPoint → db.enqueue(落库) → 刷新覆盖物
 */

import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { preferences } from '@kit.ArkData';
import { HdsNavigation, HdsTabs, HdsTabsController, HdsAnimationMode, hdsMaterial } from '@kit.UIDesignKit';
import {
  SymbolGlyphModifier,
  SegmentButton,
  SegmentButtonOptions,
  ItemRestriction,
  SegmentButtonIconTextItem,
  SegmentButtonTextItem,
  window
} from '@kit.ArkUI';
import { Mine } from './Mine';

import { TrackDatabase } from '../data/TrackDatabase';
import { PermissionService } from '../location/PermissionService';
import { TrackLocationService } from '../location/TrackLocationService';
import { MapOverlayManager } from '../map/MapOverlayManager';
import { TimeViewModel } from '../state/TimeViewModel';
import {
  TAG,
  RecordMode,
  MODE_CONFIG,
  TrackPointRecord,
  StatDayItem,
  TIME_VIEW_OVERVIEW,
  TIME_VIEW_CUSTOM,
  PREF_NAME,
  PREF_KEY_MAP_STYLE,
  SHAKE_FLOOR_OPTIONS,
  STATIONARY_SPEED
} from '../model/TrackTypes';
import { calculateDistance, computeStats as computeStatsUtil, formatDistance, formatStatDate } from '../util/TrackUtils';

@Entry
@Component
struct Index {
  // ===== 服务实例 =====
  private db: TrackDatabase = new TrackDatabase();
  private permSvc: PermissionService = new PermissionService();
  private locationSvc: TrackLocationService = new TrackLocationService();
  private mapManager: MapOverlayManager = new MapOverlayManager();
  private timeModel: TimeViewModel = new TimeViewModel();

  // ===== 地图相关状态（页面持有，供 UI / 覆盖物刷新读取）=====
  private mapOptions?: mapCommon.MapOptions;
  private callback?: AsyncCallback<map.MapComponentController>;
  // 当前实时位置（仅过精度门槛即采纳，不入库），用于实时连线，不影响 trackPoints 的防漂移落库逻辑
  private liveLocation: mapCommon.LatLng | null = null;
  @State trackPoints: mapCommon.LatLng[] = [];
  @State footprintPoints: mapCommon.LatLng[] = [];
  private lastFootprintPoint: mapCommon.LatLng | null = null;

  @State displayMode: number = 0; // 轨迹展示方式：0=折线，1=海量点（非夜间模式）
  // 状态栏高度（vp）：页面忽略安全区后内容会延伸到状态栏下方，顶部浮层 UI 需下移此高度避开状态栏
  @State statusBarHeight: number = 0;
  // 系统底部导航条高度（vp），内容（悬浮底栏 + 地图控件）据此抬升以避让导航条
  @State navBarHeight: number = 0;
  @State selectedIndexes: number[] = [0]; // 与 displayMode 同步，供 SegmentButton 的 @Link selectedIndexes 使用
  // 轨迹类型分段按钮（官方 SegmentButton 组件）：0=折线轨迹，1=海量点
  @State trajectorySegmentOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [
      {
        icon: $r('app.media.ic_trajectory_line'),
        selectedIcon: $r('app.media.ic_trajectory_line_selected'),
        text: '折线轨迹'
      },
      {
        icon: $r('app.media.ic_trajectory_points'),
        selectedIcon: $r('app.media.ic_trajectory_points_selected'),
        text: '海量点'
      }
    ] as ItemRestriction<SegmentButtonIconTextItem>,
    selectedBackgroundColor: $r('sys.color.ohos_id_color_activated'),
    fontColor: $r('sys.color.font_secondary'),
    selectedFontColor: $r('sys.color.ohos_id_color_primary_contrary'),
    fontSize: 14,
    selectedFontSize: 14,
    fontWeight: FontWeight.Regular,
    selectedFontWeight: FontWeight.Medium
  });
  @State demoSelectedIndex: number = 0;
  @State display2SegmentOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [
      { text: '折线' },
      { text: '海量点' }
    ] as ItemRestriction<SegmentButtonTextItem>,
    selectedBackgroundColor: $r('sys.color.ohos_id_color_activated'),
    fontColor: $r('sys.color.font_secondary'),
    selectedFontColor: $r('sys.color.ohos_id_color_primary_contrary'),
    fontSize: 14,
    selectedFontSize: 14,
    fontWeight: FontWeight.Regular,
    selectedFontWeight: FontWeight.Medium,
    buttonPadding: { top: 10, right: 4, bottom: 10, left: 4 }
  });
  @State display2SelectedIndexes: number[] = [0];
  @State mapStyleSegmentOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [
      { text: '经典' },
      { text: '暗夜' },
      { text: '浅白' },
      { text: '测试' }
    ] as ItemRestriction<SegmentButtonTextItem>,
    selectedBackgroundColor: $r('sys.color.ohos_id_color_activated'),
    fontColor: $r('sys.color.font_secondary'),
    selectedFontColor: $r('sys.color.ohos_id_color_primary_contrary'),
    fontSize: 14,
    selectedFontSize: 14,
    fontWeight: FontWeight.Regular,
    selectedFontWeight: FontWeight.Medium,
    buttonPadding: { top: 10, right: 4, bottom: 10, left: 4 }
  });
  // 当前定位记录模式（默认平衡）；折线按模式间隔采样，足迹点按模式距离门槛稀疏
  @State currentMode: RecordMode = RecordMode.BALANCED;
  @State isStationary: boolean = false;

  private tabsController: HdsTabsController = new HdsTabsController();
  @State customMaterialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;
  @State hasApproximatelyLocation: boolean = false;
  @State hasLocation: boolean = false;
  @State hasBackgroundLocation: boolean = false;
  @State nightModeIndex: number = 0; // 地图日/夜间模式：0=跟随系统，1=普通，2=夜间
  @State showDisplayModePopup: boolean = false;
  @State pushSwitchOn: boolean = true;
  @State immersive: boolean = false; // 沉浸模式：true=隐藏叠加 UI，只显示地图
  @State customSwitchOn: boolean = true;
  @State customSelectIndex: number = 0;
  @State showCustomSelectPopup: boolean = false;
  @State shakeFloorIndex: number = 0; // 抖动地板阈值档位：0=5米，1=10米，2=15米
  @State isShowMapToolSheet: boolean = false; // 地图工具半模态面板显隐（由足迹页右下角胶囊触发）
  @State myLocationOn: boolean = true; // "我的位置"图层开关：true=显示蓝色定位点（自定义开关，置于地图工具面板）
  @State mapStyleIndex: number = 0; // 地图样式：0=经典(暗色)，1=暗夜，2=浅白
  @State mapStyle2SelectedIndexes: number[] = [0];

  @State trackCount: number = 0;       // 当前可见（按时间视图过滤后）轨迹点数量
  @State totalDistance: number = 0;    // 当前可见累计里程（米），由相邻轨迹点距离累加

  // ===== 足迹统计（基于全量 allTrackPoints 派生）=====
  @State statTotalDistance: number = 0; // 全量累计里程（米）
  @State statTrackCount: number = 0;    // 全量足迹点总数
  @State statActiveDays: number = 0;    // 有记录的活跃天数
  @State statAvgDailyDist: number = 0;  // 平均每日里程（米）= 总里程 / 活跃天数
  @State statMaxDailyDist: number = 0;  // 最长单日里程（米）
  @State statFirstTs: number = 0;       // 首条记录时间戳
  @State statLastTs: number = 0;        // 末条记录时间戳
  @State statRecent7: StatDayItem[] = []; // 最近 7 天每日里程与点数

  // ===== 时间范围视图（足迹按天查看）=====
  @State timeViewIndex: number = 2;     // 0=总览 / 1=自定义 / 2=今日（默认今日）
  @State timeViewSelectedIndexes: number[] = [2];
  @State customStartTs: number = 0;     // 自定义起止日期（归一为当天 0 点 / 23:59:59.999）
  @State customEndTs: number = 0;

  // 顶部「时间范围」分段控件（总览 / 自定义 / 今日），玻璃拟态风格与现有胶囊一致
  @State timeViewSegmentOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [
      { text: '总览' },
      { text: '自定义' },
      { text: '今日' }
    ] as ItemRestriction<SegmentButtonTextItem>,
    selectedBackgroundColor: $r('sys.color.ohos_id_color_activated'),
    fontColor: $r('sys.color.font_secondary'),
    selectedFontColor: $r('sys.color.ohos_id_color_primary_contrary'),
    fontSize: 14,
    selectedFontSize: 14,
    fontWeight: FontWeight.Regular,
    selectedFontWeight: FontWeight.Medium,
    buttonPadding: { top: 8, right: 10, bottom: 8, left: 10 }
  });

  // ===== 生命周期 =====
  aboutToAppear(): void {
    // 恢复上次选择的地图样式，避免每次进入都被重置为经典
    let savedStyle: number = this.loadMapStyle();
    this.mapStyleIndex = savedStyle;
    this.mapStyle2SelectedIndexes = [savedStyle];
    // 恢复「时间范围」视图选择（默认今日）与自定义起止日期
    this.timeModel.setContext(getContext(this) as common.UIAbilityContext);
    this.timeModel.loadPrefs();
    this.timeViewIndex = this.timeModel.timeView;
    this.timeViewSelectedIndexes = [this.timeViewIndex];
    this.customStartTs = this.timeModel.customStart;
    this.customEndTs = this.timeModel.customEnd;

    // 地图管理器的尺寸/样式元信息 + 初始参数与回调
    this.mapManager.setLayoutMeta(this.navBarHeight, this.statusBarHeight);
    this.mapManager.setInitialMapStyle(this.mapStyleIndex);
    this.mapOptions = this.mapManager.buildMapOptions(this.mapStyleIndex);
    this.callback = this.mapManager.buildMapCallback(
      () => { this.onMapReady(); },
      () => { this.onMapClick(); }
    );

    this.mapManager.createRedDotIcon().then(() => {
      if (this.displayMode === 1 && this.trackPoints.length > 0) {
        this.mapManager.rebuildOverlay(this.displayMode, this.trackPoints, this.footprintPoints, this.liveLocation);
      }
    });

    let materialTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    if (materialTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0) {
      this.customMaterialLevel = hdsMaterial.MaterialLevel.SMOOTH;
    }

    // 获取状态栏/导航条高度：地图沉浸全屏，顶部浮层需据此下移避开状态栏
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      window.getLastWindow(ctx).then((win: window.Window) => {
        let avoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        this.statusBarHeight = px2vp(avoidArea.topRect.height);
        // 系统底部导航条高度：地图/悬浮底栏/地图控件需据此避让，避免压在导航条上
        this.navBarHeight = px2vp(avoidArea.bottomRect.height);
        // 异步拿到导航条高度后重新应用地图底部留白（初始 setPadding 可能先于此处执行）
        this.mapManager.setLayoutMeta(this.navBarHeight, this.statusBarHeight);
        if (this.mapManager.controller) {
          this.mapManager.setBottomPadding(this.immersive);
        }
      }).catch((err: BusinessError) => {
        console.error(TAG, `getLastWindow failed, code: ${err.code}, message: ${err.message}`);
      });
    } catch (e) {
      console.error(TAG, `get statusBarHeight failed: ${JSON.stringify(e)}`);
    }

    // 启动批量落库定时器
    this.db.startFlushTimer();
    // 启动跨日检测：每分钟比对日期 key，跨过午夜(00:00)时自动刷新「今日」视图
    this.timeModel.startDayCheck(() => { this.onDayChange(); });
  }

  // 每次回到前台：恢复地图显示，并刷新三项定位权限状态
  onPageShow(): void {
    if (this.mapManager.controller) {
      this.mapManager.controller.show();
    }
    this.refreshPermissionState();
  }

  // 切到后台：隐藏地图以释放 GPU 资源
  onPageHide(): void {
    if (this.mapManager.controller) {
      this.mapManager.controller.hide();
    }
  }

  // 页面销毁：注销定位监听、停止落库定时器并补齐未落库的点、停止跨日检测
  aboutToDisappear(): void {
    this.locationSvc.stopLocation();
    this.db.stopFlushTimer();
    this.timeModel.stopDayCheck();
  }

  // 地图就绪回调：开启 3D（已在管理器回调内完成）、定位首帧样式，随后初始化数据库、载入历史、
  // 渲染可见集与统计，并按权限流程开启「我的位置」与定位订阅
  private async onMapReady(): Promise<void> {
    let ctx = getContext(this) as common.UIAbilityContext;
    await this.db.init(ctx);
    let records = await this.db.loadAll();
    this.timeModel.setAllPoints(records);
    this.refreshVisibleView();
    this.computeStats();
    await this.permissionFlow(ctx);
  }

  // 点击地图空白区域切换沉浸模式：第一次进入纯净地图，再点一次恢复叠加 UI
  private onMapClick(): void {
    const next = !this.immersive;
    animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
      this.immersive = next;
    });
    // 沉浸模式隐藏 tab 栏时控件避让系统导航条；普通模式上移到 tab 栏上方（含系统导航条高度避让）
    this.mapManager.setBottomPadding(next);
    if (next) {
      this.tabsController.applyHideAnimation(HdsAnimationMode.CLICK_ANIMATION);
    } else {
      this.tabsController.applyShowAnimation(HdsAnimationMode.CLICK_ANIMATION);
    }
  }

  // 权限编排：刷新状态 → 缺前台则申请 → 否则缺后台则引导 → 均满足后开启我的位置与订阅
  private async permissionFlow(ctx: common.UIAbilityContext): Promise<void> {
    let state = await this.permSvc.refreshPermissionState();
    this.hasApproximatelyLocation = state.hasApproximatelyLocation;
    this.hasLocation = state.hasLocation;
    this.hasBackgroundLocation = state.hasBackgroundLocation;

    if (!state.hasApproximatelyLocation || !state.hasLocation) {
      let res = await this.permSvc.requestPermissions(ctx);
      this.hasApproximatelyLocation = res.hasApproximatelyLocation;
      this.hasLocation = res.hasLocation;
      this.hasBackgroundLocation = res.hasBackgroundLocation;
      if (res.hasApproximatelyLocation && res.hasLocation) {
        if (!res.hasBackgroundLocation) {
          this.permSvc.requestBackgroundLocationPermission(this.getUIContext());
        }
        this.enableMyLocation();
      }
    } else {
      if (!state.hasBackgroundLocation) {
        this.permSvc.requestBackgroundLocationPermission(this.getUIContext());
      }
      this.enableMyLocation();
    }
  }

  // 开启「我的位置」图层：设置定位样式、移动相机到当前位置(WGS84→GCJ02 转换)，并启动定位订阅
  private async enableMyLocation(): Promise<void> {
    let controller = this.mapManager.controller;
    if (!controller) {
      console.warn(TAG, 'mapController is null');
      return;
    }
    try {
      let style: mapCommon.MyLocationStyle = {
        displayType: mapCommon.MyLocationDisplayType.FOLLOW_ROTATE
      };
      await controller.setMyLocationStyle(style);
      controller.setMyLocationEnabled(true);
      controller.setMyLocationControlsEnabled(true);
      this.myLocationOn = true;
      console.info(TAG, 'My location enabled');

      let currentLocation = await geoLocationManager.getCurrentLocation();
      let gcj02Location = await map.convertCoordinate(
        mapCommon.CoordinateType.WGS84,
        mapCommon.CoordinateType.GCJ02,
        { latitude: currentLocation.latitude, longitude: currentLocation.longitude }
      );
      let cameraPosition = map.newCameraPosition({
        target: gcj02Location,
        zoom: 15
      });
      controller.moveCamera(cameraPosition);
      console.info(TAG, `Camera moved to user location: ${gcj02Location.latitude}, ${gcj02Location.longitude}`);

      // 启动定位订阅：经转换 / 驻留 / 精度过滤后的干净采样点交给页面做 5m 地板 + 速度过滤 + 落库
      this.locationSvc.startLocation({
        onSample: (latLng: mapCommon.LatLng, accuracy: number, speed: number) => {
          this.onLocationSample(latLng, accuracy, speed);
        }
      });
      // 同步驻留状态（定位服务内部已判定，页面仅做展示镜像）
      this.isStationary = this.locationSvc.stationary;
    } catch (err) {
      let error = err as BusinessError;
      console.error(`Failed to enable my location, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 定位采样回调（页面侧）：实时连线 → 5m 地板 → 速度门槛 → 落库记录
  private onLocationSample(latLng: mapCommon.LatLng, accuracy: number, speed: number): void {
    // 实时位置：通过精度门槛即采纳为 liveLocation（不入库），用于把已确认折线末端连到当前真实位置
    this.liveLocation = latLng;
    this.mapManager.updateLivePolyline(this.liveLocation, this.displayMode, this.trackPoints);
    this.isStationary = this.locationSvc.stationary;

    // 折线位移地板：与上一个折线点距离 < 当前阈值视为原地抖动，丢弃（阈值可在策略实验室切换 5/10/15米）
    if (this.trackPoints.length > 0) {
      let lastPoint: mapCommon.LatLng = this.trackPoints[this.trackPoints.length - 1];
      if (calculateDistance(lastPoint, latLng) < SHAKE_FLOOR_OPTIONS[this.shakeFloorIndex]) {
        return;
      }
    }
    // 速度门槛：定位上报速度低于静止门槛，视为原地未移动，丢弃避免折线原地漂移
    if (speed < STATIONARY_SPEED) {
      return;
    }
    this.recordTrackPoint(latLng, accuracy, speed);
  }

  // 定位回调核心：折线每通过「精度过滤+5m地板」的点都记（保持平滑）；
  // 足迹点(海量点)仅当距上一个足迹点 ≥ 当前模式距离门槛才记（控密度）；落库走缓冲批量；覆盖物节流刷新
  private recordTrackPoint(latLng: mapCommon.LatLng, accuracy: number, speed: number): void {
    let ts: number = Date.now();
    // 全量缓存增量追加（唯一数据源），供切换时间视图时重新过滤
    let rec: TrackPointRecord = {
      latitude: latLng.latitude,
      longitude: latLng.longitude,
      timestamp: ts,
      accuracy: accuracy,
      speed: speed
    };
    this.timeModel.addPoint(rec);

    // 仅当落点在当前可见时间范围才更新可见集与统计（否则仅入库、不显示）
    if (this.timeModel.isInVisibleRange(ts)) {
      let prevLast: mapCommon.LatLng | null = this.trackPoints.length > 0 ? this.trackPoints[this.trackPoints.length - 1] : null;
      this.trackPoints.push(latLng);
      this.trackCount = this.trackPoints.length;
      if (prevLast) {
        this.totalDistance += calculateDistance(prevLast, latLng);
      }
      // 足迹点：仅当距上一个足迹点的直线距离 ≥ 当前模式 distanceInterval 才记
      if (this.shouldRecordFootprint(latLng)) {
        this.footprintPoints.push(latLng);
        this.lastFootprintPoint = latLng;
      }
      // 覆盖物节流刷新（折线/足迹点分别计数）
      this.mapManager.refreshOverlayOptimized(this.displayMode, this.trackPoints, this.footprintPoints);
    }

    // 落库：推入缓冲，达到批大小即批量写入
    this.db.enqueue(rec);
  }

  // 判断是否达到「足迹」记录阈值：距上一个足迹点直线距离 ≥ 当前模式 distanceInterval 才记一次
  private shouldRecordFootprint(current: mapCommon.LatLng): boolean {
    if (!this.lastFootprintPoint) {
      return true;
    }
    let distance: number = calculateDistance(this.lastFootprintPoint, current);
    return distance >= MODE_CONFIG[this.currentMode].distanceInterval;
  }

  // 根据当前时间视图重建「可见集」并驱动地图重绘（总览强制海量点）
  private refreshVisibleView(): void {
    let interval: number = MODE_CONFIG[this.currentMode].distanceInterval;
    let v = this.timeModel.applyTimeView(interval);
    this.trackPoints = v.trackPoints;
    this.footprintPoints = v.footprintPoints;
    this.totalDistance = v.totalDistance;
    this.lastFootprintPoint = v.lastFootprintPoint;
    this.trackCount = v.trackPoints.length;
    // 总览视图不允许折线：强制海量点，并同步展示模式状态（地图工具面板的「折线」按钮将禁用）
    if (this.timeViewIndex === TIME_VIEW_OVERVIEW) {
      this.displayMode = 1;
      this.selectedIndexes = [1];
      this.display2SelectedIndexes = [1];
    }
    // 重置覆盖物节流计数，强制下一次刷新整体重绘
    this.mapManager.resetOverlayThrottle();
    this.mapManager.rebuildOverlay(this.displayMode, this.trackPoints, this.footprintPoints, this.liveLocation);
  }

  // 基于全量 allTrackPoints 派生统计指标
  private computeStats(): void {
    let result = computeStatsUtil(this.timeModel.allPoints);
    this.statTotalDistance = result.totalDistance;
    this.statTrackCount = result.trackCount;
    this.statActiveDays = result.activeDays;
    this.statAvgDailyDist = result.avgDailyDist;
    this.statMaxDailyDist = result.maxDailyDist;
    this.statFirstTs = result.firstTs;
    this.statLastTs = result.lastTs;
    this.statRecent7 = result.recent7;
  }

  // 跨日回调：仅当停留在「今日」视图时，重算今日范围并重绘（剔除昨天点，仅留新一天记录）
  private onDayChange(): void {
    if (this.timeModel.shouldRefreshOnDayChange()) {
      this.refreshVisibleView();
    }
  }

  // 顶部「时间范围」分段控件点击：切换总览/自定义/今日；选自定义则弹出日期选择
  private onTimeViewSelected(index: number): void {
    this.timeViewIndex = index;
    this.timeViewSelectedIndexes = [index];
    this.timeModel.onTimeViewSelected(index, () => { this.refreshVisibleView(); });
  }

  // 切换展示模式(0 折线 / 1 海量点)
  private switchDisplayMode(mode: number): void {
    // 总览视图仅支持海量点（避免跨天连线杂乱、卡顿），禁止切到折线
    if (this.timeViewIndex === TIME_VIEW_OVERVIEW && mode === 0) {
      return;
    }
    if (this.displayMode === mode) {
      return;
    }
    this.displayMode = mode;
    this.selectedIndexes = [mode];
    this.display2SelectedIndexes = [mode];
    this.mapManager.switchDisplayMode(mode, this.timeViewIndex, this.trackPoints, this.footprintPoints, this.liveLocation);
  }

  // 切换定位记录模式：更新展示档位并重新注册定位监听
  private switchMode(mode: number): void {
    this.currentMode = mode as RecordMode;
    this.locationSvc.switchMode(mode);
  }

  // 根据 nightModeIndex(0 跟随系统 /1 普通 /2 夜间) 设置地图日夜模式
  private applyNightMode(index: number): void {
    this.mapManager.applyNightMode(index);
  }

  private switchMapStyle(index: number): void {
    if (this.mapStyleIndex === index) {
      return;
    }
    this.mapStyleIndex = index;
    this.mapStyle2SelectedIndexes = [index];
    // 切换即持久化，下次重进按上次选择恢复，而非重置为经典
    this.saveMapStyle(index);
    this.mapManager.applyMapStyle(index);
  }

  // 清空全部轨迹：移除地图覆盖物、清空内存数组、并删除数据库中的轨迹记录
  private async clearTrack(): Promise<void> {
    this.mapManager.clearOverlays();
    this.timeModel.clearAll();
    this.trackPoints = [];
    this.trackCount = 0;
    this.totalDistance = 0;
    this.footprintPoints = [];
    this.lastFootprintPoint = null;
    this.liveLocation = null;
    await this.db.clear();
    // 删除全部后按当前时间视图重建可见集（此时为空，覆盖物随之清空）
    this.refreshVisibleView();
    console.info(TAG, 'Track cleared');
  }

  // 删除前二次确认弹窗，确认后调用 clearTrack
  private confirmClearTrack(): void {
    AlertDialog.show({
      title: '删除轨迹',
      message: `确定要删除全部 ${this.timeModel.allPoints.length} 条轨迹记录吗？此操作不可恢复。`,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('sys.color.ohos_id_color_warning'),
        action: () => {
          this.clearTrack();
        }
      }
    });
  }

  // ===== 权限相关（委托 PermissionService）=====
  private async refreshPermissionState(): Promise<void> {
    let state = await this.permSvc.refreshPermissionState();
    this.hasApproximatelyLocation = state.hasApproximatelyLocation;
    this.hasLocation = state.hasLocation;
    this.hasBackgroundLocation = state.hasBackgroundLocation;
  }

  private async requestPermissions(): Promise<void> {
    let ctx = getContext(this) as common.UIAbilityContext;
    let res = await this.permSvc.requestPermissions(ctx);
    this.hasApproximatelyLocation = res.hasApproximatelyLocation;
    this.hasLocation = res.hasLocation;
    this.hasBackgroundLocation = res.hasBackgroundLocation;
    if (res.hasApproximatelyLocation && res.hasLocation) {
      if (!res.hasBackgroundLocation) {
        this.permSvc.requestBackgroundLocationPermission(this.getUIContext());
      }
      this.enableMyLocation();
    }
  }

  private requestBackgroundLocationPermission(): void {
    this.permSvc.requestBackgroundLocationPermission(this.getUIContext());
  }

  private openPermissionSettings(): void {
    let ctx = getContext(this) as common.UIAbilityContext;
    this.permSvc.openPermissionSettings(ctx);
  }

  // ===== 地图样式偏好（页面侧轻量持久化）=====
  private saveMapStyle(index: number): void {
    try {
      let pref = preferences.getPreferencesSync(getContext(this), { name: PREF_NAME });
      pref.putSync(PREF_KEY_MAP_STYLE, index);
      pref.flushSync();
    } catch (e) {
      let error = e as BusinessError;
      console.error(`saveMapStyle failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  private loadMapStyle(): number {
    try {
      let pref = preferences.getPreferencesSync(getContext(this), { name: PREF_NAME });
      return pref.getSync(PREF_KEY_MAP_STYLE, 0) as number;
    } catch (e) {
      let error = e as BusinessError;
      console.error(`loadMapStyle failed, code: ${error.code}, message: ${error.message}`);
      return 0;
    }
  }

  // ===== UI 构建 =====
  // 结构：HdsNavigation → HdsTabs(足迹 / 统计 / 我的)  —— 画板 tab 已移除，地图工具入口改为足迹页右下角胶囊
  //  - 足迹 Tab：全屏地图 + 左上角统计胶囊 + 右上角时间切换 + 右下角「地图工具」胶囊(打开地图控制面板)
  //  - 我的 Tab：直接承载「我的」整页(buildMinePage，华为官方 Navigation + Mine)，面板由页内触发项绑定
  build() {
    HdsNavigation() {
      Stack({ alignContent: Alignment.TopStart }) {
        HdsTabs({ controller: this.tabsController }) {
          TabContent() {
            Stack() {
              MapComponent({ mapOptions: this.mapOptions, mapCallback: this.callback })
                .width('100%')
                .height('100%')
                .opacity(1)

              // 左上角胶囊组：足迹统计 + 常驻点
              Column({ space: 10 }) {
                if (this.trackCount > 0 && !this.immersive) {
                  Column({ space: 2 }) {
                    Text(`足迹点 ${this.trackCount} 个`)
                      .fontSize(13)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                    Text(`轨迹线 ${formatDistance(this.totalDistance)}`)
                      .fontSize(13)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .borderRadius(16)
                  .clip(true)
                  .backdropBlur(12)
                  .backgroundColor('rgba(255,255,255,0.1)')
                  .border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
                  .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
                  .transition({ type: TransitionType.All, opacity: 0, translate: { x: 0, y: -16 } })
                }

                if (this.isStationary) {
                  Row() {
                    SymbolGlyph($r('sys.symbol.local_fill'))
                      .fontSize(16)
                      .fontColor([$r('sys.color.font_primary')])
                    Text('常驻点激活')
                      .fontSize(13)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .margin({ left: 4 })
                  }
                  .padding({ left: 10, right: 12, top: 6, bottom: 6 })
                  .borderRadius(16)
                  .clip(true)
                  .backdropBlur(12)
                  .backgroundColor('rgba(255,255,255,0.1)')
                  .border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
                  .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
                }
              }
              .alignItems(HorizontalAlign.Start)
              .position({ x: 12, y: 12 + this.statusBarHeight })

              // 右上角的「时间范围」切换浮层（总览 / 自定义 / 今日）
              if (!this.immersive) {
                Row() {
                  SegmentButton({
                    options: this.timeViewSegmentOptions,
                    selectedIndexes: $timeViewSelectedIndexes,
                    onItemClicked: (index: number) => {
                      this.onTimeViewSelected(index);
                    }
                  })
                  .width(210)
                  .backgroundColor('rgba(0,0,0,0)')
                }
                .padding({ left: 4, right: 4, top: 4, bottom: 4 })
                .borderRadius(20)
                .clip(true)
                .backdropBlur(12)
                .backgroundColor('rgba(255,255,255,0.1)')
                .border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
                .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
                .position({ x: '100%', y: 12 + this.statusBarHeight })
                .markAnchor({ x: '100%', y: 0 })
                .offset({ x: -16, y: 0 })
                .transition({ type: TransitionType.All, opacity: 0, translate: { x: 0, y: -16 } })
              }

              // 右下角「地图工具」入口胶囊：点击打开地图控制面板（轨迹切换/地图样式/我的位置）
              Row() {
                SymbolGlyph($r('sys.symbol.paintpalette_fill'))
                  .fontSize(20)
                  .fontColor([$r('sys.color.font_primary')])
              }
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .borderRadius(16)
              .clip(true)
              .backdropBlur(12)
              .backgroundColor('rgba(255,255,255,0.1)')
              .border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
              .shadow({ radius: 6, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
              .onClick(() => {
                this.isShowMapToolSheet = true;
              })
              .bindSheet($$this.isShowMapToolSheet, this.buildMapToolSheetContent(), {
                detents: [SheetSize.MEDIUM, SheetSize.LARGE],
                title: { title: '地图工具' },
                dragBar: true,
                showClose: true,
                onDisappear: () => {
                  this.isShowMapToolSheet = false;
                }
              })
              .position({ x: '100%', y: '100%' })
              .markAnchor({ x: '100%', y: '100%' })
              .offset({ x: -16, y: -(this.navBarHeight * 2 + 44) })
            }
            .width('100%')
            .height('100%')
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.figure_running'))
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .fontColor([$r('sys.color.ohos_id_color_primary')]),
            selected: new SymbolGlyphModifier($r('sys.symbol.figure_running'))
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .fontColor([$r('sys.color.ohos_id_color_activated')])
          }, '足迹'))

          // 「统计」Tab：直接承载统计页面内容（华为官方 Navigation + List，不再使用半模态面板）
          TabContent() {
            this.buildStatsPage()
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.waveform_folder_fill'))
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .fontColor([$r('sys.color.ohos_id_color_primary')]),
            selected: new SymbolGlyphModifier($r('sys.symbol.waveform_folder_fill'))
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .fontColor([$r('sys.color.ohos_id_color_activated')])
          }, '统计'))

          // 「我的」Tab：直接承载「我的」页面内容（华为官方 Navigation + Mine，不再使用半模态面板）
          TabContent() {
            this.buildMinePage()
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1'))
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .fontColor([$r('sys.color.ohos_id_color_primary')]),
            selected: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1'))
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .fontColor([$r('sys.color.ohos_id_color_activated')])
          }, '我的'))
        }
        .barOverlap(true)
        .vertical(false)
        .barPosition(BarPosition.End)
        .scrollable(false)
        // 三个 Tab(足迹/统计/我的)均直接整页切换；地图工具面板改由足迹页内胶囊触发
        .onContentWillChange((_currentIndex: number, comingIndex: number) => {
          if (comingIndex === 0) {
            return true;
          }
          if (comingIndex === 1) {
            this.computeStats();
            return true;
          }
          if (comingIndex === 2) {
            return true;
          }
          return true;
        })
        .barFloatingStyle({
          barBottomMargin: 28 + this.navBarHeight,
          gradientMask: {
            maskColor: Color.Transparent
          },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: this.customMaterialLevel
          }
        })
      }
      .width('100%')
      .height('100%')

      // 「我的」三面板 bindSheet 已迁移到 Mine 内各触发项（方案A，官方触发项绑定）
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideBackButton(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }


  // 「足迹统计」页面：华为官方 Navigation 标题栏 + List 列表（承载于统计 Tab）
  @Builder
  buildStatsPage(): void {
    Navigation() {
      List() {
        if (this.statTrackCount === 0) {
          ListItem() {
            Column() {
              Text('暂无足迹数据')
                .fontSize(14)
                .fontColor($r('sys.color.font_primary'))
                .opacity(0.5)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 40, bottom: 40 })
          }
        } else {
          ListItem() {
            Row({ space: 12 }) {
              Column({ space: 4 }) {
                Text(`${(this.statTotalDistance / 1000).toFixed(2)}`)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('sys.color.font_primary'))
                Text('累计里程')
                  .fontSize(12)
                  .fontColor($r('sys.color.font_primary'))
                  .opacity(0.6)
              }
              .layoutWeight(1)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(16)
              .padding(16)
              .alignItems(HorizontalAlign.Center)

              Column({ space: 4 }) {
                Text(`${this.statTrackCount}`)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('sys.color.font_primary'))
                Text('足迹点')
                  .fontSize(12)
                  .fontColor($r('sys.color.font_primary'))
                  .opacity(0.6)
              }
              .layoutWeight(1)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(16)
              .padding(16)
              .alignItems(HorizontalAlign.Center)

              Column({ space: 4 }) {
                Text(`${this.statActiveDays}`)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('sys.color.font_primary'))
                Text('记录天数')
                  .fontSize(12)
                  .fontColor($r('sys.color.font_primary'))
                  .opacity(0.6)
              }
              .layoutWeight(1)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(16)
              .padding(16)
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .margin({ bottom: 16 })
          }

          ListItem() {
            Column({ space: 12 }) {
              Row({ space: 12 }) {
                this.buildStatItem(formatDistance(this.statAvgDailyDist), '平均每日里程')
                this.buildStatItem(formatDistance(this.statMaxDailyDist), '最长单日里程')
              }
              .width('100%')

              Row({ space: 12 }) {
                this.buildStatItem(formatStatDate(this.statFirstTs), '首次记录')
                this.buildStatItem(formatStatDate(this.statLastTs), '最近记录')
              }
              .width('100%')
            }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(16)
            .padding(16)
            .margin({ bottom: 16 })
          }

          ListItem() {
            Column({ space: 8 }) {
              Row() {
                Text('常驻点')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
                Blank()
                if (this.isStationary) {
                  Text('已激活')
                    .fontSize(14)
                    .fontColor($r('sys.color.ohos_id_color_activated'))
                    .fontWeight(FontWeight.Medium)
                } else {
                  Text('未激活')
                    .fontSize(14)
                    .fontColor($r('sys.color.font_primary'))
                    .opacity(0.5)
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
              .alignItems(VerticalAlign.Center)

              Text('当位置长时间不变时，系统判定为常驻点')
                .fontSize(12)
                .fontColor($r('sys.color.font_primary'))
                .opacity(0.5)
                .width('100%')
            }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(16)
            .padding(16)
            .margin({ bottom: 16 })
          }

          ListItem() {
            Column({ space: 10 }) {
              Text('最近 7 天')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .width('100%')

              ForEach(this.statRecent7, (item: StatDayItem) => {
                Column({ space: 4 }) {
                  Row() {
                    Text(item.label)
                      .fontSize(12)
                      .fontColor($r('sys.color.font_primary'))
                      .opacity(0.7)
                    Blank()
                    Text(`${item.count} 点 · ${formatDistance(item.distance)}`)
                      .fontSize(12)
                      .fontColor($r('sys.color.font_primary'))
                      .opacity(0.7)
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.SpaceBetween)

                  Row() {
                    Column()
                      .width(this.statMaxDailyDist > 0
                        ? `${Math.min(100, (item.distance / this.statMaxDailyDist) * 100)}%`
                        : '0%')
                      .height(6)
                      .backgroundColor($r('sys.color.ohos_id_color_activated'))
                      .borderRadius(3)
                    Blank()
                  }
                  .width('100%')
                  .height(6)
                  .backgroundColor($r('sys.color.ohos_id_color_activated'))
                  .opacity(0.15)
                  .borderRadius(3)
                }
                .width('100%')
              }, (item: StatDayItem) => item.label)
            }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(16)
            .padding(16)
            .margin({ bottom: 16 })
          }

          ListItem() {
            Column({ space: 8 }) {
              Text(this.timeViewIndex === TIME_VIEW_OVERVIEW ? '当前视图（总览）'
                : this.timeViewIndex === TIME_VIEW_CUSTOM ? '当前视图（自定义）' : '当前视图（今日）')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .width('100%')

              Row({ space: 12 }) {
                Column({ space: 2 }) {
                  Text(formatDistance(this.totalDistance))
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                  Text('里程')
                    .fontSize(12)
                    .fontColor($r('sys.color.font_primary'))
                    .opacity(0.6)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)

                Column({ space: 2 }) {
                  Text(`${this.trackCount}`)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                  Text('足迹点')
                    .fontSize(12)
                    .fontColor($r('sys.color.font_primary'))
                    .opacity(0.6)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
              }
              .width('100%')
            }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(16)
            .padding(16)
            .margin({ bottom: 16 })
          }
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, bottom: this.navBarHeight + 96 })
      .backgroundColor($r('sys.color.background_secondary'))
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
    }
    .title('足迹统计', { backgroundColor: $r('sys.color.background_secondary') })
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .padding({ top: this.statusBarHeight })
    .backgroundColor($r('sys.color.background_secondary'))
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
  }

  // 统计面板内的单行指标（左标题 + 右数值），两列布局复用
  @Builder
  private buildStatItem(value: string, label: string): void {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      Text(label)
        .fontSize(12)
        .fontColor($r('sys.color.font_primary'))
        .opacity(0.6)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  // 「我的」Tab 页面：华为官方 Navigation 标题栏承载 Mine 组件（与统计页一致，不再使用半模态面板）
  @Builder
  buildMinePage(): void {
    Navigation() {
      Mine({
        recordMode: $currentMode,
        hasApproximatelyLocation: $hasApproximatelyLocation,
        hasLocation: $hasLocation,
        hasBackgroundLocation: $hasBackgroundLocation,
        nightModeIndex: $nightModeIndex,
        customSelectIndex: $customSelectIndex,
        shakeFloorIndex: $shakeFloorIndex,
        pushSwitchOn: $pushSwitchOn,
        customSwitchOn: $customSwitchOn,
        trackCount: $trackCount,
        safeBottom: this.navBarHeight + 96,
        onRecordModeChange: (m: number) => this.switchMode(m),
        onRequestPermissions: () => this.requestPermissions(),
        onOpenPermissionSettings: () => this.openPermissionSettings(),
        onRequestBackgroundPermission: () => this.requestBackgroundLocationPermission(),
        onNightModeChange: (i: number) => this.applyNightMode(i),
        onClearTrack: () => this.confirmClearTrack(),
        onLocationPermissionRefresh: () => this.refreshPermissionState()
      })
    }
    .title('我的', { backgroundColor: $r('sys.color.background_secondary') })
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .padding({ top: this.statusBarHeight })
    .backgroundColor($r('sys.color.background_secondary'))
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
  }





  // 「地图工具」半模态面板内容
  @Builder
  buildMapToolSheetContent(): void {
    Column() {
      Column() {
        Row() {
          Text('轨迹切换')
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)

          Blank()

          SegmentButton({
            options: this.display2SegmentOptions,
            selectedIndexes: $display2SelectedIndexes,
            onItemClicked: (index: number) => {
              this.switchDisplayMode(index);
            }
          })
          .width(160)
          .enabled(this.timeViewIndex !== TIME_VIEW_OVERVIEW)
          .opacity(this.timeViewIndex === TIME_VIEW_OVERVIEW ? 0.4 : 1)
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding({ top: 16, bottom: 16, left: 12, right: 12 })
      }
      .width('100%')
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(16)
      .margin({ bottom: 12 })

      Column() {
        Row() {
          Text('地图样式')
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)

          Blank()

          SegmentButton({
            options: this.mapStyleSegmentOptions,
            selectedIndexes: $mapStyle2SelectedIndexes,
            onItemClicked: (index: number) => {
              this.switchMapStyle(index);
            }
          })
          .width(200)
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding({ top: 16, bottom: 16, left: 12, right: 12 })
      }
      .width('100%')
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(16)
      .margin({ bottom: 12 })

      // 「我的位置」开关：自定义开启/关闭“我的位置”图层（蓝色定位点）
      Column() {
        Row() {
          Text('我的位置')
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)

          Blank()

          Toggle({ type: ToggleType.Switch, isOn: this.myLocationOn })
            .onChange((isOn: boolean) => {
              this.myLocationOn = isOn;
              if (this.mapManager.controller) {
                this.mapManager.controller.setMyLocationEnabled(isOn);
                this.mapManager.controller.setMyLocationControlsEnabled(isOn);
              }
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding({ top: 16, bottom: 16, left: 12, right: 12 })
      }
      .width('100%')
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(16)
      .margin({ bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
  }






}
