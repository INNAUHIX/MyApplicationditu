/**
 * Index.ets —— 应用主页面（地图 / 轨迹记录 / 「我的」）
 *
 * 功能概览：
 *  - 集成 @kit.MapKit 地图组件，展示用户当前位置并支持 3D 建筑、指南针等交互
 *  - 通过定位服务（geoLocationManager）实时记录轨迹点，持久化到本地关系型数据库 footprint.db
 *  - 轨迹支持两种展示模式：`折线轨迹`(displayMode=0) 与 `海量点`(displayMode=1)
 *  - 地图日/夜模式可切换：跟随系统 / 普通 / 夜间（nightModeIndex）
 *  - 底部 HdsTabs 两个 Tab：足迹（本页地图）/ 我的（以半模态面板承载 Mine 组件）
 *
 * 关键数据流：
 *  定位回调 → recordTrackPoint → saveTrackPoint(落库) → 刷新折线/海量点覆盖物
 *
 * 注意：本组件在代码库早期原型中曾命名 MapPage，部分历史命名（如日志 TAG）已统一为 Index。
 */
import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, bundleManager, common, Permissions, Want } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { image } from '@kit.ImageKit';
import { relationalStore, preferences } from '@kit.ArkData';

import { HdsNavigation, HdsTabs, HdsTabsController, HdsAnimationMode, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier, SegmentButton, SegmentButtonOptions, ItemRestriction, SegmentButtonIconTextItem, SegmentButtonTextItem, window } from '@kit.ArkUI';
import { Mine } from './Mine';
import { MAP_STYLE_TEST } from './MapStyleTest';




// 日志 TAG：组件名为 Index，早期原型曾叫 MapPage，此处统一为 Index 以消除歧义
const TAG: string = 'Index';

// 定位模式面板「防漂移与性能策略」展示项结构
interface RecordStrategyItem {
  title: string;
  desc: string;
}

// 时间视图的可见时间范围（含上/下界），用于从全量缓存过滤出可见轨迹点
interface VisibleRange {
  start: number;
  end: number;
}

// ===== 本地数据库（ArkData RdbStore）配置 =====
const DB_NAME: string = 'footprint.db';    // 数据库文件名，存于应用沙箱
const TABLE_NAME: string = 'track_points'; // 轨迹点表名
// 建表语句：新装直接带全字段；旧库通过 initDatabase 里的 ALTER TABLE 兼容升级
const CREATE_TABLE_SQL: string =
  `CREATE TABLE IF NOT EXISTS ${TABLE_NAME} (id INTEGER PRIMARY KEY AUTOINCREMENT, latitude REAL, longitude REAL, timestamp INTEGER DEFAULT 0, accuracy REAL DEFAULT 0, speed REAL DEFAULT 0)`;
// 不兼容旧轨迹数据：若检测到旧表（缺新字段），直接删表重建，旧数据不保留
const DROP_TABLE_SQL: string = `DROP TABLE IF EXISTS ${TABLE_NAME}`;
const CREATE_INDEX_SQL: string = `CREATE INDEX IF NOT EXISTS idx_ts ON ${TABLE_NAME}(timestamp)`;

// 轻量偏好存储：持久化地图样式（经典/暗夜/浅白），避免每次重进都被重置为经典
const PREF_NAME: string = 'app_prefs';
const PREF_KEY_MAP_STYLE: string = 'mapStyleIndex';
// 轻量偏好存储：持久化「时间范围」视图选择（0=总览 / 1=自定义 / 2=今日）与自定义起止日期
const PREF_KEY_TIME_VIEW: string = 'timeViewIndex';
const PREF_KEY_CUSTOM_START: string = 'customStartTs';
const PREF_KEY_CUSTOM_END: string = 'customEndTs';

// 时间范围视图索引常量
const TIME_VIEW_OVERVIEW: number = 0; // 总览（仅海量点）
const TIME_VIEW_CUSTOM: number = 1;   // 自定义日期
const TIME_VIEW_TODAY: number = 2;    // 今日（默认）

// 一天的毫秒数
const ONE_DAY_MS: number = 24 * 60 * 60 * 1000;

// 自定义地图样式 ID（在 Petal Maps Studio 发布）：暗夜 / 浅白
const MAP_STYLE_DARK_ID: string = '1992208612130395136';
const MAP_STYLE_LIGHT_ID: string = '1992216939216384896';

// ===== 定位记录模式（按功耗分级，Option B）=====
enum RecordMode {
  POWER_SAVING = 0, // 省电
  BALANCED = 1,     // 平衡（默认）
  HIGH_POWER = 2    // 耗电
}

// 各档参数：timeInterval=定位回调间隔(秒)；distanceInterval=足迹点记录距离门槛(米，仅控海量点稀疏度)；
//          maxAccuracy=精度门槛(米，超出则丢弃漂移点)
interface RecordModeConfig {
  timeInterval: number;
  distanceInterval: number;
  maxAccuracy: number;
  label: string;
}

// 三档参数：省电 / 平衡(默认) / 耗电
// 折线防漂：timeInterval 采样 + 精度过滤 + 5m 位移地板 + 速度门槛(静止判定) + 30m 静止迟滞；distanceInterval 仅用来给足迹点(海量点)降密度
const MODE_CONFIG: RecordModeConfig[] = [
  { timeInterval: 30, distanceInterval: 200, maxAccuracy: 100, label: '省电' },
  { timeInterval: 10, distanceInterval: 50,  maxAccuracy: 80,  label: '平衡' },
  { timeInterval: 3,  distanceInterval: 20,  maxAccuracy: 50,  label: '耗电' }
];

// 待写入数据库的轨迹点记录（含精度/速度/时间戳）
interface TrackPointRecord {
  latitude: number;
  longitude: number;
  timestamp: number;
  accuracy: number;
  speed: number;
}

// 统计面板「最近 7 天」每日聚合数据（ArkTS 禁止对象字面量作为类型注解，需显式接口）
interface StatDayItem {
  label: string;
  distance: number;
  count: number;
}

/**
 * 主页面组件 Index。
 * 职责：地图渲染、实时轨迹记录（落库）、展示模式切换、日/夜模式、以及承载「我的」半模态面板。
 */
@Entry
@Component
struct Index {
  private mapOptions?: mapCommon.MapOptions;
  private callback?: AsyncCallback<map.MapComponentController>;
  private mapController?: map.MapComponentController;
  private trackPolyline: map.MapPolyline | null = null;
  private massPointOverlay: map.MassPointOverlay | null = null;
  // 实时位置连线：把已确认折线末端连到当前实时位置，消除「已确认点 → 真实位置」之间的空白与终点断点
  private livePolyline: map.MapPolyline | null = null;
  // 当前实时位置（仅过精度门槛即采纳，不入库），用于实时连线，不影响 trackPoints 的防漂移落库逻辑
  private liveLocation: mapCommon.LatLng | null = null;
  private trackPoints: mapCommon.LatLng[] = [];
  private footprintPoints: mapCommon.LatLng[] = [];
  private lastFootprintPoint: mapCommon.LatLng | null = null;
  private locationCallback?: (location: geoLocationManager.Location) => void;
  private redDotIcon: image.PixelMap | null = null;
  private rdbStore: relationalStore.RdbStore | null = null;
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
  // 折线轨迹距离地板：新点与上一个轨迹点距离 < 5米时丢弃，过滤GPS漂移导致的原地锯齿线
  private static readonly MIN_TRACK_DISTANCE: number = 5;
  // 静止检测：最近窗口大小
  private static readonly STATIONARY_WINDOW: number = 10;
  // 静止检测：窗口内所有点到质心距离 < 15米则判定为静止
  private static readonly STATIONARY_RADIUS: number = 15;
  // 静止时定位频率（秒），降低频率减少漂移点产生（覆盖各模式间隔）
  private static readonly STATIONARY_INTERVAL: number = 30;
  // 静止速度门槛（米/秒）：定位上报速度低于此值视为原地未移动（≈3.6km/h，低于步行），
  // 用于过滤静止时的位置漂移（室内网络定位/弱信号下位置会原地乱跳，但速度常近似 0）
  private static readonly STATIONARY_SPEED: number = 1.0;
  // 静止退出半径（米）：已判定为常驻后，仅当新点明显远离常驻簇超过此值才视为真正离开并恢复记录
  // （迟滞，防止抖动误把常驻点判成「在动」而漏记飘线）
  private static readonly STATIONARY_EXIT_RADIUS: number = 30;
  // 当前定位记录模式（默认平衡）；折线按模式间隔采样，足迹点按模式距离门槛稀疏
  @State currentMode: RecordMode = RecordMode.BALANCED;
  // 待写入数据库的轨迹点缓冲（批量落库，降低 DB 写入频率）
  private pendingPoints: TrackPointRecord[] = [];
  private flushTimer: number | null = null;
  private static readonly BATCH_SIZE: number = 15;          // 缓冲积累点数达此值立即落库
  private static readonly FLUSH_INTERVAL: number = 8000;    // 定时落库间隔（毫秒）
  // 覆盖物节流刷新计数/时间戳
  private lastPolylineUpdatePointCount: number = 0;         // 上次折线刷新时已刷新到的点数
  private lastFootprintUpdateCount: number = 0;             // 上次海量点刷新时已刷新到的足迹点数
  private lastOverlayUpdateTs: number = 0;                  // 上次任意覆盖物刷新的时间戳(秒)
  private static readonly OVERLAY_UPDATE_INTERVAL: number = 30;   // 覆盖物最多每30秒刷新一次
  private static readonly POLYLINE_UPDATE_POINT_GAP: number = 50; // 每新增50个折线点刷新折线
  private static readonly FOOTPRINT_UPDATE_POINT_GAP: number = 20; // 每新增20个足迹点刷新海量点
  @State isStationary: boolean = false;



  private recentPoints: mapCommon.LatLng[] = [];

