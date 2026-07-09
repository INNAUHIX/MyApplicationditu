import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, bundleManager, common, Permissions, Want } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { image } from '@kit.ImageKit';
import { relationalStore } from '@kit.ArkData';
import { HdsNavigation, HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier, promptAction } from '@kit.ArkUI';
import { Mine } from './Mine';




const TAG: string = 'MapPage';
const DB_NAME: string = 'footprint.db';
const TABLE_NAME: string = 'track_points';
const CREATE_TABLE_SQL: string =
  `CREATE TABLE IF NOT EXISTS ${TABLE_NAME} (id INTEGER PRIMARY KEY AUTOINCREMENT, latitude REAL, longitude REAL)`;

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
  @State displayMode: number = 0;
  private static readonly FOOTPRINT_DISTANCE: number = 80;
  private tabsController: HdsTabsController = new HdsTabsController();
  @State customMaterialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;
  @State hasApproximatelyLocation: boolean = false;
  @State hasLocation: boolean = false;
  @State hasBackgroundLocation: boolean = false;
  @State isShowSheet: boolean = false;
  @State displayModeIndex: number = 0;
  @State showDisplayModePopup: boolean = false;
  @State pushSwitchOn: boolean = true;
  @State customSwitchOn: boolean = true;
  @State customSelectIndex: number = 0;
  @State showCustomSelectPopup: boolean = false;
  private sheetNavPathStack: NavPathStack = new NavPathStack();
  private displayModeOptions: string[] = ['跟随系统', '普通模式', '夜间模式'];
  private customSelectOptions: string[] = ['选项1', '选项2', '选项3'];

  aboutToAppear(): void {
    this.initMapOptions();
    this.initMapCallback();
    this.createRedDotIcon();
    let materialTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    if (materialTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0) {
      this.customMaterialLevel = hdsMaterial.MaterialLevel.SMOOTH;
    }
  }

  onPageShow(): void {
    if (this.mapController) {
      this.mapController.show();
    }
    this.refreshPermissionState();
  }

  onPageHide(): void {
    if (this.mapController) {
      this.mapController.hide();
    }
  }

  aboutToDisappear(): void {
    try {
      geoLocationManager.off('locationChange');
    } catch (err) {
      console.warn(TAG, 'Failed to unsubscribe locationChange');
    }
  }

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
      dayNightMode: mapCommon.DayNightMode.NIGHT
    };
  }

  private initMapCallback(): void {
    this.callback = async (err, mapController) => {
      if (!err) {
        this.mapController = mapController;

        console.info(TAG, 'Map initialized successfully');
        this.enable3DBuilding();
        await this.initDatabase();
        this.checkAndRequestPermission();
      } else {
        console.error(`Failed to initialize the map, code: ${err.code}, message: ${err.message}`);
      }
    };
  }

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

  private async refreshPermissionState(): Promise<void> {
    let hasForeground = await this.checkAccessToken('ohos.permission.APPROXIMATELY_LOCATION');
    this.hasApproximatelyLocation = hasForeground === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;

    let hasLocation = await this.checkAccessToken('ohos.permission.LOCATION');
    this.hasLocation = hasLocation === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;

    let hasBackground = await this.checkAccessToken('ohos.permission.LOCATION_IN_BACKGROUND');
    this.hasBackgroundLocation = hasBackground === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;

  }

  private async checkAndRequestPermission(): Promise<void> {
    let hasForeground = await this.checkAccessToken('ohos.permission.APPROXIMATELY_LOCATION');
    this.hasApproximatelyLocation = hasForeground === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    
    let hasLocation = await this.checkAccessToken('ohos.permission.LOCATION');
    this.hasLocation = hasLocation === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    
    let hasBackground = await this.checkAccessToken('ohos.permission.LOCATION_IN_BACKGROUND');
    this.hasBackgroundLocation = hasBackground === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    
    if (!this.hasApproximatelyLocation || !this.hasLocation) {
      this.requestPermissions();
      return;
    }
    if (!this.hasBackgroundLocation) {
      this.requestBackgroundLocationPermission();
    }
    this.enableMyLocation();
  }


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
          console.warn(TAG, 'Location permission denied, please grant in Settings');
        }
      })
      .catch((err: BusinessError) => {
        console.error(`Failed to request permissions from user. Code: ${err.code}, message: ${err.message}`);
      });
  }

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

  private recordTrackPoint(latLng: mapCommon.LatLng): void {
    this.trackPoints.push(latLng);
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

  private shouldRecordFootprint(current: mapCommon.LatLng): boolean {
    if (!this.lastFootprintPoint) {
      return true;
    }
    let distance: number = this.calculateDistance(this.lastFootprintPoint, current);
    return distance >= Index.FOOTPRINT_DISTANCE;
  }

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

  private switchDisplayMode(mode: number): void {
    if (this.displayMode === mode) {
      return;
    }
    this.displayMode = mode;

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

  build() {
    HdsNavigation() {
      HdsTabs({ controller: this.tabsController }) {
        TabContent() {
          Stack() {
            MapComponent({ mapOptions: this.mapOptions, mapCallback: this.callback })
              .width('100%')
              .height('100%');

            Column() {
              Text('定位权限状态')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .margin({ bottom: 8 })

              Row({ space: 8 }) {
                Text(`大致位置: ${this.hasApproximatelyLocation ? '✓' : '✗'}`)
                  .fontSize(12)
                  .fontColor(this.hasApproximatelyLocation ? '#4CAF50' : '#F44336')
                  .backgroundColor('#80000000')
                  .padding(4)
                  .borderRadius(4)
                  .onClick(() => {
                    if (!this.hasApproximatelyLocation) {
                      this.requestPermissions();
                    }
                  })

                Text(`精确位置: ${this.hasLocation ? '✓' : '✗'}`)
                  .fontSize(12)
                  .fontColor(this.hasLocation ? '#4CAF50' : '#F44336')
                  .backgroundColor('#80000000')
                  .padding(4)
                  .borderRadius(4)
                  .onClick(() => {
                    if (!this.hasLocation) {
                      this.requestPermissions();
                    }
                  })

                Text(`后台定位: ${this.hasBackgroundLocation ? '✓' : '✗'}`)
                  .fontSize(12)
                  .fontColor(this.hasBackgroundLocation ? '#4CAF50' : '#F44336')
                  .backgroundColor('#80000000')
                  .padding(4)
                  .borderRadius(4)
                  .onClick(() => {
                    if (!this.hasBackgroundLocation) {
                      this.requestBackgroundLocationPermission();
                    }
                  })
              }
            }
            .position({ x: 10, y: 100 })
            .backgroundColor('#80000000')
            .padding(10)
            .borderRadius(8)

            Row({ space: 0 }) {
              Button('折线轨迹')
                .fontSize(14)
                .fontColor(this.displayMode === 0 ? Color.White : '#999999')
                .backgroundColor(this.displayMode === 0 ? '#007DFF' : '#333333')
                .borderRadius({ topLeft: 20, bottomLeft: 20, topRight: 0, bottomRight: 0 })
                .width(110)
                .height(40)
                .onClick(() => this.switchDisplayMode(0))

              Button('海量点')
                .fontSize(14)
                .fontColor(this.displayMode === 1 ? Color.White : '#999999')
                .backgroundColor(this.displayMode === 1 ? '#007DFF' : '#333333')
                .borderRadius({ topLeft: 0, bottomLeft: 0, topRight: 20, bottomRight: 20 })
                .width(110)
                .height(40)
                .onClick(() => this.switchDisplayMode(1))
            }
            .position({ x: '25%', y: 50 })

            Button('清除轨迹')
              .backgroundColor('#333333')
              .width(120)
              .height(40)
              .borderRadius(20)
              .position({ x: '35%', y: '85%' })
              .onClick(() => {
                this.clearTrack();
              })
          }
          .width('100%')
          .height('100%')
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
      .onContentWillChange((_currentIndex: number, comingIndex: number) => {
        if (comingIndex === 1) {
          this.isShowSheet = true;
          return false;
        }
        return true;
      })
      .barFloatingStyle({
        barBottomMargin: 28,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: this.customMaterialLevel
        }
      })
      .bindSheet($$this.isShowSheet, this.buildSheetContent(), {
        height: SheetSize.LARGE,
        dragBar: true,

        onDisappear: () => {
          this.isShowSheet = false;
          this.sheetNavPathStack.clear();
        }
      })
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideBackButton(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }

  @Builder
  buildSheetContent(): void {
    Navigation(this.sheetNavPathStack) {
      Mine({ pathStack: this.sheetNavPathStack })
    }
    .navDestination(this.SheetNavDestination)
    .title('我的')
  }

  @Builder
  SheetNavDestination(name: string) {
    if (name === 'SettingPage') {
      NavDestination() {
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
                        Text(this.displayModeOptions[this.displayModeIndex])
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
                        Text('清理缓存')
                          .fontSize(16)
                          .fontColor($r('sys.color.font_primary'))
                          .fontWeight(FontWeight.Medium)
                          .textAlign(TextAlign.Start)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Row() {
                        Text('0.00M')
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
                      promptAction.showToast({ message: '功能不可用' });
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
                    .onClick(() => {
                      promptAction.showToast({ message: '功能不可用' });
                    })
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
                    .onClick(() => {
                      promptAction.showToast({ message: '功能不可用' });
                    })
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
                      this.sheetNavPathStack.pushPathByName('PrivacySettingPage', null);
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
                    .onClick(() => {
                      promptAction.showToast({ message: '功能不可用' });
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
                    .onClick(() => {
                      promptAction.showToast({ message: '功能不可用' });
                    })
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
                  .onClick(() => {
                    promptAction.showToast({ message: '功能不可用' });
                  })
              }
              .margin({ top: 16 })
            }
            .padding({ top: 12 })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16 })
        .backgroundColor($r('sys.color.background_secondary'))
      }
      .title('设置')
      .hideBackButton(false)
    } else if (name === 'PrivacySettingPage') {
      NavDestination() {
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
                  .onClick(() => {
                    promptAction.showToast({ message: '功能不可用' });
                  })
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
                  .onClick(() => {
                    promptAction.showToast({ message: '功能不可用' });
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
                  .onClick(() => {
                    promptAction.showToast({ message: '功能不可用' });
                  })
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
                  .onClick(() => {
                    promptAction.showToast({ message: '功能不可用' });
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
                endMargin: 12,
              })
            }
            .padding({ top: 12 })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16 })
        .backgroundColor($r('sys.color.background_secondary'))
      }
      .title('隐私设置')
      .hideBackButton(false)
    }
  }

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
                .visibility(this.displayModeIndex === index ? Visibility.Visible : Visibility.Hidden)
            }
            .width('100%')
            .borderRadius(16)
            .padding(12)
            .onClick(() => {
              this.displayModeIndex = index;
              this.showDisplayModePopup = false;
              promptAction.showToast({ message: '功能不可用' });
            })
          }
        }, (option: string, index: number) => `${index}`)
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
              promptAction.showToast({ message: '功能不可用' });
            })
          }
        }, (option: string, index: number) => `${index}`)
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
