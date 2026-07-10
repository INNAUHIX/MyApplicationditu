/**
 * EntryAbility.ets —— 应用入口 Ability（UIAbility）
 *
 * 职责：
 *  - 加载主页面 pages/Index
 *  - 管理应用前后台切换时的「后台定位长任务」：
 *    进入后台时申请后台运行(LOCATION 模式)，保证轨迹能在后台持续记录；
 *    回到前台或销毁时停止，避免无谓耗电。
 */
import { AbilityConstant, ConfigurationConstant, UIAbility, Want, wantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  private isBackgroundRunning: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    this.stopBackgroundTask();
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    this.stopBackgroundTask();
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // 进入后台：启动后台定位长任务，使轨迹记录在应用不可见时仍可继续
    this.startBackgroundTask();
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }

  // 申请后台运行(LOCATION 模式)：用 WantAgent 关联自身，确保系统允许后台持续定位
  private async startBackgroundTask(): Promise<void> {
    if (this.isBackgroundRunning) {
      return;
    }
    try {
      let wantObj: Want = {
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: this.context.abilityInfo.name
      };
      let wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [wantObj],
        requestCode: 0,
        actionType: wantAgent.OperationType.START_ABILITY,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      let agent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(this.context, backgroundTaskManager.BackgroundMode.LOCATION, agent);
      this.isBackgroundRunning = true;
      hilog.info(DOMAIN, TAG, 'startBackgroundRunning succeeded');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}s', JSON.stringify(err));
    }
  }

  // 停止后台定位长任务（回到前台 / Ability 销毁时调用）
  private async stopBackgroundTask(): Promise<void> {
    if (!this.isBackgroundRunning) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.isBackgroundRunning = false;
      hilog.info(DOMAIN, TAG, 'stopBackgroundRunning succeeded');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'stopBackgroundRunning failed: %{public}s', JSON.stringify(err));
    }
  }
}