  private tabsController: HdsTabsController = new HdsTabsController();
  @State customMaterialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;
  @State hasApproximatelyLocation: boolean = false;
  @State hasLocation: boolean = false;
  @State hasBackgroundLocation: boolean = false;
  @State isShowSheet: boolean = false;
  @State nightModeIndex: number = 0; // 地图日/夜间模式：0=跟随系统，1=普通，2=夜间
  @State showDisplayModePopup: boolean = false;
  @State pushSwitchOn: boolean = true;
  private mapEventManager?: map.MapEventManager;
  @State immersive: boolean = false; // 沉浸模式：true=隐藏叠加 UI，只显示地图
  @State customSwitchOn: boolean = true;
  @State customSelectIndex: number = 0;
  @State showCustomSelectPopup: boolean = false;
  @State isShowSettingSheet: boolean = false;
  @State isShowLocationSheet: boolean = false; // 定位权限半模态面板显隐
  @State isShowRecordModeSheet: boolean = false; // 定位模式半模态面板显隐
  @State isShowMapToolSheet: boolean = false; // 地图工具半模态面板显隐
  @State isShowStatsSheet: boolean = false; // 足迹统计半模态面板显隐
  @State myLocationOn: boolean = true; // “我的位置”图层开关：true=显示蓝色定位点（自定义开关，置于地图工具面板）
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
  // allTrackPoints 为唯一全量数据源（含 timestamp），启动时从 DB 一次性载入并随实时记录增量追加；
  // 其余 overlay / 统计均基于「当前可见集」（this.trackPoints / footprintPoints）派生。
  private allTrackPoints: TrackPointRecord[] = [];
  private visibleStartTs: number = 0;                  // 当前视图可见时间下界
  private visibleEndTs: number = Number.MAX_SAFE_INTEGER; // 当前视图可见时间上界
  @State timeViewIndex: number = TIME_VIEW_TODAY;      // 0=总览 / 1=自定义 / 2=今日（默认今日）
  @State timeViewSelectedIndexes: number[] = [TIME_VIEW_TODAY];
  @State customStartTs: number = 0;                    // 自定义起止日期（归一为当天 0 点 / 23:59:59.999）
  @State customEndTs: number = 0;
  private currentDayKey: string = '';                  // 跨日检测：当前日期 key（YYYY-M-D）
  private dayCheckTimer: number | null = null;         // 跨日检测定时器
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
  private settingStack: NavPathStack = new NavPathStack();
  private displayModeOptions: string[] = ['跟随系统', '普通模式', '夜间模式'];
  private customSelectOptions: string[] = ['选项1', '选项2', '选项3'];
  // 定位模式：档位名称与描述（与 MODE_CONFIG 顺序一致：GeneratedTypeLiteralInterface_1
  private recordModeNames: string[] = ['省电', '平衡', '耗电'];
  private recordModeDescs: string[] = [
    '定位间隔约30秒，精度门槛100米。采样最稀疏、最省电，适合长时间后台挂机、对轨迹精度要求不高的日常记录。',
    '定位间隔约10秒，精度门槛80米。精度与耗电均衡，推荐作为日常默认档位。',
    '定位间隔约3秒，精度门槛50米。采样最密集、轨迹最精细，但最费电，适合骑行 / 步行导航等需要细腻轨迹的场景。'
  ];
  // 定位模式面板下方「防漂移与性能策略」展示项（title=要点，desc=说明）
  private recordStrategyItems: Array<RecordStrategyItem> = [
    { title: '静止降频', desc: '连续定位点均落在小范围内（≤15米）判定为静止，自动把定位间隔降到30秒省电；仅当明显远离（>30米）才视为真正移动并恢复档位间隔。' },
    { title: '漂移过滤', desc: '单点定位精度超出当前模式门槛（省电100米/平衡80米/耗电50米）时整体丢弃，不计入轨迹。' },
    { title: '静止不记', desc: '定位上报速度低于步行速度（约3.6km/h）时视为原地未动，不记录，避免静止漂移画蛇添足。' },
    { title: '抖动地板', desc: '与上一个折线点距离不足5米视为原地抖动，直接丢弃，防止轨迹回绕。' },
    { title: '足迹降密', desc: '海量点（足迹点）按各模式距离门槛抽样记录：省电≥200米、平衡≥50米、耗电≥20米才记一次，降低点数密度与渲染压力。' },
    { title: '批量落库', desc: '轨迹点先进缓冲，每8秒定时一次性写入数据库，降低存储写入频率。' },
    { title: '绘制节流', desc: '折线每新增50点、海量点每新增20点且最多每30秒刷新一次，避免高频重绘卡顿。' },
    { title: '实时连线', desc: '已确认折线末端实时连到你当前位置（仅过精度门槛、不入库），让红线始终延伸到脚下，消除停下时的终点断点与等待下一个确认点的空白。' }
  ];

  // ===== 生命周期 =====
  // 页面即将显示：初始化地图参数/回调、异步生成红点图标、按需初始化数据库、确定系统材质等级
  aboutToAppear(): void {
    // 恢复上次选择的地图样式，避免每次进入都被重置为经典
    let savedStyle: number = this.loadMapStyle();
    this.mapStyleIndex = savedStyle;
    this.mapStyle2SelectedIndexes = [savedStyle];
    // 恢复「时间范围」视图选择（默认今日）与自定义起止日期
    this.loadTimeViewPrefs();
    this.initMapOptions();
    this.initMapCallback();
    this.createRedDotIcon().then(() => {
      if (this.displayMode === 1 && this.trackPoints.length > 0) {
        this.updateMassPointOverlay();
      }
    });
    let materialTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    if (materialTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0) {
      this.customMaterialLevel = hdsMaterial.MaterialLevel.SMOOTH;
    }

    // 获取状态栏高度：页面整体忽略安全区（地图沉浸全屏），顶部浮层需据此下移避开状态栏
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      window.getLastWindow(ctx).then((win: window.Window) => {
        let avoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        this.statusBarHeight = px2vp(avoidArea.topRect.height);
        // 系统底部导航条高度：地图/悬浮底栏/地图控件需据此避让，避免压在导航条上
        this.navBarHeight = px2vp(avoidArea.bottomRect.height);
        // 异步拿到导航条高度后重新应用地图底部留白（初始 setPadding 可能先于此处执行）
        if (this.mapController) {
          this.mapController.setPadding({
            left: 0,
            top: 0,
            right: 0,
            bottom: this.navBarHeight + 90
          });
        }
      }).catch((err: BusinessError) => {
        console.error(TAG, `getLastWindow failed, code: ${err.code}, message: ${err.message}`);
      });
    } catch (e) {
      console.error(TAG, `get statusBarHeight failed: ${JSON.stringify(e)}`);
    }

    // 启动批量落库定时器：每 FLUSH_INTERVAL 毫秒把缓冲中的轨迹点一次性写入数据库
    this.flushTimer = setInterval(() => {
      this.flushBatch();
    }, Index.FLUSH_INTERVAL);

