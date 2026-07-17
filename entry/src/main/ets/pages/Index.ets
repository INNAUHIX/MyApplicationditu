/**
 * Index.ets —— 应用主页面编排层
 *
 * FootprintTab 直接作为 HdsNavigation 内容。
 * HdsTabs 浮动页签移至 FootprintTab 内部，与地图同组件。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { HdsNavigation, HdsNavDestination } from '@kit.UIDesignKit';
import { window, display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { TrackDatabase } from '../data/TrackDatabase';
import { PermissionService } from '../service/PermissionService';
import { TrackLocationService } from '../service/TrackLocationService';
import { MapOverlayManager } from '../service/MapOverlayManager';
import { TimeViewModel } from '../viewmodel/TimeViewModel';
import { MapStyleViewModel } from '../viewmodel/MapStyleViewModel';
import { FootprintTab } from './FootprintTab';

import { StrategyLabPanel } from '../components/StrategyLabPanel';

import {
  RecordMode, TAG, PREF_NAME, PREF_KEY_RECORD_MODE, PREF_KEY_NIGHT_MODE, PREF_KEY_SLEEP_MODE
} from '../model/TrackTypes';

const TAG_LOG: string = 'Index';

function px2vpSafe(px: number): number {
  try {
    const density = display.getDefaultDisplaySync().densityPixels;
    return px / density;
  } catch (e) {
    return px / 3;
  }
}

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

  @State @Watch('watchCurrentMode') currentMode: RecordMode = RecordMode.BALANCED;

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
    let ctx: common.UIAbilityContext | undefined = undefined;
    try {
      ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (e) {}

    if (ctx !== undefined) {
      this.locationSvc.init(ctx);
    }

    this.loadPrefs();
    this.locationSvc.switchMode(this.currentMode);
    this.locationSvc.setSleepModeEnabled(this.sleepModeEnabled);
    this.locationSvc.setUserMode(this.currentMode);
    this.startSleepCheckTimer();
    if (ctx !== undefined) {
      try {
        window.getLastWindow(ctx).then((win) => {
          const avoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          this.statusBarHeight = px2vpSafe(avoidArea.topRect.height);
          const bottomAvoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
          this.navBarHeight = px2vpSafe(bottomAvoid.bottomRect.height);
        }).catch(() => {});
      } catch (e) {}
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

  private onRefreshPermission(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.permSvc.requestPermissions(ctx, this.getUIContext());
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
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      this.currentMode = pref.getSync(PREF_KEY_RECORD_MODE, RecordMode.BALANCED) as RecordMode;
      this.nightModeIndex = pref.getSync(PREF_KEY_NIGHT_MODE, 0) as number;
      this.sleepModeEnabled = pref.getSync(PREF_KEY_SLEEP_MODE, false) as boolean;
    } catch (e) {
      const error = e as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'loadPrefs failed, code: %{public}d, message: %{public}s', error.code, error.message);
    }
  }

  private savePrefs(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      pref.putSync(PREF_KEY_RECORD_MODE, this.currentMode);
      pref.putSync(PREF_KEY_NIGHT_MODE, this.nightModeIndex);
      pref.putSync(PREF_KEY_SLEEP_MODE, this.sleepModeEnabled);
      pref.flushSync();
    } catch (e) {
      const error = e as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'savePrefs failed, code: %{public}d, message: %{public}s', error.code, error.message);
    }
  }

  build() {
    HdsNavigation(this.mainNavStack) {
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
        mainNavStack: this.mainNavStack,
        trackCount: $trackCount,
        totalDistance: $totalDistance,
        timeViewIndex: $timeViewIndex,
        hasApproximatelyLocation: $hasApproximatelyLocation,
        hasLocation: $hasLocation,
        hasBackgroundLocation: $hasBackgroundLocation,
        nightModeIndex: $nightModeIndex,
        sleepModeEnabled: $sleepModeEnabled,
        immersive: $immersive,
        onRefreshPermission: () => { this.onRefreshPermission(); },
        onNightModeChange: (i: number) => { this.onNightModeChange(i); },
        onRecordModeChange: (m: number) => { this.onRecordModeChange(m); },
        onSleepModeChange: (e: boolean) => { this.onSleepModeChange(e); },
      })
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideToolBar(true)
    .hideBackButton(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .navDestination(this.mainNavDestination)
  }

  // MiniBar 和 HdsTabs 已移至 FootprintTab 内部
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
