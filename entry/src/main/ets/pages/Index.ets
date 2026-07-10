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
import { relationalStore } from '@kit.ArkData';
import { HdsNavigation, HdsTabs, HdsTabsController, HdsAnimationMode, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier, SegmentButton, SegmentButtonOptions, ItemRestriction, SegmentButtonIconTextItem, SegmentButtonTextItem } from '@kit.ArkUI';
import { Mine } from './Mine';




// 日志 TAG：组件名为 Index，早期原型曾叫 MapPage，此处统一为 Index 以消除歧义
const TAG: string = 'Index';

// ===== 本地数据库（ArkData RdbStore）配置 =====
const DB_NAME: string = 'footprint.db';    // 数据库文件名，存于应用沙箱
const TABLE_NAME: string = 'track_points'; // 轨迹点表名
const CREATE_TABLE_SQL: string =
  // 建表语句：id 自增主键 + 经纬度；每次定位回调都会向该表插入一行
  `CREATE TABLE IF NOT EXISTS ${TABLE_NAME} (id INTEGER PRIMARY KEY AUTOINCREMENT, latitude REAL, longitude REAL)`;

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
  private trackPoints: mapCommon.LatLng[] = [];
  private footprintPoints: mapCommon.LatLng[] = [];
  private lastFootprintPoint: mapCommon.LatLng | null = null;
  private locationCallback?: (location: geoLocationManager.Location) => void;
  private redDotIcon: image.PixelMap | null = null;
  private rdbStore: relationalStore.RdbStore | null = null;
  @State displayMode: number = 0; // 轨迹展示方式：0=折线，1=海量点（非夜间模式）
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
    selectedBackgroundColor: '#007DFF',
    fontColor: '#999999',
    selectedFontColor: Color.White,
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
    selectedBackgroundColor: '#007DFF',
    fontColor: '#999999',
    selectedFontColor: Color.White,
    fontSize: 14,
    selectedFontSize: 14,
    fontWeight: FontWeight.Regular,
    selectedFontWeight: FontWeight.Medium,
    buttonPadding: { top: 10, right: 4, bottom: 10, left: 4 }
  });
  @State display2SelectedIndexes: number[] = [0];
  private static readonly FOOTPRINT_DISTANCE: number = 80;
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
  @State isShowMapToolSheet: boolean = false; // 地图工具半模态面板显隐
  @State trackCount: number = 0;
  private settingStack: NavPathStack = new NavPathStack();
  private displayModeOptions: string[] = ['跟随系统', '普通模式', '夜间模式'];
  private customSelectOptions: string[] = ['选项1', '选项2', '选项3'];

  // ===== 生命周期 =====
  // 页面即将显示：初始化地图参数/回调、异步生成红点图标、按需初始化数据库、确定系统材质等级
  aboutToAppear(): void {
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

  // 页面销毁：反注册定位监听，避免后台持续定位与内存泄漏
  aboutToDisappear(): void {
    try {
      geoLocationManager.off('locationChange');
    } catch (err) {
      console.warn(TAG, 'Failed to unsubscribe locationChange');
    }
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
      await this.loadTrackPoints();
    } catch (err) {
      let error = err as BusinessError;
      console.error(`initDatabase failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 从数据库按 id 升序读取全部轨迹点，重建内存中的 trackPoints / footprintPoints，并刷新地图覆盖物
  private async loadTrackPoints(): Promise<void> {
    if (!this.rdbStore) {
      return;
    }
    try {
      let predicates = new relationalStore.RdbPredicates(TABLE_NAME);
      predicates.orderByAsc('id');
      let resultSet = await this.rdbStore.query(predicates, ['latitude', 'longitude']);
      while (resultSet.goToNextRow()) {
        let latLng: mapCommon.LatLng = {
          latitude: resultSet.getDouble(resultSet.getColumnIndex('latitude')),
          longitude: resultSet.getDouble(resultSet.getColumnIndex('longitude'))
        };
        this.trackPoints.push(latLng);
        if (this.shouldRecordFootprint(latLng)) {
          this.footprintPoints.push(latLng);
          this.lastFootprintPoint = latLng;
        }
      }
      resultSet.close();
      if (this.trackPoints.length > 0) {
        if (this.displayMode === 0) {
          this.updatePolyline();
        } else {
          this.updateMassPointOverlay();
        }
      }
      console.info(TAG, `Loaded ${this.trackPoints.length} track points from database`);
    } catch (err) {
      let error = err as BusinessError;
      console.error(`loadTrackPoints failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 将单个轨迹点（经纬度）插入数据库，实现轨迹持久化
  private async saveTrackPoint(latLng: mapCommon.LatLng): Promise<void> {
    if (!this.rdbStore) {
      return;
    }
    try {
      let values: relationalStore.ValuesBucket = {
        latitude: latLng.latitude,
        longitude: latLng.longitude
      };
      await this.rdbStore.insert(TABLE_NAME, values);
    } catch (err) {
      let error = err as BusinessError;
      console.error(`saveTrackPoint failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 初始化地图初始参数：默认中心点(北京)、缩放级别、各类控件开关。
  // dayNightMode 初始设为 AUTO，与 nightModeIndex 默认值 0(跟随系统) 保持一致；
  // 用户可在「设置-夜间模式」改选普通/夜间，由 applyNightMode 实时生效。
  private initMapOptions(): void {
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
      zoomControlsEnabled: true,
      tiltGesturesEnabled: true,
      rotateGesturesEnabled: true,
      sphereEnabled: true,
      dayNightMode: mapCommon.DayNightMode.AUTO // 与 nightModeIndex=0(跟随系统) 保持一致，避免首屏强制夜间
    };
  }

  // 构造地图初始化回调：地图就绪后保存 controller、开启 3D 建筑、初始化数据库、申请定位权限
  private initMapCallback(): void {
    this.callback = async (err, mapController) => {
      if (!err) {
        this.mapController = mapController;

        // 底部留白：将缩放控件、"我的位置"按钮整体顶到悬浮 tab 栏上方，避免被遮挡
        this.mapController.setPadding({
          left: 0,
          top: 0,
          right: 0,
          bottom: 90
        });

        console.info(TAG, 'Map initialized successfully');

        // 点击地图空白区域切换沉浸模式：第一次进入纯净地图，再点一次恢复叠加 UI
        this.mapEventManager = this.mapController.getEventManager();
        this.mapEventManager.on('mapClick', () => {
          this.immersive = !this.immersive;
          // 沉浸模式隐藏 tab 栏时控件贴底；普通模式上移到 tab 栏上方
          this.mapController?.setPadding({
            left: 0,
            top: 0,
            right: 0,
            bottom: this.immersive ? 0 : 90
          });
          // 沉浸模式：隐藏底部页签栏（含迷你栏），只保留纯净地图；再次点击恢复
          if (this.immersive) {
            this.tabsController.applyHideAnimation(HdsAnimationMode.CLICK_ANIMATION);
          } else {
            this.tabsController.applyShowAnimation(HdsAnimationMode.CLICK_ANIMATION);
          }
        });
        this.enable3DBuilding();
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
        fontColor: '#007DFF',
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

      let locationRequest: geoLocationManager.LocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.ACCURACY,
        scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
        timeInterval: 1,
        distanceInterval: 0,
        maxAccuracy: 0
      };
      this.locationCallback = (location: geoLocationManager.Location) => {
        map.convertCoordinate(
          mapCommon.CoordinateType.WGS84,
          mapCommon.CoordinateType.GCJ02,
          { latitude: location.latitude, longitude: location.longitude }
        ).then((gcj02: mapCommon.LatLng) => {
          this.recordTrackPoint(gcj02);
        });
      };
      geoLocationManager.on('locationChange', locationRequest, this.locationCallback);
      console.info(TAG, 'Location change listener registered');
    } catch (err) {
      let error = err as BusinessError;
      console.error(`Failed to enable my location, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 定位回调核心：记录轨迹点(内存+落库)，按距离阈值补记「足迹」，并刷新当前展示模式的覆盖物
  private recordTrackPoint(latLng: mapCommon.LatLng): void {
    this.trackPoints.push(latLng);
    this.trackCount = this.trackPoints.length;
    this.saveTrackPoint(latLng);

    if (this.shouldRecordFootprint(latLng)) {
      this.footprintPoints.push(latLng);
      this.lastFootprintPoint = latLng;
    }

    if (this.displayMode === 0) {
      this.updatePolyline();
    } else {
      this.updateMassPointOverlay();
    }
  }

  // 判断是否达到「足迹」记录阈值：与上一个足迹点距离 >= FOOTPRINT_DISTANCE(80m) 才记一次，避免过密
  private shouldRecordFootprint(current: mapCommon.LatLng): boolean {
    if (!this.lastFootprintPoint) {
      return true;
    }
    let distance: number = this.calculateDistance(this.lastFootprintPoint, current);
    return distance >= Index.FOOTPRINT_DISTANCE;
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

  // 折线模式：首次创建 MapPolyline，之后仅 setPoints 增量更新（红色、宽度 10）
  private updatePolyline(): void {
    if (!this.trackPolyline) {
      let polylineOption: mapCommon.MapPolylineOptions = {
        points: this.trackPoints,
        width: 10,
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
  }

  // 切换展示模式(0 折线 / 1 海量点)：移除另一种模式的覆盖物，并重建当前模式
  private switchDisplayMode(mode: number): void {
    if (this.displayMode === mode) {
      return;
    }
    this.displayMode = mode;
    this.selectedIndexes = [mode];

    if (mode === 0) {
      if (this.massPointOverlay) {
        this.massPointOverlay.remove();
        this.massPointOverlay = null;
      }
      if (this.trackPoints.length > 0) {
        this.updatePolyline();
      }
    } else {
      if (this.trackPolyline) {
        this.trackPolyline.remove();
        this.trackPolyline = null;
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
    this.trackPoints = [];
    this.trackCount = 0;
    this.footprintPoints = [];
    this.lastFootprintPoint = null;
    if (this.rdbStore) {
      try {
        let predicates = new relationalStore.RdbPredicates(TABLE_NAME);
        await this.rdbStore.delete(predicates);
      } catch (err) {
        let error = err as BusinessError;
        console.error(`clearTrack DB failed, code: ${error.code}, message: ${error.message}`);
      }
    }
    console.info(TAG, 'Track cleared');
  }

  // 删除前二次确认弹窗，确认后调用 clearTrack
  private confirmClearTrack(): void {
    AlertDialog.show({
      title: '删除轨迹',
      message: `确定要删除全部 ${this.trackPoints.length} 条轨迹记录吗？此操作不可恢复。`,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E64566',
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

  // ===== UI 构建 =====
  // 结构：HdsNavigation → HdsTabs(足迹 / 我的)
  //  - 足迹 Tab：全屏地图 + 左上角权限状态条；轨迹类型切换改由「地图工具」面板内的官方 SegmentButton 承载
  //  - 我的 Tab：点击时改为弹出半模态面板(buildSheetContent)，不切换整页
  build() {
    HdsNavigation() {
      HdsTabs({ controller: this.tabsController }) {
        TabContent() {
          Stack() {
            MapComponent({ mapOptions: this.mapOptions, mapCallback: this.callback })
              .width('100%')
              .height('100%');


            // 自定义悬浮按钮：显示在系统缩放控件上方，点击打开地图工具半模态面板（功能内容待补充）
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.paintpalette_fill'))
                .fontSize(22)
                .fontColor([Color.White])
            }
            .width(44)
            .height(44)
            .backgroundColor('#007DFF')
            .shadow({ radius: 6, color: '#33000000', offsetX: 0, offsetY: 2 })
            .position({ x: '100%', y: '100%' })
            .translate({ x: -60, y: -240 })
            .onClick(() => {
              this.isShowMapToolSheet = true;
            })


          }
          .width('100%')
          .height('100%')
          // 地图工具面板：由地图 Stack 承载（仅「足迹」Tab），与「我的」半模态分离宿主组件，避免同一根组件挂两个 bindSheet 冲突闪退
          .bindSheet($$this.isShowMapToolSheet, this.buildMapToolSheetContent(), {
            detents: [SheetSize.MEDIUM, SheetSize.LARGE],
            title: { title: '地图工具' },
            dragBar: true,
            showClose: true,
            onDisappear: () => {
              this.isShowMapToolSheet = false;
            }
          })
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.figure_running'))
            .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
            .fontColor([
              $r('sys.color.ohos_id_color_bottom_tab_icon_off'),
              $r('sys.color.ohos_id_color_bottom_tab_icon_auxcolor_off02')
            ]),
          selected: new SymbolGlyphModifier($r('sys.symbol.figure_running'))
            .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
            .fontColor([
              $r('sys.color.ohos_id_color_activated'),
              $r('sys.color.ohos_id_color_primary_contrary')
            ])
        }, '足迹'))

        // 「我的」Tab：本体留空，仅作为 tab 按钮载体；点击交互由下方 onContentWillChange 拦截并弹出半模态面板
        TabContent() {
          Column()
            .width('100%')
            .height('100%')
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1'))
            .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
            .fontColor([
              $r('sys.color.ohos_id_color_bottom_tab_icon_off'),
              $r('sys.color.ohos_id_color_bottom_tab_icon_auxcolor_off02')
            ]),
          selected: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1'))
            .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
            .fontColor([
              $r('sys.color.ohos_id_color_activated'),
              $r('sys.color.ohos_id_color_primary_contrary')
            ])
        }, '我的'))
      }
      .barOverlap(true)
      .vertical(false)
      .barPosition(BarPosition.End)
      .scrollable(false)
      // 点「我的」(index=1) 时拦截整页切换，改为弹出半模态面板，返回 false 取消切换
      .onContentWillChange((_currentIndex: number, comingIndex: number) => {
        if (comingIndex === 1) {
          this.isShowSheet = true;
          return false;
        }
        return true;
      })
      .barFloatingStyle({
        barBottomMargin: 28,
        gradientMask: {
          maskColor: Color.Transparent
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: this.customMaterialLevel
        }
      })
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
          locationAbnormal: !(this.hasApproximatelyLocation && this.hasLocation && this.hasBackgroundLocation)
        })
      }
      .title('我的')
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
                          .selectedColor('#e64566')
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
                          .selectedColor('#e64566')
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
                    .fontColor(this.hasApproximatelyLocation ? '#4CAF50' : '#F44336')
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
                    .fontColor(this.hasLocation ? '#4CAF50' : '#F44336')
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
                    .fontColor(this.hasBackgroundLocation ? '#4CAF50' : '#F44336')
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
                        .selectedColor('#e64566')
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
                        .selectedColor('#e64566')
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