    // 启动跨日检测：每分钟比对日期 key，跨过午夜(00:00)时自动刷新「今日」视图，
    // 把昨天的点从今日可见集剔除，仅保留新一天记录的点（停留今日视图时地图自动重绘）
    this.startDayCheck();
  }

  // 每次回到前台：恢复地图显示，并刷新三项定位权限状态
  onPageShow(): void {
    if (this.mapController) {
      this.mapController.show();
    }
    this.refreshPermissionState();
  }

  // 切到后台：隐藏地图以释放 GPU 资源
  onPageHide(): void {
    if (this.mapController) {
      this.mapController.hide();
    }
  }

  // 页面销毁：反注册定位监听，清除落库定时器并补齐未落库的点，避免后台持续定位与内存泄漏
  aboutToDisappear(): void {
    try {
      geoLocationManager.off('locationChange');
    } catch (err) {
      console.warn(TAG, 'Failed to unsubscribe locationChange');
    }
    if (this.flushTimer !== null) {
      clearInterval(this.flushTimer);
      this.flushTimer = null;
    }
    // 清除跨日检测定时器，避免页面销毁后仍触发
    if (this.dayCheckTimer !== null) {
      clearInterval(this.dayCheckTimer);
      this.dayCheckTimer = null;
    }
    this.flushBatch();
  }

  // 用 PixelMap 以代码绘制一个 12x12 的红色实心圆点，作为「足迹」海量点的图标（无需图片资源）
  private async createRedDotIcon(): Promise<void> {
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

  // 初始化本地关系型数据库：获取 RdbStore、建表，并加载历史轨迹点
  private async initDatabase(): Promise<void> {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      this.rdbStore = await relationalStore.getRdbStore(context, config);
      await this.rdbStore.executeSql(CREATE_TABLE_SQL);
      // 不兼容旧轨迹：尝试访问新字段 timestamp，失败说明是旧表（仅2列），直接删表重建丢弃旧数据
      try {
        let probe = new relationalStore.RdbPredicates(TABLE_NAME);
        await this.rdbStore.query(probe, ['timestamp']);
      } catch (e) {
        console.info(TAG, 'Old schema detected, dropping table to rebuild (old data discarded)');
        await this.rdbStore.executeSql(DROP_TABLE_SQL);
        await this.rdbStore.executeSql(CREATE_TABLE_SQL);
      }
      await this.rdbStore.executeSql(CREATE_INDEX_SQL);
      await this.loadTrackPoints();
    } catch (err) {
      let error = err as BusinessError;
      console.error(`initDatabase failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 按时间范围从数据库查询轨迹点（命中 idx_ts 索引），返回含 timestamp 的完整记录。
  // 用于「自定义 / 今日 / 总览」分天查看：数据库仍单表存储，仅按 timestamp 做范围筛选。
  private async queryTrackPointsByRange(startTs: number, endTs: number): Promise<TrackPointRecord[]> {
    let records: TrackPointRecord[] = [];
    if (!this.rdbStore) {
      return records;
    }
    try {
      let predicates = new relationalStore.RdbPredicates(TABLE_NAME);
      predicates.between('timestamp', startTs, endTs).orderByAsc('id');
      let resultSet = await this.rdbStore.query(predicates,
        ['latitude', 'longitude', 'timestamp']);
      while (resultSet.goToNextRow()) {
        records.push({
          latitude: resultSet.getDouble(resultSet.getColumnIndex('latitude')),
          longitude: resultSet.getDouble(resultSet.getColumnIndex('longitude')),
          timestamp: resultSet.getLong(resultSet.getColumnIndex('timestamp')),
          accuracy: 0,
          speed: 0
        });
      }
      resultSet.close();
    } catch (err) {
      let error = err as BusinessError;
      console.error(`queryTrackPointsByRange failed, code: ${error.code}, message: ${error.message}`);
    }
    return records;
  }

  // 从数据库全量载入轨迹点（0~now），作为 allTrackPoints 唯一全量缓存；随后按当前时间视图派生可见集
  private async loadTrackPoints(): Promise<void> {
    if (!this.rdbStore) {
      return;
    }
    try {
      this.allTrackPoints = await this.queryTrackPointsByRange(0, Number.MAX_SAFE_INTEGER);
      console.info(TAG, `Loaded ${this.allTrackPoints.length} track points from database`);
      this.applyTimeView();
      this.computeStats();
    } catch (err) {
      let error = err as BusinessError;
      console.error(`loadTrackPoints failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 计算当前时间视图对应的可见时间范围 [startTs, endTs]
  private getVisibleRange(): VisibleRange {
    if (this.timeViewIndex === TIME_VIEW_OVERVIEW) {
      // 总览：全部历史
      return { start: 0, end: Number.MAX_SAFE_INTEGER };
    } else if (this.timeViewIndex === TIME_VIEW_CUSTOM) {
      // 自定义：用户选的起止日期（归一为当天 0 点 ~ 23:59:59.999）
      return { start: this.customStartTs, end: this.customEndTs };
    } else {
      // 今日：今天 0 点 ~ 现在（每次计算取实时，跨日后自动变化）
      return { start: this.getDayStartTs(Date.now()), end: Date.now() };
    }
  }

  // 根据当前 timeViewIndex 重建「可见集」：从全量缓存按时间范围过滤，
  // 重算足迹点(海量点)与里程，并强制更新覆盖物。总览视图强制海量点展示（仅看足迹点）。
  private applyTimeView(): void {
    let range = this.getVisibleRange();
    this.visibleStartTs = range.start;
    this.visibleEndTs = range.end;

    // 总览视图不允许折线：强制海量点，并同步展示模式状态（地图工具面板的「折线」按钮将禁用）
    if (this.timeViewIndex === TIME_VIEW_OVERVIEW) {
      this.displayMode = 1;
      this.selectedIndexes = [1];
      this.display2SelectedIndexes = [1];
    }

    // 重置可见集与节流计数，按当前范围重新过滤全量缓存（区间边界自然断开，不跨天连线）
    this.trackPoints = [];
    this.footprintPoints = [];
    this.lastFootprintPoint = null;
    this.totalDistance = 0;
    let prev: mapCommon.LatLng | null = null;
    for (let i = 0; i < this.allTrackPoints.length; i++) {
      let rec = this.allTrackPoints[i];
      if (rec.timestamp < range.start || rec.timestamp > range.end) {
        continue;
      }
      let latLng: mapCommon.LatLng = { latitude: rec.latitude, longitude: rec.longitude };
      this.trackPoints.push(latLng);
      if (prev) {
        this.totalDistance += this.calculateDistance(prev, latLng);
      }
      prev = latLng;
      if (this.shouldRecordFootprint(latLng)) {
        this.footprintPoints.push(latLng);
        this.lastFootprintPoint = latLng;
      }
    }
    this.trackCount = this.trackPoints.length;
    console.info(TAG, `applyTimeView(${this.timeViewIndex}) -> visible ${this.trackCount} points, ` +
      `distance ${Math.round(this.totalDistance)}m`);

    // 重置覆盖物节流计数，强制下一次刷新整体重绘
    this.lastPolylineUpdatePointCount = 0;
    this.lastFootprintUpdateCount = 0;
    this.lastOverlayUpdateTs = 0;
    this.rebuildOverlay();
  }

  // 移除现有覆盖物并依据当前展示模式重建（基于可见集 trackPoints / footprintPoints）
  private rebuildOverlay(): void {
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
    if (this.trackPoints.length === 0) {
      return;
    }
    if (this.displayMode === 0) {
      this.updatePolyline();
      this.updateLivePolyline();
    } else {
      this.updateMassPointOverlay();
    }
  }

  // 判断时间戳是否落在当前可见时间范围内（实时新点是否计入可见集）
  private isInVisibleRange(ts: number): boolean {
    return ts >= this.visibleStartTs && ts <= this.visibleEndTs;
  }

  // 顶部「时间范围」分段控件点击：切换总览/自定义/今日；选自定义则弹出日期选择
  private onTimeViewSelected(index: number): void {
    this.timeViewIndex = index;
    this.timeViewSelectedIndexes = [index];
    if (index === TIME_VIEW_CUSTOM) {
      this.openCustomDatePicker();
    } else {
      this.applyTimeView();
      this.saveTimeViewPrefs();
    }
  }

  // 自定义日期选择：依次弹出「起始日期」「结束日期」两个 DatePickerDialog，
  // 选完写入 customStartTs/customEndTs（归一为当天 0 点 / 23:59:59.999）后应用视图
  private openCustomDatePicker(): void {
    let todayStart: number = this.getDayStartTs(Date.now());
    let todayEnd: number = this.getDayEndTs(Date.now());
    let startInit: number = this.customStartTs > 0 ? this.customStartTs : todayStart;
    DatePickerDialog.show({
      start: new Date(todayStart - 365 * ONE_DAY_MS),
      end: new Date(todayEnd),
      selected: new Date(startInit),
      onAccept: (value: DatePickerResult) => {
        let s: number = this.getDayStartTs(new Date(value.year, (value.month ?? 1) - 1, value.day ?? 1).getTime());
        this.customStartTs = s;
        let endInit: number = this.customEndTs > 0 ? this.customEndTs : Date.now();
        DatePickerDialog.show({
          start: new Date(s),
          end: new Date(todayEnd),
          selected: new Date(endInit),
          onAccept: (value2: DatePickerResult) => {
            let e: number = this.getDayEndTs(new Date(value2.year, (value2.month ?? 1) - 1, value2.day ?? 1).getTime());
            if (e < s) {
              e = this.getDayEndTs(s);
            }
            this.customEndTs = e;
            this.applyTimeView();
            this.saveTimeViewPrefs();
          }
        });
      }
    });
  }

  // 启动跨日检测定时器：每分钟比对日期 key，跨过午夜时刷新今日视图
  private startDayCheck(): void {
    this.currentDayKey = this.getDayKey(Date.now());
    this.dayCheckTimer = setInterval(() => {
      let key: string = this.getDayKey(Date.now());
      if (key !== this.currentDayKey) {
        this.currentDayKey = key;
        this.onDayChange();
      }
    }, 60 * 1000);
  }

  // 跨日回调：仅当停留在「今日」视图时，重算今日范围并重绘（剔除昨天点，仅留新一天记录）
  private onDayChange(): void {
    if (this.timeViewIndex === TIME_VIEW_TODAY) {
      this.applyTimeView();
    }
  }

  // 日期边界辅助：当天 0 点 / 当天 23:59:59.999 / 日期 key(YYYY-M-D)
  private getDayStartTs(ts: number): number {
    let d: Date = new Date(ts);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }
  private getDayEndTs(ts: number): number {
    let d: Date = new Date(ts);
    d.setHours(23, 59, 59, 999);
    return d.getTime();
  }
  private getDayKey(ts: number): string {
    let d: Date = new Date(ts);
    return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
  }

  // 持久化「时间范围」视图选择与自定义起止日期，下次重进按上次选择恢复
  private saveTimeViewPrefs(): void {
    try {
      let pref = preferences.getPreferencesSync(getContext(this), { name: PREF_NAME });
      pref.putSync(PREF_KEY_TIME_VIEW, this.timeViewIndex);
      pref.putSync(PREF_KEY_CUSTOM_START, this.customStartTs);
      pref.putSync(PREF_KEY_CUSTOM_END, this.customEndTs);
      pref.flushSync();
    } catch (e) {
      let error = e as BusinessError;
      console.error(`saveTimeViewPrefs failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 恢复「时间范围」视图选择与自定义起止日期（默认今日）
  private loadTimeViewPrefs(): void {
    try {
      let pref = preferences.getPreferencesSync(getContext(this), { name: PREF_NAME });
      let idx: number = pref.getSync(PREF_KEY_TIME_VIEW, TIME_VIEW_TODAY) as number;
      // 仅允许 0/1/2 三态，非法值回退今日
      if (idx < 0 || idx > 2) {
        idx = TIME_VIEW_TODAY;
      }
      this.timeViewIndex = idx;
      this.timeViewSelectedIndexes = [idx];
      let cs: number = pref.getSync(PREF_KEY_CUSTOM_START, 0) as number;
      let ce: number = pref.getSync(PREF_KEY_CUSTOM_END, 0) as number;
      // 自定义起止未设置时回退为今天，避免空范围
      if (cs <= 0 || ce <= 0) {
        cs = this.getDayStartTs(Date.now());
        ce = this.getDayEndTs(Date.now());
      }
      this.customStartTs = cs;
      this.customEndTs = ce;
    } catch (e) {
      let error = e as BusinessError;
      console.error(`loadTimeViewPrefs failed, code: ${error.code}, message: ${error.message}`);
      this.timeViewIndex = TIME_VIEW_TODAY;
      this.timeViewSelectedIndexes = [TIME_VIEW_TODAY];
    }
  }


  // 将轨迹点推入缓冲（含精度/速度/时间戳），达到批大小即触发批量落库
  private saveTrackPoint(latLng: mapCommon.LatLng, accuracy: number, speed: number, timestamp: number): void {
    this.pendingPoints.push({
      latitude: latLng.latitude,
      longitude: latLng.longitude,
      timestamp: timestamp,
      accuracy: accuracy,
      speed: speed
    });
    if (this.pendingPoints.length >= Index.BATCH_SIZE) {
      this.flushBatch();
    }
  }

  // 批量落库：用 batchInsert 一次性写入缓冲中的全部轨迹点，降低 DB 写入频率
  private flushBatch(): void {
    if (!this.rdbStore || this.pendingPoints.length === 0) {
      return;
    }
    let values: relationalStore.ValuesBucket[] = [];
    for (let p of this.pendingPoints) {
      values.push({
        latitude: p.latitude,
        longitude: p.longitude,
        timestamp: p.timestamp,
        accuracy: p.accuracy,
        speed: p.speed
      });
    }
    this.rdbStore.batchInsert(TABLE_NAME, values)
      .then((count: number) => {
        console.info(TAG, `flushBatch inserted ${count} points`);
      })
      .catch((err: BusinessError) => {
        console.error(`flushBatch failed, code: ${err.code}, message: ${err.message}`);
      });
    this.pendingPoints = [];
  }

  // 初始化地图初始参数：默认中心点(北京)、缩放级别、各类控件开关。
  // 关键：按已保存的地图样式在初始化阶段就预置 dayNightMode 与 styleId，让首帧直接对：
  //  - 经典：暗色(NIGHT)、不套自定义样式（保持内置暗色底图）
  //  - 暗夜：暗色(NIGHT) + 暗夜自定义样式 ID（init 阶段即请求，避免重进先闪默认「经典」样式）
  //  - 浅白：白天(DAY) + 浅白自定义样式 ID
  // 这样重进应用时第一帧就已是目标样式，不会再闪一下默认样式。
  // 用户仍可在「设置-夜间模式」改选，由 applyNightMode 实时生效（仅覆盖 day/night，不影响自定义样式）。
  private initMapOptions(): void {
    let initialDayNight: mapCommon.DayNightMode =
      (this.mapStyleIndex === 2 || this.mapStyleIndex === 3) ? mapCommon.DayNightMode.DAY : mapCommon.DayNightMode.NIGHT;
    // 初始化阶段就套用自定义样式 ID（暗夜/浅白），经典不设置（undefined 即使用内置样式）
    let initialStyleId: string | undefined =
      this.mapStyleIndex === 1 ? MAP_STYLE_DARK_ID :
      this.mapStyleIndex === 2 ? MAP_STYLE_LIGHT_ID : undefined;
    this.mapOptions = {
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

  // 构造地图初始化回调：地图就绪后保存 controller、开启 3D 建筑、初始化数据库、申请定位权限
  private initMapCallback(): void {
    this.callback = async (err, mapController) => {
      if (!err) {
        this.mapController = mapController;

        // 底部留白：将缩放控件、"我的位置"按钮整体顶到悬浮 tab 栏上方，避免被遮挡
        // 底部留白 = 系统导航条高度 + 悬浮 tab 栏占位（约 90vp），确保控件不被导航条与浮条压住
        this.mapController.setPadding({
          left: 0,
          top: 0,
          right: 0,
          bottom: this.navBarHeight + 90
        });

        // 关闭系统缩放控件（initMapOptions 已设 zoomControlsEnabled=false，这里再次确保运行时关闭）
        this.mapController.setZoomControlsEnabled(false);

        // 关闭地图自带的审图号（setApproveNumberEnabled 对应 MapOptions.approveNumberEnabled）
        try {
          this.mapController.setApproveNumberEnabled(false);
        } catch (e) {
          console.error(TAG, `setApproveNumberEnabled failed: ${JSON.stringify(e)}`);
        }

        // 说明：当前 SDK 的 Map Kit 未提供「隐藏 Logo」的 API，Logo 无法关闭，保持默认显示。

        // 调整指南针位置：位于右上角，并整体下移到「时间范围」切换浮层下方，
        // 避免与右侧的日期切换浮层及顶部状态栏/导航栏重叠。
        // setCompassPosition 以地图组件左上角为原点、单位为 px（地图全屏沉浸，故等同于屏幕左上角）。
        try {
          let ctx = getContext(this) as common.UIAbilityContext;
          window.getLastWindow(ctx).then((win: window.Window) => {
            let screenWidth: number = win.getWindowProperties().windowRect.width; // px
            // Y：状态栏下方再下移 72vp，落在右侧日期切换浮层下方；X：右侧留 12vp 间距，指南针约 48vp 宽
            let point: mapCommon.MapPoint = {
              positionX: screenWidth - vp2px(12) - vp2px(48),
              positionY: vp2px(72 + this.statusBarHeight)
            };
            this.mapController?.setCompassPosition(point);
          }).catch((err: BusinessError) => {
            console.error(TAG, `setCompassPosition failed, code: ${err.code}, message: ${err.message}`);
          });
        } catch (e) {
          console.error(TAG, `setCompassPosition try failed: ${JSON.stringify(e)}`);
        }

        console.info(TAG, 'Map initialized successfully');

        // 点击地图空白区域切换沉浸模式：第一次进入纯净地图，再点一次恢复叠加 UI
        this.mapEventManager = this.mapController.getEventManager();
        this.mapEventManager.on('mapClick', () => {
          const next = !this.immersive;
          // 用动画驱动沉浸式状态切换，让叠加浮层（足迹统计/日期切换）跟 tab 栏一样淡入淡出
          animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
            this.immersive = next;
          });
          // 沉浸模式隐藏 tab 栏时控件避让系统导航条；普通模式上移到 tab 栏上方（含系统导航条高度避让）
          this.mapController?.setPadding({
            left: 0,
            top: 0,
            right: 0,
            bottom: next ? this.navBarHeight : this.navBarHeight + 90
          });
          // 沉浸模式：隐藏底部页签栏（含迷你栏），只保留纯净地图；再次点击恢复
          if (next) {
            this.tabsController.applyHideAnimation(HdsAnimationMode.CLICK_ANIMATION);
          } else {
            this.tabsController.applyShowAnimation(HdsAnimationMode.CLICK_ANIMATION);
          }
        });

        this.enable3DBuilding();
        // 地图就绪后按已存（或默认）的样式强制应用一次，确保重进后保持上次选择
        this.applyMapStyleToMap(this.mapStyleIndex);
        await this.initDatabase();
        this.checkAndRequestPermission();
      } else {
        console.error(`Failed to initialize the map, code: ${err.code}, message: ${err.message}`);
      }
    };
  }




  // 开启地图 3D 建筑显示效果
  private enable3DBuilding(): void {
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

  // 读取三项定位权限(大致/精确/后台)的当前授权状态，更新对应 @State 供 UI 展示
  private async refreshPermissionState(): Promise<void> {
    let hasForeground = await this.checkAccessToken('ohos.permission.APPROXIMATELY_LOCATION');
    this.hasApproximatelyLocation = hasForeground === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;

    let hasLocation = await this.checkAccessToken('ohos.permission.LOCATION');
    this.hasLocation = hasLocation === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;

    let hasBackground = await this.checkAccessToken('ohos.permission.LOCATION_IN_BACKGROUND');
    this.hasBackgroundLocation = hasBackground === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;

  }

  // 权限编排：先刷新状态；缺前台定位则申请，否则缺后台定位则引导；均满足后开启我的位置
  private async checkAndRequestPermission(): Promise<void> {
    await this.refreshPermissionState();

    if (!this.hasApproximatelyLocation || !this.hasLocation) {
      this.requestPermissions();
      return;
    }
    if (!this.hasBackgroundLocation) {
      this.requestBackgroundLocationPermission();
    }
    this.enableMyLocation();
  }


  // 查询指定权限是否已授权：通过 bundleInfo 获取 tokenId，再调用 atManager.checkAccessToken
  private async checkAccessToken(permission: Permissions): Promise<abilityAccessCtrl.GrantStatus> {
    let atManager = abilityAccessCtrl.createAtManager();
    let grantStatus = abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;
    let tokenId = 0;

    try {
      let bundleInfo = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      tokenId = bundleInfo.appInfo.accessTokenId;
      grantStatus = await atManager.checkAccessToken(tokenId, permission);
      console.info(TAG, `checkAccessToken ${permission}: ${grantStatus}`);
    } catch (error) {
      let err = error as BusinessError;
      console.error(`Failed to check access token. Code: ${err.code}, message: ${err.message}`);
    }

    return grantStatus;
  }

  // 向前台定位权限(大致 + 精确)发起授权申请；结果返回后继续处理后后台定位并开启我的位置
  private requestPermissions(): void {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let atManager = abilityAccessCtrl.createAtManager();
    let permissions: Array<Permissions> = [
      'ohos.permission.APPROXIMATELY_LOCATION',
      'ohos.permission.LOCATION'
    ];
    atManager.requestPermissionsFromUser(context, permissions)
      .then(async (result) => {
        let authResults: Array<number> = result.authResults;
        this.hasApproximatelyLocation = authResults[0] === 0;
        this.hasLocation = authResults[1] === 0;
        
        let hasBackground = await this.checkAccessToken('ohos.permission.LOCATION_IN_BACKGROUND');
        this.hasBackgroundLocation = hasBackground === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
        
        if (this.hasApproximatelyLocation && this.hasLocation) {
          if (!this.hasBackgroundLocation) {
            this.requestBackgroundLocationPermission();
          }
          this.enableMyLocation();
        } else {
          // 用户拒绝或此前已选「不再询问」导致系统不再弹授权框时，
          // 弹出应用内引导对话框，避免点击后无任何反应
          console.warn(TAG, 'Location permission denied, please grant in Settings');
          this.guideToLocationSettings();
        }
      })
      .catch((err: BusinessError) => {
        console.error(`Failed to request permissions from user. Code: ${err.code}, message: ${err.message}`);
      });
  }

  // 弹窗引导用户去系统设置将定位改为「始终允许」，以支持后台持续记录轨迹
  private requestBackgroundLocationPermission(): void {
    let uiContext = this.getUIContext();
    uiContext.getPromptAction().showDialog({
      title: '开启后台定位',
      message: '请在设置中将定位权限改为"始终允许"，并开启"精确定位"，以支持后台持续记录轨迹。',
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '开启权限', color: '#007DFF' }
      ]
    }).then((result) => {
      if (result.index === 1) {
        this.openPermissionSettings();
      }
    }).catch((err: BusinessError) => {
      console.error(`showDialog failed. Code: ${err.code}, message: ${err.message}`);
    });
  }

  // 前台定位权限被拒 / 系统不再弹授权框时，弹出应用内引导对话框，
  // 提示并引导用户前往系统设置手动开启「大致位置」与「精确位置」
  private guideToLocationSettings(): void {
    AlertDialog.show({
      title: '定位权限未开启',
      message: '请前往系统设置开启"大致位置"与"精确位置"。',
      primaryButton: {
        value: '暂不',
        action: () => {}
      },
      secondaryButton: {
        value: '前往设置',
        fontColor: $r('sys.color.ohos_id_color_activated'),
        action: () => {
          this.openPermissionSettings();
        }
      }
    });
  }


  // 跳转到系统「应用信息」设置页，便于用户手动修改定位权限
  private async openPermissionSettings(): Promise<void> {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      let want: Want = {
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility',
        uri: 'application_info_entry',
        parameters: {
          pushParams: context.abilityInfo.bundleName
        }
      };
      await context.startAbility(want);
    } catch (err) {
      let error = err as BusinessError;
      console.error(`Failed to open settings. Code: ${error.code}, message: ${error.message}`);
    }
  }

  // 开启「我的位置」图层：设置定位样式、移动相机到当前位置(WGS84→GCJ02 转换)，
  // 并注册位置变化监听；每次回调都会把坐标转 GCJ02 后记录为轨迹点。
  private async enableMyLocation(): Promise<void> {
    if (!this.mapController) {
      console.warn(TAG, 'mapController is null');
      return;
    }

    try {
      let style: mapCommon.MyLocationStyle = {
        displayType: mapCommon.MyLocationDisplayType.FOLLOW_ROTATE
      };
      await this.mapController.setMyLocationStyle(style);

      this.mapController.setMyLocationEnabled(true);
      this.mapController.setMyLocationControlsEnabled(true);
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
      this.mapController.moveCamera(cameraPosition);
      console.info(TAG, `Camera moved to user location: ${gcj02Location.latitude}, ${gcj02Location.longitude}`);

      // 定位策略：NAVIGATION场景，按当前模式间隔回调；静止时降频到 STATIONARY_INTERVAL
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
          if (this.recentPoints.length > Index.STATIONARY_WINDOW) {
            this.recentPoints.shift();
          }
          if (this.detectStationary()) {
            if (!this.isStationary) {
              this.isStationary = true;
              this.switchLocationInterval(Index.STATIONARY_INTERVAL);
            }
            return;
          }
          if (this.isStationary) {
            // 静止退出迟滞：抖动常使 detectStationary 短暂失效，不应立刻恢复记录。
            // 仅当新点明显远离常驻簇（超过退出半径）才判为真正离开，否则仍视为原地抖动、不记录。
            let centroid: mapCommon.LatLng | null = this.getRecentCentroid();
            if (centroid !== null && this.calculateDistance(gcj02, centroid) < Index.STATIONARY_EXIT_RADIUS) {
              return;
            }
            this.isStationary = false;
            this.switchLocationInterval(this.getModeInterval());
          }
          // 精度过滤：超出当前模式精度门槛的漂移点整体丢弃（折线/足迹点都不记）
          if (location.accuracy > MODE_CONFIG[this.currentMode].maxAccuracy) {
            return;
          }
          // 实时位置：通过精度门槛即采纳为 liveLocation（不入库），用于把已确认折线末端连到当前真实位置，
          // 覆盖「静止/速度门槛过滤致终点断点」与「等待下一个确认点才绘制导致的空白」两种场景
          this.liveLocation = gcj02;
          this.updateLivePolyline();
          if (this.trackPoints.length > 0) {
            let lastPoint: mapCommon.LatLng = this.trackPoints[this.trackPoints.length - 1];
            let distance: number = this.calculateDistance(lastPoint, gcj02);
            // 折线位移地板：与上一个折线点距离 < 5m 视为原地抖动，丢弃
            if (distance < Index.MIN_TRACK_DISTANCE) {
              return;
            }
          }
          // 速度门槛：定位上报速度低于静止门槛，视为原地未移动，丢弃避免折线原地漂移
          if (location.speed !== undefined && location.speed < Index.STATIONARY_SPEED) {
            return;
          }
          this.recordTrackPoint(gcj02, location.accuracy, location.speed !== undefined ? location.speed : 0);
        });
      };
      geoLocationManager.on('locationChange', locationRequest, this.locationCallback);
      console.info(TAG, 'Location change listener registered');
    } catch (err) {
      let error = err as BusinessError;
      console.error(`Failed to enable my location, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 静止检测：最近窗口内所有点到质心的最大距离 < STATIONARY_RADIUS 则判定为静止
  private detectStationary(): boolean {
    if (this.recentPoints.length < Index.STATIONARY_WINDOW) {
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
      if (this.calculateDistance(point, centroid) >= Index.STATIONARY_RADIUS) {
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

  // 获取当前模式对应的定位回调间隔（秒）
  private getModeInterval(): number {
    return MODE_CONFIG[this.currentMode].timeInterval;
  }

  // 切换定位记录模式：更新 currentMode 并重新注册定位监听（静止状态下保持静止间隔，避免打断降频）
  private switchMode(mode: number): void {
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

  // 定位回调核心（Option B）：折线每通过「精度过滤+5m地板」的点都记（保持平滑）；
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
    this.allTrackPoints.push(rec);

    // 仅当落点在当前可见时间范围才更新可见集与统计（否则仅入库、不显示）
    if (this.isInVisibleRange(ts)) {
      // 折线：每通过过滤的点都记，保证轨迹相对顺滑
      let prevLast: mapCommon.LatLng | null = this.trackPoints.length > 0 ? this.trackPoints[this.trackPoints.length - 1] : null;
      this.trackPoints.push(latLng);
      this.trackCount = this.trackPoints.length;
      if (prevLast) {
        this.totalDistance += this.calculateDistance(prevLast, latLng);
      }
      // 足迹点：仅当距上一个足迹点的直线距离 ≥ 当前模式 distanceInterval 才记
      if (this.shouldRecordFootprint(latLng)) {
        this.footprintPoints.push(latLng);
        this.lastFootprintPoint = latLng;
      }
      // 覆盖物节流刷新（折线/足迹点分别计数）
      this.refreshOverlayOptimized();
    }

    // 落库：推入缓冲，达到批大小即批量写入
    this.saveTrackPoint(latLng, accuracy, speed, ts);
  }

  // 判断是否达到「足迹」记录阈值：距上一个足迹点直线距离 ≥ 当前模式 distanceInterval 才记一次
  private shouldRecordFootprint(current: mapCommon.LatLng): boolean {
    if (!this.lastFootprintPoint) {
      return true;
    }
    let distance: number = this.calculateDistance(this.lastFootprintPoint, current);
    return distance >= MODE_CONFIG[this.currentMode].distanceInterval;
  }

  // 使用 Haversine 公式估算两点间地表距离(米)
  private calculateDistance(from: mapCommon.LatLng, to: mapCommon.LatLng): number {
    let R: number = 6371000;
    let dLat: number = (to.latitude - from.latitude) * Math.PI / 180;
    let dLon: number = (to.longitude - from.longitude) * Math.PI / 180;
    let a: number = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(from.latitude * Math.PI / 180) * Math.cos(to.latitude * Math.PI / 180) *
      Math.sin(dLon / 2) * Math.sin(dLon / 2);
    let c: number = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
  }

  // 将米格式化为易读里程：不足 1 公里显示「米」，否则显示「公里（保留两位）」
  private formatDistance(meters: number): string {
    if (meters < 1000) {
      return `${Math.round(meters)} 米`;
    }
    return `${(meters / 1000).toFixed(2)} 公里`;
  }

  // 将时间戳格式化为「YYYY-MM-DD」用于统计面板展示（补零对齐标准格式）
  private formatStatDate(ts: number): string {
    if (!ts) {
      return '—';
    }
    let d: Date = new Date(ts);
    let m: number = d.getMonth() + 1;
    let day: number = d.getDate();
    return `${d.getFullYear()}-${m < 10 ? '0' + m : m}-${day < 10 ? '0' + day : day}`;
  }

  // 基于全量 allTrackPoints 派生统计指标：累计里程 / 足迹点 / 活跃天数 / 日均 / 最长单日 / 首末记录 / 最近7天分布
  // 调用时机：① DB 载入完成后（loadTrackPoints）；② 每次打开统计面板前（保证随实时记录保持新鲜）
  private computeStats(): void {
    let pts: TrackPointRecord[] = this.allTrackPoints;
    if (!pts || pts.length === 0) {
      this.statTotalDistance = 0;
      this.statTrackCount = 0;
      this.statActiveDays = 0;
      this.statAvgDailyDist = 0;
      this.statMaxDailyDist = 0;
      this.statFirstTs = 0;
      this.statLastTs = 0;
      this.statRecent7 = [];
      return;
    }

    let totalDist: number = 0;
    let dailyDist: Map<string, number> = new Map();
    let dailyCount: Map<string, number> = new Map();
    let prev: mapCommon.LatLng | null = null;
    let prevKey: string = '';
    for (let i = 0; i < pts.length; i++) {
      let rec: TrackPointRecord = pts[i];
      let key: string = this.getDayKey(rec.timestamp);
      let latLng: mapCommon.LatLng = { latitude: rec.latitude, longitude: rec.longitude };
      if (prev && prevKey === key) {
        let d: number = this.calculateDistance(prev, latLng);
        totalDist += d;
        dailyDist.set(key, (dailyDist.get(key) ?? 0) + d);
      }
      prev = latLng;
      prevKey = key;
      dailyCount.set(key, (dailyCount.get(key) ?? 0) + 1);
    }

    let activeDays: number = dailyCount.size;
    let maxDaily: number = 0;
    dailyDist.forEach((v: number) => {
      if (v > maxDaily) {
        maxDaily = v;
      }
    });

    // 最近 7 天（含今天）每日里程与点数分布
    let recent: StatDayItem[] = [];
    let now: Date = new Date();
    for (let i = 6; i >= 0; i--) {
      let d: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i);
      let key: string = `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
      recent.push({
        label: `${d.getMonth() + 1}/${d.getDate()}`,
        distance: dailyDist.get(key) ?? 0,
        count: dailyCount.get(key) ?? 0
      });
    }

    this.statTotalDistance = totalDist;
    this.statTrackCount = pts.length;
    this.statActiveDays = activeDays;
    this.statAvgDailyDist = activeDays > 0 ? totalDist / activeDays : 0;
    this.statMaxDailyDist = maxDaily;
    this.statFirstTs = pts[0].timestamp;
    this.statLastTs = pts[pts.length - 1].timestamp;
    this.statRecent7 = recent;
  }



  private updatePolyline(): void {
    if (!this.trackPolyline) {
      let polylineOption: mapCommon.MapPolylineOptions = {
        points: this.trackPoints,
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
      this.trackPolyline.setPoints(this.trackPoints);
    }
    // 同步节流计数：本次已把全部折线点刷新到地图
    this.lastPolylineUpdatePointCount = this.trackPoints.length;
  }

  // 实时连线：把已确认折线的末端（或首个确认点）连到当前实时位置 liveLocation，
  // 让红线始终延伸到你脚下，消除「已确认点 → 真实位置」之间的空白与终点断点。
  // liveLocation 仅过精度门槛、不入库，因此不影响 trackPoints 的防漂移落库逻辑。
  private updateLivePolyline(): void {
    if (!this.liveLocation || this.displayMode !== 0) {
      return;
    }
    // 尚无任何确认点、或实时位置与末端确认点几乎重合（已停下）时不成线，避免零长线段
    if (this.trackPoints.length === 0) {
      return;
    }
    let lastConfirmed: mapCommon.LatLng = this.trackPoints[this.trackPoints.length - 1];
    if (this.calculateDistance(lastConfirmed, this.liveLocation) < 1) {
      return;
    }
    let points: mapCommon.LatLng[] = [lastConfirmed, this.liveLocation];
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
  private buildMassPointItems(): mapCommon.MassPointItem[] {
    let items: mapCommon.MassPointItem[] = [];
    for (let i = 0; i < this.footprintPoints.length; i++) {
      let item: mapCommon.MassPointItem = {
        itemId: `footprint_${i}`,
        position: this.footprintPoints[i],
        title: `足迹${i + 1}`
      };
      items.push(item);
    }
    return items;
  }

  // 海量点模式：首次创建红色圆点覆盖物，之后仅 setItems 增量更新
  private updateMassPointOverlay(): void {
    if (!this.redDotIcon) {
      console.warn(TAG, 'redDotIcon is not ready');
      return;
    }
    if (!this.massPointOverlay) {
      let params: mapCommon.MassPointOverlayParams = {
        id: 'footprint_overlay',
        items: this.buildMassPointItems(),
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
      this.massPointOverlay.setItems(this.buildMassPointItems());
    }
    // 同步节流计数：本次已把全部足迹点刷新到地图
    this.lastFootprintUpdateCount = this.footprintPoints.length;
  }

  // 覆盖物节流刷新（折线 / 足迹点海量点）：按展示模式分别判断「新增点数」与「距上次刷新时间」，
  // 任一达标才真正刷新；MapPolyline.setPoints / MassPointOverlay.setItems 仅支持整体替换，故为降频整体刷新
  private refreshOverlayOptimized(): void {
    let now: number = Math.floor(Date.now() / 1000);
    if (this.displayMode === 0) {
      let gap: number = this.trackPoints.length - this.lastPolylineUpdatePointCount;
      if (gap < Index.POLYLINE_UPDATE_POINT_GAP && (now - this.lastOverlayUpdateTs) < Index.OVERLAY_UPDATE_INTERVAL) {
        return;
      }
      this.updatePolyline();
    } else {
      let gap: number = this.footprintPoints.length - this.lastFootprintUpdateCount;
      if (gap < Index.FOOTPRINT_UPDATE_POINT_GAP && (now - this.lastOverlayUpdateTs) < Index.OVERLAY_UPDATE_INTERVAL) {
        return;
      }
      this.updateMassPointOverlay();
    }
    this.lastOverlayUpdateTs = now;
  }

  // 切换展示模式(0 折线 / 1 海量点)：移除另一种模式的覆盖物，并重建当前模式
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

    if (mode === 0) {
      if (this.massPointOverlay) {
        this.massPointOverlay.remove();
        this.massPointOverlay = null;
      }
      if (this.trackPoints.length > 0) {
        this.updatePolyline();
        this.updateLivePolyline();
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
      if (this.trackPoints.length > 0) {
        this.updateMassPointOverlay();
      }
    }
  }

  // 清空全部轨迹：移除地图覆盖物、清空内存数组、并删除数据库中的轨迹记录
  private async clearTrack(): Promise<void> {
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
    this.allTrackPoints = [];
    this.trackPoints = [];
    this.trackCount = 0;
    this.totalDistance = 0;
    this.footprintPoints = [];
    this.lastFootprintPoint = null;
    this.liveLocation = null;
    this.pendingPoints = [];
    this.lastPolylineUpdatePointCount = 0;
    this.lastFootprintUpdateCount = 0;
    if (this.rdbStore) {
      try {
        let predicates = new relationalStore.RdbPredicates(TABLE_NAME);
        await this.rdbStore.delete(predicates);
      } catch (err) {
        let error = err as BusinessError;
        console.error(`clearTrack DB failed, code: ${error.code}, message: ${error.message}`);
      }
    }
    // 删除全部后按当前时间视图重建可见集（此时为空，覆盖物随之清空）
    this.applyTimeView();
    console.info(TAG, 'Track cleared');
  }

  // 删除前二次确认弹窗，确认后调用 clearTrack
  private confirmClearTrack(): void {
    AlertDialog.show({
      title: '删除轨迹',
      message: `确定要删除全部 ${this.allTrackPoints.length} 条轨迹记录吗？此操作不可恢复。`,
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

  // 根据 nightModeIndex(0 跟随系统 /1 普通 /2 夜间) 设置地图日夜模式
  private applyNightMode(index: number): void {
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

  private switchMapStyle(index: number): void {
    if (this.mapStyleIndex === index) {
      return;
    }
    this.mapStyleIndex = index;
    this.mapStyle2SelectedIndexes = [index];
    // 切换即持久化，下次重进按上次选择恢复，而非重置为经典
    this.saveMapStyle(index);
    this.applyMapStyleToMap(index);
  }

  // 将指定地图样式应用到地图（与 switchMapStyle 解耦，供地图就绪后按已存值强制应用）
  private applyMapStyleToMap(index: number): void {
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

  // 持久化地图样式到偏好存储
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

  // 从偏好存储读取上次保存的地图样式（默认 0=经典）
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
  // 结构：HdsNavigation → HdsTabs(足迹 / 我的)
  //  - 足迹 Tab：全屏地图 + 左上角权限状态条；轨迹类型切换改由「地图工具」面板内的官方 SegmentButton 承载
  //  - 我的 Tab：点击时改为弹出半模态面板(buildSheetContent)，不切换整页
  build() {
    HdsNavigation() {
      Stack({ alignContent: Alignment.TopStart }) {
        HdsTabs({ controller: this.tabsController }) {
        TabContent() {
          Stack() {
            MapComponent({ mapOptions: this.mapOptions, mapCallback: this.callback })
              .width('100%')
              .height('100%')
              // 地图直接显示（已撤销预加载遮罩）；opacity 保持 1 避免 ArkUI 不绘制底层地图 Surface
              .opacity(1)


            // 左上角胶囊组：足迹统计 + 常驻点，统一放进一个 Column({ space: 10 })，
            // 使常驻点恒定处于足迹胶囊下方 10vp（无需为动态高度写死 y）。
            Column({ space: 10 }) {
              // 足迹统计胶囊：无图标，足迹点数与累计里程分两行显示（有轨迹时才展示）。
              if (this.trackCount > 0 && !this.immersive) {
                Column({ space: 2 }) {
                  Text(`足迹点 ${this.trackCount}`)
                    .fontSize(13)
                    .fontColor($r('sys.color.font_primary'))
                    .fontWeight(FontWeight.Medium)
                    .textAlign(TextAlign.Start)
                  Text(this.formatDistance(this.totalDistance))
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

            // 右上角的「时间范围」切换浮层（总览 / 自定义 / 今日）：打开 App 即可见、随时切换。
            // 玻璃拟态底色由外层 Row 承载，与「足迹统计 / 常驻点」胶囊统一（rgba(255,255,255,0.1)），
            // 内层 SegmentButton 透明透出容器背景；靠右对齐、右侧留出 16vp 安全边距，避开左上角统计胶囊。
            // 用 if(!immersive) + transition 实现跟 tab 栏一致的淡出淡入动效。
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

        // 「画板」Tab：本体留空，仅作为 tab 按钮载体；点击交互由下方 onContentWillChange 拦截并弹出地图工具半模态面板，
        // 替代原先悬浮在地图上的 paintpalette_fill 圆形按钮，使入口统一收归底部页签栏。
        TabContent() {
          Column()
            .width('100%')
            .height('100%')
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.paintpalette_fill'))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_primary')]),
          selected: new SymbolGlyphModifier($r('sys.symbol.paintpalette_fill'))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_activated')])
        }, '画板'))

        // 「我的」Tab：本体留空，仅作为 tab 按钮载体；点击交互由下方 onContentWillChange 拦截并弹出半模态面板
        TabContent() {
          Column()
            .width('100%')
            .height('100%')
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1'))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_primary')]),
          selected: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1'))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_activated')])
        }, '我的'))

        // 「统计」Tab：本体留空，仅作为 tab 按钮载体；点击交互由下方 onContentWillChange 拦截并弹出足迹统计半模态面板
        TabContent() {
          Column()
            .width('100%')
            .height('100%')
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.calendar'))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_primary')]),
          selected: new SymbolGlyphModifier($r('sys.symbol.calendar'))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('sys.color.ohos_id_color_activated')])
        }, '统计'))
      }
      .barOverlap(true)
      .vertical(false)
      .barPosition(BarPosition.End)
      .scrollable(false)
      // 点「画板」(index=1) 拦截整页切换，改为弹出地图工具半模态面板；点「我的」(index=2) 同样拦截弹出半模态面板
      .onContentWillChange((_currentIndex: number, comingIndex: number) => {
        if (comingIndex === 1) {
          this.isShowMapToolSheet = true;
          return false;
        }
        if (comingIndex === 2) {
          this.isShowSheet = true;
          return false;
        }
        if (comingIndex === 3) {
          this.computeStats();
          this.isShowStatsSheet = true;
          return false;
        }
        return true;
      })
      .barFloatingStyle({
        // 浮条整体抬过系统导航条：距底 = 基础 28vp + 导航条高度
        barBottomMargin: 28 + this.navBarHeight,
        gradientMask: {
          maskColor: Color.Transparent
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: this.customMaterialLevel
        }
      })

      // 画板（地图工具）面板宿主：独立于地图 Stack 的常驻空节点，避免面板挂在地图上
      Column()
        .width(0)
        .height(0)
        .bindSheet($$this.isShowMapToolSheet, this.buildMapToolSheetContent(), {
          detents: [SheetSize.MEDIUM, SheetSize.LARGE],
          title: { title: '地图工具' },
          dragBar: true,
          showClose: true,
          onDisappear: () => {
            this.isShowMapToolSheet = false;
          }
        })

      // 足迹统计面板宿主：独立于地图 / Tabs 的常驻空节点
      Column()
        .width(0)
        .height(0)
        .bindSheet($$this.isShowStatsSheet, this.buildStatsSheetContent(), {
          detents: [SheetSize.MEDIUM, SheetSize.LARGE],
          dragBar: true,
          showClose: true,
          title: { title: '足迹统计' },
          onDisappear: () => {
            this.isShowStatsSheet = false;
          }
        })
      }
      .width('100%')
      .height('100%')
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideBackButton(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindSheet($$this.isShowSheet, this.buildSheetContent(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      onDisappear: () => {
        this.isShowSheet = false;
      }
    })
  }

  // 「足迹统计」半模态面板内容：基于全量 allTrackPoints 的统计数据，参考「一生足迹 / 灵感足迹 / 点点足迹」统计呈现
  @Builder
  buildStatsSheetContent(): void {
    Scroll() {
      Column({ space: 16 }) {
        // 顶部占位：把内容整体下移到拖拽条下方，避免与拖拽条重叠（仿 buildSheetContent）
        Column().width('100%').height(6)

        if (this.statTrackCount === 0) {
          // 空态兜底：无足迹数据时给出标准占位提示（plan「实现注意」要求）
          Column() {
            Text('暂无足迹数据')
              .fontSize(14)
              .fontColor($r('sys.color.font_primary'))
              .opacity(0.5)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 40, bottom: 40 })
        } else {
          // === 核心三卡：累计里程 / 足迹点总数 / 记录天数 ===
          Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text(this.formatDistance(this.statTotalDistance))
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

        // === 详细指标网格（两列）===
        Column({ space: 12 }) {
          Row({ space: 12 }) {
            this.buildStatItem(this.formatDistance(this.statAvgDailyDist), '平均每日里程')
            this.buildStatItem(this.formatDistance(this.statMaxDailyDist), '最长单日里程')
          }
          .width('100%')

          Row({ space: 12 }) {
            this.buildStatItem(this.formatStatDate(this.statFirstTs), '首次记录')
            this.buildStatItem(this.formatStatDate(this.statLastTs), '最近记录')
          }
          .width('100%')
        }
        .width('100%')
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(16)
        .padding(16)

        // === 常驻点状态卡（复用 isStationary）===
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

        // === 最近 7 天里程分布 ===
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
                Text(`${item.count} 点 · ${this.formatDistance(item.distance)}`)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_primary'))
                  .opacity(0.7)
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)

              // 进度条：当日里程占「最长单日里程」的比例
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

        // === 当前时间视图数据（与「累计」对照）===
        Column({ space: 8 }) {
          Text(this.timeViewIndex === TIME_VIEW_OVERVIEW ? '当前视图（总览）'
            : this.timeViewIndex === TIME_VIEW_CUSTOM ? '当前视图（自定义）' : '当前视图（今日）')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')

          Row({ space: 12 }) {
            Column({ space: 2 }) {
              Text(this.formatDistance(this.totalDistance))
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
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 24 })
    }
    .height('100%')
    .width('100%')
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

  // 「我的」半模态面板内容：内嵌 Navigation 承载 Mine 组件，并叠加「设置」二级半模态
  @Builder
  buildSheetContent(): void {
    Column() {
      // 顶部占位：把 Navigation（含标题栏）整体下移到拖拽条下方，避免标题栏上移/与拖拽条重叠
      Column().width('100%').height(6)
      Navigation() {
        Mine({
          onSettingClick: () => { this.isShowSettingSheet = true; },
          onLocationPermissionClick: () => {
            this.refreshPermissionState();
            this.isShowLocationSheet = true;
          },
          locationAbnormal: !(this.hasApproximatelyLocation && this.hasLocation && this.hasBackgroundLocation),
          recordMode: this.currentMode,
          onRecordModeClick: () => { this.isShowRecordModeSheet = true; }
        })
          // 「定位模式」面板：挂在 Mine 组件上，避免与 Navigation 上的定位权限 sheet 冲突
          .bindSheet($$this.isShowRecordModeSheet, this.buildRecordModeSheetContent(), {
            height: SheetSize.LARGE,
            dragBar: true,
            showClose: false,
            onDisappear: () => {
              this.isShowRecordModeSheet = false;
            }
          })
      }
      .title('我的', { backgroundColor: $r('sys.color.background_secondary') })
      .titleMode(NavigationTitleMode.Mini)
      .hideBackButton(true)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
      .mode(NavigationMode.Stack)
      .menus([
        {
          value: '',
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.xmark'))
            .fontSize(22)
            .fontColor([$r('sys.color.font_primary')]),
          action: () => {
            this.isShowSheet = false;
          }
        }
      ])
      .width('100%')
      .layoutWeight(1)
      // 「定位权限」面板：嵌套半模态，绑在 Navigation 上，避免与下方设置面板的 bindSheet 冲突
      .bindSheet($$this.isShowLocationSheet, this.buildLocationSheetContent(), {
        height: SheetSize.LARGE,
        dragBar: true,
        showClose: false,
        onDisappear: () => {
          this.isShowLocationSheet = false;
        }
      })
    }
    .width('100%')
    .height('100%')
    // 「设置」面板：嵌套半模态，浮在"我的"上方，不关闭"我的"
    .bindSheet($$this.isShowSettingSheet, this.buildSettingSheetContent(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      onDisappear: () => {
        this.isShowSettingSheet = false;
        this.settingStack.clear();
      }
    })
  }

  // 「设置」面板根内容：固定模板分组(字体大小/夜间模式/通知/删除轨迹/版本/关于/隐私/Web) + 自定义分组
  @Builder
  settingRootContent() {
    Column() {
      Scroll() {
            Column({ space: 12 }) {
              Column() {
                Row() {
                  Text('固定模板')
                    .fontSize(14)
                    .fontColor($r('sys.color.font_secondary'))
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 16, bottom: 8 })

                List() {
                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Text('字体大小')
                          .fontSize(16)
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .textAlign(TextAlign.Start)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Row() {
                        SymbolGlyph($r('sys.symbol.chevron_right'))
                          .fontSize(24)
                          .fontColor([$r('sys.color.font_fourth')])
                          .margin({ left: 4 })
                      }
                      .justifyContent(FlexAlign.End)
                      .margin({ left: 16 })
                    }
                    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                    .constraintSize({ minHeight: 48 })
                    .borderRadius(16)
                  }

                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Text('夜间模式')
                          .fontSize(16)
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .textAlign(TextAlign.Start)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Row() {
                        Text(this.displayModeOptions[this.nightModeIndex])
                          .fontSize(14)
                          .fontColor($r('sys.color.font_secondary'))
                          .maxFontScale(1.3)
                          .constraintSize({ maxWidth: '50%' })
                        SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
                          .fontSize(12)
                          .fontColor([$r('sys.color.font_fourth')])
                          .margin({ left: 4 })
                      }
                      .justifyContent(FlexAlign.End)
                      .margin({ left: 16 })
                      .onClick(() => {
                        this.showDisplayModePopup = !this.showDisplayModePopup;
                      })
                      .bindPopup(this.showDisplayModePopup, {
                        builder: this.displayModePopupBuilder(),
                        enableArrow: false,
                        autoCancel: true,
                        placement: Placement.BottomRight,
                        width: 224,
                        offset: { x: 12, y: 8 },
                        onWillDismiss: () => {
                          this.showDisplayModePopup = false;
                        }
                      })
                    }
                    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                    .constraintSize({ minHeight: 48 })
                    .borderRadius(16)
                  }

                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Text('通知开关')
                          .fontSize(16)
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .textAlign(TextAlign.Start)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Row() {
                        Toggle({ type: ToggleType.Switch, isOn: $$this.pushSwitchOn })
                          .selectedColor($r('sys.color.ohos_id_color_warning'))
                      }
                      .justifyContent(FlexAlign.End)
                      .margin({ left: 16 })
                    }
                    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                    .constraintSize({ minHeight: 48 })
                    .borderRadius(16)
                  }

                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Text('删除轨迹')
                          .fontSize(16)
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .textAlign(TextAlign.Start)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Row() {
                        Text(`${this.trackCount}`)
                          .fontSize(14)
                          .fontColor($r('sys.color.font_secondary'))
                          .maxFontScale(1.3)
                          .constraintSize({ maxWidth: '50%' })
                        SymbolGlyph($r('sys.symbol.chevron_right'))
                          .fontSize(24)
                          .fontColor([$r('sys.color.font_fourth')])
                          .margin({ left: 4 })
                      }
                      .justifyContent(FlexAlign.End)
                      .margin({ left: 16 })
                    }
                    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                    .constraintSize({ minHeight: 48 })
                    .borderRadius(16)
                    .onClick(() => {
                      this.confirmClearTrack();
                    })
                  }

                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Text('检测版本')
                          .fontSize(16)
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .textAlign(TextAlign.Start)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Row() {
                        SymbolGlyph($r('sys.symbol.chevron_right'))
                          .fontSize(24)
                          .fontColor([$r('sys.color.font_fourth')])
                          .margin({ left: 4 })
                      }
                      .justifyContent(FlexAlign.End)
                      .margin({ left: 16 })
                    }
                    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                    .constraintSize({ minHeight: 48 })
                    .borderRadius(16)
                  }

                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Text('关于我们')
                          .fontSize(16)
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .textAlign(TextAlign.Start)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Row() {
                        SymbolGlyph($r('sys.symbol.chevron_right'))
                          .fontSize(24)
                          .fontColor([$r('sys.color.font_fourth')])
                          .margin({ left: 4 })
                      }
                      .justifyContent(FlexAlign.End)
                      .margin({ left: 16 })
                    }
                    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                    .constraintSize({ minHeight: 48 })
                    .borderRadius(16)
                  }

                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Text('隐私设置')
                          .fontSize(16)
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .textAlign(TextAlign.Start)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Row() {
                        SymbolGlyph($r('sys.symbol.chevron_right'))
                          .fontSize(24)
                          .fontColor([$r('sys.color.font_fourth')])
                          .margin({ left: 4 })
                      }
                      .justifyContent(FlexAlign.End)
                      .margin({ left: 16 })
                    }
                    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                    .constraintSize({ minHeight: 48 })
                    .borderRadius(16)
                    .onClick(() => {
                      this.settingStack.pushPathByName('privacy', null);
                    })
                  }

                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Text('Web页面')
                          .fontSize(16)
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .textAlign(TextAlign.Start)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Row() {
                        SymbolGlyph($r('sys.symbol.chevron_right'))
                          .fontSize(24)
                          .fontColor([$r('sys.color.font_fourth')])
                          .margin({ left: 4 })
                      }
                      .justifyContent(FlexAlign.End)
                      .margin({ left: 16 })
                    }
                    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                    .constraintSize({ minHeight: 48 })
                    .borderRadius(16)
                  }
                }
                .width('100%')
                .height('auto')
                .borderRadius(20)
                .backgroundColor($r('sys.color.comp_background_list_card'))
                .padding(4)
                .divider({
                  strokeWidth: '1px',
                  color: $r('sys.color.comp_divider'),
                  startMargin: 12,
                  endMargin: 12,
                })
              }
              .alignItems(HorizontalAlign.Start)

              Column() {
                Row() {
                  Text('自定义')
                    .fontSize(14)
                    .fontColor($r('sys.color.font_secondary'))
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 16, bottom: 8 })

                List() {
                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Text('页面跳转')
                          .fontSize(16)
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .textAlign(TextAlign.Start)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Row() {
                        SymbolGlyph($r('sys.symbol.chevron_right'))
                          .fontSize(24)
                          .fontColor([$r('sys.color.font_fourth')])
                          .margin({ left: 4 })
                      }
                      .justifyContent(FlexAlign.End)
                      .margin({ left: 16 })
                    }
                    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                    .constraintSize({ minHeight: 48 })
                    .borderRadius(16)
                  }

                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Text('开关标题')
                          .fontSize(16)
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .textAlign(TextAlign.Start)
                        Text('副标题')
                          .fontSize(12)
                          .fontColor($r('sys.color.font_secondary'))
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Row() {
                        Toggle({ type: ToggleType.Switch, isOn: $$this.customSwitchOn })
                          .selectedColor($r('sys.color.ohos_id_color_warning'))
                      }
                      .justifyContent(FlexAlign.End)
                      .margin({ left: 16 })
                    }
                    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                    .constraintSize({ minHeight: 48 })
                    .borderRadius(16)
                  }

                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Text('下拉选择')
                          .fontSize(16)
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .textAlign(TextAlign.Start)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Row() {
                        Text(this.customSelectOptions[this.customSelectIndex])
                          .fontSize(14)
                          .fontColor($r('sys.color.font_secondary'))
                          .maxFontScale(1.3)
                          .constraintSize({ maxWidth: '50%' })
                        SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
                          .fontSize(12)
                          .fontColor([$r('sys.color.font_fourth')])
                          .margin({ left: 4 })
                      }
                      .justifyContent(FlexAlign.End)
                      .margin({ left: 16 })
                      .onClick(() => {
                        this.showCustomSelectPopup = !this.showCustomSelectPopup;
                      })
                      .bindPopup(this.showCustomSelectPopup, {
                        builder: this.customSelectPopupBuilder(),
                        enableArrow: false,
                        autoCancel: true,
                        placement: Placement.BottomRight,
                        width: 224,
                        offset: { x: 12, y: 8 },
                        onWillDismiss: () => {
                          this.showCustomSelectPopup = false;
                        }
                      })
                    }
                    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                    .constraintSize({ minHeight: 48 })
                    .borderRadius(16)
                  }
                }
                .width('100%')
                .height('auto')
                .borderRadius(20)
                .backgroundColor($r('sys.color.comp_background_list_card'))
                .padding(4)
                .divider({
                  strokeWidth: '1px',
                  color: $r('sys.color.comp_divider'),
                  startMargin: 12,
                  endMargin: 12,
                })
              }
              .alignItems(HorizontalAlign.Start)

              Column() {
                Button('退出登录')
                  .width('100%')
                  .backgroundColor($r('sys.color.comp_background_tertiary'))
                  .fontColor($r('sys.color.font_primary'))
                  .fontWeight(FontWeight.Medium)
                  .fontSize(16)
                  .padding({ top: 12, bottom: 12 })
              }
              .margin({ top: 16 })
            }
            .padding({ top: 12 })
          }
          .layoutWeight(1)
          .align(Alignment.Top)
          .edgeEffect(EdgeEffect.Spring)
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16 })
        .backgroundColor($r('sys.color.background_secondary'))
  }


  // 「定位权限」半模态面板容器：展示当前定位权限获取状态
  @Builder
  buildLocationSheetContent(): void {
    Column() {
      // 顶部占位：把 Navigation（含标题栏）整体下移到拖拽条下方
      Column().width('100%').height(6)
      Navigation() {
        this.locationRootContent()
      }
      .title('定位权限', { backgroundColor: $r('sys.color.background_secondary') })
      .titleMode(NavigationTitleMode.Mini)
      .hideBackButton(true)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
      .mode(NavigationMode.Stack)
      .menus([
        {
          value: '',
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.xmark'))
            .fontSize(22)
            .fontColor([$r('sys.color.font_primary')]),
          action: () => {
            this.isShowLocationSheet = false;
          }
        }
      ])
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  // 「定位模式」半模态面板容器：参考「定位权限」做法，用 Navigation 承载卡片列表
  @Builder
  buildRecordModeSheetContent(): void {
    Column() {
      // 顶部占位：把 Navigation（含标题栏）整体下移到拖拽条下方
      Column().width('100%').height(6)
      Navigation() {
        this.recordModeRootContent()
      }
      .title('定位模式', { backgroundColor: $r('sys.color.background_secondary') })
      .titleMode(NavigationTitleMode.Mini)
      .hideBackButton(true)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
      .mode(NavigationMode.Stack)
      .menus([
        {
          value: '',
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.xmark'))
            .fontSize(22)
            .fontColor([$r('sys.color.font_primary')]),
          action: () => {
            this.isShowRecordModeSheet = false;
          }
        }
      ])
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  // 「定位模式」面板根内容：三档模式卡片（省电/平衡/耗电），点击整行切换，当前档右侧显示官方单选框选中态
  @Builder
  recordModeRootContent() {
    Column() {
      Scroll() {
        Column({ space: 12 }) {
          List() {
            ForEach(this.recordModeDescs, (desc: string, index: number) => {
              ListItem() {
                Row() {
                  Column({ space: 6 }) {
                    Text(this.recordModeNames[index])
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                    Text(desc)
                      .fontSize(12)
                      .fontColor($r('sys.color.font_secondary'))
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  // 官方单选框（Radio）：由 currentMode 状态驱动选中态，无需 RadioGroup 即可互斥
                  Radio({ value: `${index}`, group: 'recordMode' })
                    .checked(this.currentMode === index)
                    .radioStyle({
                      checkedBackgroundColor: $r('sys.color.ohos_id_color_activated'),
                      uncheckedBorderColor: $r('sys.color.comp_background_emphasize'),
                      indicatorColor: $r('sys.color.comp_background_primary')
                    })
                    .width(24)
                    .height(24)
                    .onChange((isChecked: boolean) => {
                      if (isChecked) {
                        this.switchMode(index);
                      }
                    })
                    .margin({ left: 16 })
                }
                .padding({ top: 16, bottom: 16, left: 12, right: 12 })
                .constraintSize({ minHeight: 64 })
                .borderRadius(16)
                .onClick(() => {
                  this.switchMode(index);
                })
              }
            }, (_desc: string, index: number) => `rm_${index}`)
          }
          .width('100%')
          .height('auto')
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .padding(4)
          .divider({
            strokeWidth: '1px',
            color: $r('sys.color.comp_divider'),
            startMargin: 12,
            endMargin: 12
          })

          // 说明标题：模式选择概述 + 策略卡片入口
          Column() {
            Text('防漂移与性能策略')
              .fontSize(14)
              .fontColor($r('sys.color.font_primary'))
              .fontWeight(FontWeight.Medium)
              .width('100%')

            Text('三档模式仅调整定位频率与精度门槛，切换后立即生效，以下策略在所有模式下自动生效：')
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .margin({ top: 4 })
              .width('100%')
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })

          // 策略卡片：每项以「要点标签 + 说明」两行呈现，左侧点缀色圆点呼应主题色，项间细分割线
          Column() {
            ForEach(this.recordStrategyItems,
              (item: RecordStrategyItem, index: number) => {
                Row() {
                  SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
                    .fontSize(14)
                    .fontColor([$r('sys.color.ohos_id_color_activated')])
                    .margin({ right: 10, top: 3 })
                  Column() {
                    Text(item.title)
                      .fontSize(13)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                    Text(item.desc)
                      .fontSize(12)
                      .fontColor($r('sys.color.font_secondary'))
                      .margin({ top: 2 })
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .padding({ top: 10, bottom: 10 })
                .borderWidth({ bottom: index < this.recordStrategyItems.length - 1 ? 1 : 0 })
                .borderColor($r('sys.color.comp_divider'))
              },
              (_item: RecordStrategyItem, index: number) => `str_${index}`)
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 4, bottom: 8 })
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(16)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  // 「地图工具」半模态面板内容：标题栏与关闭按钮由半模态系统自带
  @Builder
  buildMapToolSheetContent(): void {
    Column() {

      // === 容器C（独立）：显示2 —— 左侧标题 + 右侧 SegmentButton ===
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
          // 总览视图仅支持海量点：禁用「折线」按钮并灰显，避免跨天连线杂乱
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

      // 「我的位置」开关：自定义开启/关闭“我的位置”图层（蓝色定位点）。
      // 关闭时一并隐藏右下角官方“我的位置”按钮，避免留下无响应的死按钮。
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
              if (this.mapController) {
                this.mapController.setMyLocationEnabled(isOn);
                this.mapController.setMyLocationControlsEnabled(isOn);
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

      // TODO: 在此追加更多独立容器（每个容器内部均为：左标题 + 右控件）
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
  }

  // 「定位权限」面板根内容：三项权限状态（大致/精确/后台）+ 前往系统设置入口
  @Builder
  locationRootContent() {
    Column() {
      Scroll() {
        Column({ space: 12 }) {
          // 权限状态卡片
          List() {
            ListItem() {
              Row() {
                Column({ space: 6 }) {
                  Text('大致位置')
                    .fontSize(16)
                    .fontColor($r('sys.color.font_primary'))
                    .fontWeight(FontWeight.Medium)
                    .textAlign(TextAlign.Start)
                  Text('允许 App 获取您所在的城市 / 街区级别大致位置')
                    .fontSize(12)
                    .fontColor($r('sys.color.font_secondary'))
                    .textAlign(TextAlign.Start)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  Text(this.hasApproximatelyLocation ? '已授权' : '未授权')
                    .fontSize(14)
                    .fontColor(this.hasApproximatelyLocation ? $r('sys.color.ohos_id_color_activated') : $r('sys.color.ohos_id_color_warning'))
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(24)
                    .fontColor([$r('sys.color.font_fourth')])
                    .margin({ left: 4 })
                }
                .justifyContent(FlexAlign.End)
                .margin({ left: 16 })
              }
              .padding({ top: 16, bottom: 16, left: 12, right: 12 })
              .constraintSize({ minHeight: 64 })
              .borderRadius(16)
              .onClick(() => {
                if (!this.hasApproximatelyLocation) {
                  this.requestPermissions();
                } else {
                  this.openPermissionSettings();
                }
              })
            }

            ListItem() {
              Row() {
                Column({ space: 6 }) {
                  Text('精确位置')
                    .fontSize(16)
                    .fontColor($r('sys.color.font_primary'))
                    .fontWeight(FontWeight.Medium)
                    .textAlign(TextAlign.Start)
                  Text('允许 App 获取精确 GPS 位置，用于地图标注与轨迹记录')
                    .fontSize(12)
                    .fontColor($r('sys.color.font_secondary'))
                    .textAlign(TextAlign.Start)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  Text(this.hasLocation ? '已授权' : '未授权')
                    .fontSize(14)
                    .fontColor(this.hasLocation ? $r('sys.color.ohos_id_color_activated') : $r('sys.color.ohos_id_color_warning'))
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(24)
                    .fontColor([$r('sys.color.font_fourth')])
                    .margin({ left: 4 })
                }
                .justifyContent(FlexAlign.End)
                .margin({ left: 16 })
              }
              .padding({ top: 16, bottom: 16, left: 12, right: 12 })
              .constraintSize({ minHeight: 64 })
              .borderRadius(16)
              .onClick(() => {
                if (!this.hasLocation) {
                  this.requestPermissions();
                } else {
                  this.openPermissionSettings();
                }
              })
            }

            ListItem() {
              Row() {
                Column({ space: 6 }) {
                  Text('后台定位')
                    .fontSize(16)
                    .fontColor($r('sys.color.font_primary'))
                    .fontWeight(FontWeight.Medium)
                    .textAlign(TextAlign.Start)
                  Text('允许 App 在后台持续获取位置，用于后台轨迹记录')
                    .fontSize(12)
                    .fontColor($r('sys.color.font_secondary'))
                    .textAlign(TextAlign.Start)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  Text(this.hasBackgroundLocation ? '已授权' : '未授权')
                    .fontSize(14)
                    .fontColor(this.hasBackgroundLocation ? $r('sys.color.ohos_id_color_activated') : $r('sys.color.ohos_id_color_warning'))
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(24)
                    .fontColor([$r('sys.color.font_fourth')])
                    .margin({ left: 4 })
                }
                .justifyContent(FlexAlign.End)
                .margin({ left: 16 })
              }
              .padding({ top: 16, bottom: 16, left: 12, right: 12 })
              .constraintSize({ minHeight: 64 })
              .borderRadius(16)
              .onClick(() => {
                if (!this.hasBackgroundLocation) {
                  this.requestBackgroundLocationPermission();
                } else {
                  this.openPermissionSettings();
                }
              })
            }
          }
          .width('100%')
          .height('auto')
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .padding(4)
          .divider({
            strokeWidth: '1px',
            color: $r('sys.color.comp_divider'),
            startMargin: 12,
            endMargin: 12
          })

          // 前往系统设置入口
          List() {
            ListItem() {
              Row() {
                Column({ space: 6 }) {
                  Text('前往系统设置')
                    .fontSize(16)
                    .fontColor($r('sys.color.font_primary'))
                    .fontWeight(FontWeight.Medium)
                    .textAlign(TextAlign.Start)
                  Text('若以上权限未授权或被拒绝，可在此前往系统设置手动开启')
                    .fontSize(12)
                    .fontColor($r('sys.color.font_secondary'))
                    .textAlign(TextAlign.Start)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(24)
                    .fontColor([$r('sys.color.font_fourth')])
                    .margin({ left: 4 })
                }
                .justifyContent(FlexAlign.End)
                .margin({ left: 16 })
              }
              .padding({ top: 16, bottom: 16, left: 12, right: 12 })
              .constraintSize({ minHeight: 64 })
              .borderRadius(16)
              .onClick(() => {
                this.openPermissionSettings();
              })
            }
          }
          .width('100%')
          .height('auto')
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .padding(4)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  // 「设置」半模态面板容器：内嵌 Navigation(settingStack) 与页面路由 pageMap
  @Builder
  buildSettingSheetContent(): void {
    Column() {
      // 顶部占位：把 Navigation（含标题栏）整体下移到拖拽条下方，避免标题栏上移/与拖拽条重叠
      Column().width('100%').height(6)
      Navigation(this.settingStack) {
        this.settingRootContent()
      }
      .title('设置', { backgroundColor: $r('sys.color.background_secondary') })
      .titleMode(NavigationTitleMode.Mini)
      .hideBackButton(true)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
      .mode(NavigationMode.Stack)
      .navDestination(this.pageMap)
      .menus([
        {
          value: '',
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.xmark'))
            .fontSize(22)
            .fontColor([$r('sys.color.font_primary')]),
          action: () => {
            this.isShowSettingSheet = false;
          }
        }
      ])
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  // NavDestination 路由表：当前仅 'privacy'(隐私设置) 一个二级页
  @Builder
  pageMap(name: string, _param: Record<string, Object>) {
    if (name === 'privacy') {
      NavDestination() {
        this.privacyRootContent()
      }
      .title('隐私设置', { backgroundColor: $r('sys.color.background_secondary') })
      .menus([
        {
          value: '',
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.xmark'))
            .fontSize(22)
            .fontColor([$r('sys.color.font_primary')]),
          action: () => {
            this.isShowSettingSheet = false;
          }
        }
      ])
      .onBackPressed(() => {
        this.settingStack.pop();
        return true;
      })
    }
  }

  // 「隐私设置」二级页内容：个性化推荐 / 通知 / 用户协议 / 隐私政策 / 第三方信息共享清单等
  @Builder
  privacyRootContent() {
    Column() {
      Scroll() {
        Column({ space: 12 }) {
              List() {
                ListItem() {
                  Row() {
                    Column({ space: 2 }) {
                      Text('个性化推荐')
                        .fontSize(16)
                        .fontColor($r('sys.color.font_primary'))
                        .fontWeight(FontWeight.Medium)
                        .textAlign(TextAlign.Start)
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    Row() {
                      Toggle({ type: ToggleType.Switch, isOn: true })
                        .selectedColor($r('sys.color.ohos_id_color_warning'))
                    }
                    .justifyContent(FlexAlign.End)
                    .margin({ left: 16 })
                  }
                  .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                  .constraintSize({ minHeight: 48 })
                  .borderRadius(16)
                }
              }
              .width('100%')
              .height('auto')
              .borderRadius(20)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .padding(4)

              List() {
                ListItem() {
                  Row() {
                    Column({ space: 2 }) {
                      Text('通知开关')
                        .fontSize(16)
                        .fontColor($r('sys.color.font_primary'))
                        .fontWeight(FontWeight.Medium)
                        .textAlign(TextAlign.Start)
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    Row() {
                      Toggle({ type: ToggleType.Switch, isOn: true })
                        .selectedColor($r('sys.color.ohos_id_color_warning'))
                    }
                    .justifyContent(FlexAlign.End)
                    .margin({ left: 16 })
                  }
                  .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                  .constraintSize({ minHeight: 48 })
                  .borderRadius(16)
                }
              }
              .width('100%')
              .height('auto')
              .borderRadius(20)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .padding(4)

              List() {
                ListItem() {
                  Row() {
                    Column({ space: 2 }) {
                      Text('用户协议')
                        .fontSize(16)
                        .fontColor($r('sys.color.font_primary'))
                        .fontWeight(FontWeight.Medium)
                        .textAlign(TextAlign.Start)
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    Row() {
                      SymbolGlyph($r('sys.symbol.chevron_right'))
                        .fontSize(24)
                        .fontColor([$r('sys.color.font_fourth')])
                        .margin({ left: 4 })
                    }
                    .justifyContent(FlexAlign.End)
                    .margin({ left: 16 })
                  }
                  .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                  .constraintSize({ minHeight: 48 })
                  .borderRadius(16)
                }

                ListItem() {
                  Row() {
                    Column({ space: 2 }) {
                      Text('隐私政策')
                        .fontSize(16)
                        .fontColor($r('sys.color.font_primary'))
                        .fontWeight(FontWeight.Medium)
                        .textAlign(TextAlign.Start)
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    Row() {
                      SymbolGlyph($r('sys.symbol.chevron_right'))
                        .fontSize(24)
                        .fontColor([$r('sys.color.font_fourth')])
                        .margin({ left: 4 })
                    }
                    .justifyContent(FlexAlign.End)
                    .margin({ left: 16 })
                  }
                  .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                  .constraintSize({ minHeight: 48 })
                  .borderRadius(16)
                }
              }
              .width('100%')
              .height('auto')
              .borderRadius(20)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .padding(4)
              .divider({
                strokeWidth: '1px',
                color: $r('sys.color.comp_divider'),
                startMargin: 12,
                endMargin: 12,
              })

              List() {
                ListItem() {
                  Row() {
                    Column({ space: 2 }) {
                      Text('第三方信息共享清单')
                        .fontSize(16)
                        .fontColor($r('sys.color.font_primary'))
                        .fontWeight(FontWeight.Medium)
                        .textAlign(TextAlign.Start)
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    Row() {
                      SymbolGlyph($r('sys.symbol.chevron_right'))
                        .fontSize(24)
                        .fontColor([$r('sys.color.font_fourth')])
                        .margin({ left: 4 })
                    }
                    .justifyContent(FlexAlign.End)
                    .margin({ left: 16 })
                  }
                  .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                  .constraintSize({ minHeight: 48 })
                  .borderRadius(16)
                }

                ListItem() {
                  Row() {
                    Column({ space: 2 }) {
                      Text('个人信息收集清单')
                        .fontSize(16)
                        .fontColor($r('sys.color.font_primary'))
                        .fontWeight(FontWeight.Medium)
                        .textAlign(TextAlign.Start)
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    Row() {
                      SymbolGlyph($r('sys.symbol.chevron_right'))
                        .fontSize(24)
                        .fontColor([$r('sys.color.font_fourth')])
                        .margin({ left: 4 })
                    }
                    .justifyContent(FlexAlign.End)
                    .margin({ left: 16 })
                  }
                  .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                  .constraintSize({ minHeight: 48 })
                  .borderRadius(16)
                }
              }
              .width('100%')
              .height('auto')
              .borderRadius(20)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .padding(4)
              .divider({
                strokeWidth: '1px',
                color: $r('sys.color.comp_divider'),
                startMargin: 12,
                endMargin: 12,
              })
            }
            .padding({ top: 12 })
          }
          .layoutWeight(1)
          .align(Alignment.Top)
          .edgeEffect(EdgeEffect.Spring)
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16 })
        .backgroundColor($r('sys.color.background_secondary'))
  }

  // 「夜间模式」弹窗内容：列出 跟随系统 / 普通模式 / 夜间模式 供选择，当前项打勾
  @Builder
  displayModePopupBuilder() {
    Column() {
      List() {
        ForEach(this.displayModeOptions, (option: string, index: number) => {
          ListItem() {
            Row() {
              Text(option)
                .fontSize(16)
                .fontColor($r('sys.color.font_primary'))
                .fontWeight(FontWeight.Medium)
                .maxFontScale(1.3)
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(24)
                .fontColor([$r('sys.color.font_primary')])
                .margin({ left: 4 })
                .visibility(this.nightModeIndex === index ? Visibility.Visible : Visibility.Hidden)
            }
            .width('100%')
            .borderRadius(16)
            .padding(12)
            .onClick(() => {
              this.nightModeIndex = index;
              this.showDisplayModePopup = false;
              this.applyNightMode(index);
            })
          }
        }, (_option: string, index: number) => `dm_${index}`)
      }
      .width('100%')
      .height('100%')
      .padding(4)
      .scrollBar(BarState.Off)
      .divider({
        strokeWidth: '1px',
        color: $r('sys.color.comp_divider'),
        startMargin: 8,
        endMargin: 8,
      })
    }
    .width('100%')
    .borderRadius($r('sys.float.corner_radius_level10'))
    .backgroundColor($r('sys.color.comp_background_primary'))
  }

  // 「下拉选择」弹窗内容（自定义分组示例项）
  @Builder
  customSelectPopupBuilder() {
    Column() {
      List() {
        ForEach(this.customSelectOptions, (option: string, index: number) => {
          ListItem() {
            Row() {
              Text(option)
                .fontSize(16)
                .fontColor($r('sys.color.font_primary'))
                .fontWeight(FontWeight.Medium)
                .maxFontScale(1.3)
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(24)
                .fontColor([$r('sys.color.font_primary')])
                .margin({ left: 4 })
                .visibility(this.customSelectIndex === index ? Visibility.Visible : Visibility.Hidden)
            }
            .width('100%')
            .borderRadius(16)
            .padding(12)
            .onClick(() => {
              this.customSelectIndex = index;
              this.showCustomSelectPopup = false;
            })
          }
        }, (_option: string, index: number) => `cs_${index}`)
      }
      .width('100%')
      .height('100%')
      .padding(4)
      .scrollBar(BarState.Off)
      .divider({
        strokeWidth: '1px',
        color: $r('sys.color.comp_divider'),
        startMargin: 8,
        endMargin: 8,
      })
    }
    .width('100%')
    .borderRadius($r('sys.float.corner_radius_level10'))
    .backgroundColor($r('sys.color.comp_background_primary'))
  }
}
