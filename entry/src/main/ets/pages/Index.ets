/**
 * Index.ets —— 应用主页面编排层
 *
 * 仅负责：服务实例持有、生命周期管理、HdsTabs 编排（3 个 Tab 页）。
 * 具体 UI 与交互逻辑已拆至独立 Tab 组件：
 *   - FootprintTab  足迹地图（地图 + 覆盖物 + 定位 + 时间切换 + 工具面板）
 *   - StatsTab      足迹统计（统计指标 + 7天分布）
 *   - Mine          我的（定位模式 / 权限 / 设置 / 策略实验室）
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { HdsTabs, HdsTabsController, HdsAnimationMode, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier, window } from '@kit.ArkUI';

import { TrackDatabase } from '../data/TrackDatabase';
import { PermissionService } from '../service/PermissionService';
import { TrackLocationService } from '../service/TrackLocationService';
import { MapOverlayManager } from '../service/MapOverlayManager';
import { TimeViewModel } from '../viewmodel/TimeViewModel';
import { MapStyleViewModel } from '../viewmodel/MapStyleViewModel';
import { FootprintTab } from './FootprintTab';
import { StatsTab } from './StatsTab';
import { Mine } from './Mine';
import { StrategyLabPanel } from '../components/StrategyLabPanel';

import { RecordMode, TAG, PREF_NAME, PREF_KEY_RECORD_MODE, PREF_KEY_NIGHT_MODE, PREF_KEY_SHAKE_FLOOR } from '../model/TrackTypes';

@Entry
@Component
struct Index {
  // ===== 服务实例 =====
  private db: TrackDatabase = new TrackDatabase();
  private permSvc: PermissionService = new PermissionService();
  private locationSvc: TrackLocationService = new TrackLocationService();
  private mapManager: MapOverlayManager = new MapOverlayManager();
  private timeModel: TimeViewModel = new TimeViewModel();
  private mapStyleVM: MapStyleViewModel = new MapStyleViewModel();

  // ===== 布局状态 =====
  @State statusBarHeight: number = 0;
  @State navBarHeight: number = 0;
  private tabsController: HdsTabsController = new HdsTabsController();
  @State customMaterialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;

  // ===== 跨 Tab 共享状态 =====
  @State @Watch('watchCurrentMode') currentMode: RecordMode = RecordMode.BALANCED;
  @State isStationary: boolean = false;
  @State trackCount: number = 0;
  @State totalDistance: number = 0;
  @State @Watch('watchNightMode') nightModeIndex: number = 0;
  @State @Watch('watchShakeFloor') shakeFloorIndex: number = 0;
  @State @Watch('watchImmersive') immersive: boolean = false;

  private watchImmersive(): void {
    if (this.immersive) {
      this.tabsController.applyHideAnimation(HdsAnimationMode.CLICK_ANIMATION);
    } else {
      this.tabsController.applyShowAnimation(HdsAnimationMode.CLICK_ANIMATION);
    }
  }
  @State timeViewIndex: number = 2;
  @State hasApproximatelyLocation: boolean = false;
  @State hasLocation: boolean = false;
  @State hasBackgroundLocation: boolean = false;
  private pageNavStack: NavPathStack = new NavPathStack();

  // ===== 生命周期 =====
  aboutToAppear(): void {

    let ctx = getContext(this) as common.UIAbilityContext;
    this.mapStyleVM.setContext(ctx);

    // 从持久化存储恢复用户偏好
    this.loadPrefs(ctx);

    // 获取状态栏/导航条高度
    try {
      window.getLastWindow(ctx).then((win: window.Window) => {
        let avoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        this.statusBarHeight = px2vp(avoidArea.topRect.height);
        this.navBarHeight = px2vp(avoidArea.bottomRect.height);
      }).catch((err: BusinessError) => {
        console.error(TAG, `getLastWindow failed, code: ${err.code}, message: ${err.message}`);
      });
    } catch (e) {
      console.error(TAG, `get statusBarHeight failed: ${JSON.stringify(e)}`);
    }

    let materialTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    if (materialTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0) {
      this.customMaterialLevel = hdsMaterial.MaterialLevel.SMOOTH;
    }
  }

  onPageShow(): void {
    // 通知 FootprintTab 恢复地图显示
    if (this.mapManager.controller) {
      this.mapManager.controller.show();
    }
  }

  onPageHide(): void {
    // 通知 FootprintTab 隐藏地图以释放 GPU 资源
    if (this.mapManager.controller) {
      this.mapManager.controller.hide();
    }
  }

  aboutToDisappear(): void {
    this.locationSvc.stopLocation();
    this.db.stopFlushTimer();
    this.timeModel.stopDayCheck();
  }

  // ===== 偏好持久化（记住用户设置，重进不丢失）=====
  private loadPrefs(ctx: common.UIAbilityContext): void {
    try {
      let pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      let modeIdx: number = pref.getSync(PREF_KEY_RECORD_MODE, RecordMode.BALANCED) as number;
      if (modeIdx >= 0 && modeIdx <= 2) {
        this.currentMode = modeIdx as RecordMode;
      }
      let nightIdx: number = pref.getSync(PREF_KEY_NIGHT_MODE, 0) as number;
      if (nightIdx >= 0 && nightIdx <= 2) {
        this.nightModeIndex = nightIdx;
      }
      let shakeIdx: number = pref.getSync(PREF_KEY_SHAKE_FLOOR, 0) as number;
      if (shakeIdx >= 0 && shakeIdx <= 2) {
        this.shakeFloorIndex = shakeIdx;
      }
    } catch (e) {
      let error = e as BusinessError;
      console.error(`${TAG} loadPrefs failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  // @Watch 回调：用户偏好变化时自动持久化
  private watchCurrentMode(): void {
    let ctx = getContext(this) as common.UIAbilityContext;
    try {
      let pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      pref.putSync(PREF_KEY_RECORD_MODE, this.currentMode);
      pref.flushSync();
    } catch (e) {
      let error = e as BusinessError;
      console.error(`${TAG} save recordMode failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  private watchNightMode(): void {
    let ctx = getContext(this) as common.UIAbilityContext;
    try {
      let pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      pref.putSync(PREF_KEY_NIGHT_MODE, this.nightModeIndex);
      pref.flushSync();
    } catch (e) {
      let error = e as BusinessError;
      console.error(`${TAG} save nightMode failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  private watchShakeFloor(): void {
    let ctx = getContext(this) as common.UIAbilityContext;
    try {
      let pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      pref.putSync(PREF_KEY_SHAKE_FLOOR, this.shakeFloorIndex);
      pref.flushSync();
    } catch (e) {
      let error = e as BusinessError;
      console.error(`${TAG} save shakeFloor failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  // ===== 回调 =====
  private onRecordModeChange(mode: number): void {
    this.currentMode = mode as RecordMode;
    this.locationSvc.switchMode(mode);
  }

  private onNightModeChange(index: number): void {
    this.nightModeIndex = index;
  }

  // 清除轨迹：由 Mine 面板点击「删除轨迹」触发，弹出确认弹窗后执行清除
  private onClearTrack(): void {
    AlertDialog.show({
      title: '删除轨迹',
      message: '确定要删除全部轨迹记录吗？此操作不可恢复。',
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('sys.color.ohos_id_color_warning'),
        action: () => {
          this.doClearTrack();
        }
      }
    });
  }

  private async doClearTrack(): Promise<void> {
    this.mapManager.clearOverlays();
    this.timeModel.clearAll();
    this.trackCount = 0;
    this.totalDistance = 0;
    await this.db.clear();
  }

  private onRefreshPermission(): void {
    this.permSvc.refreshPermissionState().then((state) => {
      this.hasApproximatelyLocation = state.hasApproximatelyLocation;
      this.hasLocation = state.hasLocation;
      this.hasBackgroundLocation = state.hasBackgroundLocation;
    });
  }

  // ===== UI 构建 =====
  build() {
    Navigation(this.pageNavStack) {
      Stack({ alignContent: Alignment.TopStart }) {
        HdsTabs({ controller: this.tabsController }) {
          TabContent() {
            FootprintTab({
              db: this.db,
              permSvc: this.permSvc,
              locationSvc: this.locationSvc,
              mapManager: this.mapManager,
              timeModel: this.timeModel,
              mapStyleVM: this.mapStyleVM,
              statusBarHeight: this.statusBarHeight,
              navBarHeight: this.navBarHeight,
              currentMode: $currentMode,
              isStationary: $isStationary,
              trackCount: $trackCount,
              totalDistance: $totalDistance,
              shakeFloorIndex: $shakeFloorIndex,
              timeViewIndex: $timeViewIndex,
              hasApproximatelyLocation: $hasApproximatelyLocation,
              hasLocation: $hasLocation,
              hasBackgroundLocation: $hasBackgroundLocation,
              nightModeIndex: $nightModeIndex,
              immersive: $immersive
            })
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.figure_running'))
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .fontColor([$r('sys.color.ohos_id_color_primary')]),
            selected: new SymbolGlyphModifier($r('sys.symbol.figure_running'))
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .fontColor([$r('sys.color.ohos_id_color_activated')])
          }, '足迹'))

          TabContent() {
            StatsTab({
              timeModel: this.timeModel,
              navBarHeight: this.navBarHeight,
              statusBarHeight: this.statusBarHeight,
              trackCount: $trackCount,
              totalDistance: $totalDistance,
              isStationary: $isStationary,
              timeViewIndex: $timeViewIndex
            })
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.waveform_folder_fill'))
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .fontColor([$r('sys.color.ohos_id_color_primary')]),
            selected: new SymbolGlyphModifier($r('sys.symbol.waveform_folder_fill'))
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .fontColor([$r('sys.color.ohos_id_color_activated')])
          }, '统计'))
          .onAppear(() => {
            // StatsTab 每次切入时刷新统计
          })

          TabContent() {
            Column() {
              Mine({
                permSvc: this.permSvc,
                pageNavStack: this.pageNavStack,
                recordMode: $currentMode,
                hasApproximatelyLocation: $hasApproximatelyLocation,
                hasLocation: $hasLocation,
                hasBackgroundLocation: $hasBackgroundLocation,
                nightModeIndex: $nightModeIndex,
                shakeFloorIndex: $shakeFloorIndex,
                trackCount: $trackCount,
                onClearTrack: () => { this.onClearTrack(); },
                onRefreshPermission: () => { this.onRefreshPermission(); },
                onNightModeChange: (i: number) => { this.onNightModeChange(i); },
                onRecordModeChange: (mode: number) => { this.onRecordModeChange(mode); }
              })
            }
            .width('100%')
            .height('100%')
            .padding({ top: this.statusBarHeight })
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


        .onContentWillChange((_currentIndex: number, comingIndex: number) => {
          if (comingIndex === 1) {
            // StatsTab 切入时刷新统计
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
    }
    .navDestination(this.buildPageNavDest)
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideBackButton(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }

  @Builder
  private buildPageNavDest(name: string, param: Object) {
    if (name === 'StrategyLab') {
      this.buildStrategyLabDest(name, param);
    } else if (name === 'LogRecords') {
      this.buildLogRecordsDest(name, param);
    }
  }

  @Builder
  private buildStrategyLabDest(_name: string, _param: Object) {
    NavDestination() {
      StrategyLabPanel({
        shakeFloorIndex: $shakeFloorIndex
      })
    }
    .title('策略实验室')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private buildLogRecordsDest(_name: string, _param: Object) {
    NavDestination() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('sys.color.background_secondary'))
    }
    .title('日志记录')
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
