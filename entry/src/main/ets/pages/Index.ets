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
import { HdsNavigation, HdsNavDestination, HdsTabs, HdsTabsController, HdsAnimationMode, hdsMaterial } from '@kit.UIDesignKit';
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

import { RecordMode, TAG, PREF_NAME, PREF_KEY_RECORD_MODE, PREF_KEY_NIGHT_MODE, PREF_KEY_SLEEP_MODE, SLEEP_START_HOUR, SLEEP_END_HOUR } from '../model/TrackTypes';

@Entry
@Component
struct Index {
  private db: TrackDatabase = new TrackDatabase();
  private permSvc: PermissionService = new PermissionService();
  private locationSvc: TrackLocationService = new TrackLocationService();
  private mapManager: MapOverlayManager = new MapOverlayManager();
  private timeModel: TimeViewModel = new TimeViewModel();
  private mapStyleVM: MapStyleViewModel = new MapStyleViewModel();

  @State statusBarHeight: number = 0;
  @State navBarHeight: number = 0;
  private tabsController: HdsTabsController = new HdsTabsController();
  @State customMaterialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;

  @State @Watch('watchCurrentMode') currentMode: RecordMode = RecordMode.BALANCED;
  @State isStationary: boolean = false;
  @State sleepModeEnabled: boolean = false;
  private sleepCheckTimer: number | null = null;
  @State trackCount: number = 0;
  @State totalDistance: number = 0;
  @State hasApproximatelyLocation: boolean = false;
  @State hasLocation: boolean = false;
  @State hasBackgroundLocation: boolean = false;
  @State @Watch('watchNightMode') nightModeIndex: number = 0;
  @State timeViewIndex: number = 0;
  @State immersive: boolean = false;
  private mainNavStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.loadPrefs();
    this.locationSvc.switchMode(this.currentMode);
    this.locationSvc.setSleepModeEnabled(this.sleepModeEnabled);
    this.locationSvc.setUserMode(this.currentMode);
    this.startSleepCheckTimer();
    try {
      const materialTypes: hdsMaterial.MaterialType[] = hdsMaterial.getSystemMaterialTypes();
      if (materialTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0) {
        this.customMaterialLevel = hdsMaterial.MaterialLevel.SMOOTH;
      }
    } catch (e) {
      this.customMaterialLevel = hdsMaterial.MaterialLevel.SMOOTH;
    }
    try {
      const win = window.findWindow('FootprintWindow');
      if (win) {
        const avoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        this.statusBarHeight = px2vp(avoidArea.topRect.height);
        const bottomAvoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        this.navBarHeight = px2vp(bottomAvoid.bottomRect.height);
      }
    } catch (e) {
      // 窗口未就绪时使用默认值
    }
  }

  aboutToDisappear(): void {
    this.locationSvc.stopLocation();
    this.timeModel.stopDayCheck();
    this.stopSleepCheckTimer();
  }

  private watchCurrentMode(): void {
    this.locationSvc.switchMode(this.currentMode);
    this.locationSvc.setUserMode(this.currentMode);
    this.savePrefs();
  }

  private watchNightMode(): void {
    this.mapManager.applyNightMode(this.nightModeIndex);
    this.savePrefs();
  }

  private onClearTrack(): void {
    this.db.clear();
    this.timeModel.clearAll();
    this.mapManager.clearOverlays();
    this.trackCount = 0;
    this.totalDistance = 0;
  }

  private onRefreshPermission(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.permSvc.requestPermissions(ctx);
  }

  private onNightModeChange(index: number): void {
    this.nightModeIndex = index;
  }

  private onRecordModeChange(mode: number): void {
    this.currentMode = mode as RecordMode;
  }

  private onSleepModeChange(enabled: boolean): void {
    this.sleepModeEnabled = enabled;
    this.locationSvc.setSleepModeEnabled(enabled);
    this.savePrefs();
  }

  private startSleepCheckTimer(): void {
    this.sleepCheckTimer = setInterval(() => {
      this.locationSvc.checkAndEnterSleep();
      this.locationSvc.checkAndExitSleepOnTime();
    }, 60 * 1000);
  }

  private stopSleepCheckTimer(): void {
    if (this.sleepCheckTimer !== null) {
      clearInterval(this.sleepCheckTimer);
      this.sleepCheckTimer = null;
    }
  }

  private loadPrefs(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      this.currentMode = pref.getSync(PREF_KEY_RECORD_MODE, RecordMode.BALANCED) as RecordMode;
      this.nightModeIndex = pref.getSync(PREF_KEY_NIGHT_MODE, 0) as number;
      this.sleepModeEnabled = pref.getSync(PREF_KEY_SLEEP_MODE, false) as boolean;
    } catch (e) {
      const error = e as BusinessError;
      console.error(`${TAG} loadPrefs failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  private savePrefs(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      pref.putSync(PREF_KEY_RECORD_MODE, this.currentMode);
      pref.putSync(PREF_KEY_NIGHT_MODE, this.nightModeIndex);
      pref.putSync(PREF_KEY_SLEEP_MODE, this.sleepModeEnabled);
      pref.flushSync();
    } catch (e) {
      const error = e as BusinessError;
      console.error(`${TAG} savePrefs failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  build() {
    HdsNavigation(this.mainNavStack) {
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
            timeViewIndex: $timeViewIndex,
            hasApproximatelyLocation: $hasApproximatelyLocation,
            hasLocation: $hasLocation,
            hasBackgroundLocation: $hasBackgroundLocation,
            nightModeIndex: $nightModeIndex,
            immersive: $immersive,
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
            timeViewIndex: $timeViewIndex,
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

        TabContent() {
          Mine({
            permSvc: this.permSvc,
            mainNavStack: this.mainNavStack,
            recordMode: $currentMode,
            sleepModeEnabled: $sleepModeEnabled,
            hasApproximatelyLocation: $hasApproximatelyLocation,
            hasLocation: $hasLocation,
            hasBackgroundLocation: $hasBackgroundLocation,
            nightModeIndex: $nightModeIndex,
            trackCount: $trackCount,
            onClearTrack: () => { this.onClearTrack(); },
            onRefreshPermission: () => { this.onRefreshPermission(); },
            onNightModeChange: (i: number) => { this.onNightModeChange(i); },
            onRecordModeChange: (m: number) => { this.onRecordModeChange(m); },
            onSleepModeChange: (e: boolean) => { this.onSleepModeChange(e); },
          })
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
      .barFloatingStyle({
          barBottomMargin: 28 + this.navBarHeight,
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
    .navDestination(this.mainNavDestination)
  }

  @Builder
  mainNavDestination(name: string) {
    if (name === 'StrategyLab') {
      HdsNavDestination() {
        StrategyLabPanel()
      }
      .titleBar({
        content: {
          title: { mainTitle: '策略实验室' }
        }
      })
      .hideBackButton(false)
    }
  }
}
