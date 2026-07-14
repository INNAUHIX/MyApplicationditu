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
    // 窗口销毁时的清理；长时任务在 onDestroy 中统一取消
  }

  onForeground(): void {
    this.stopBackgroundTask();
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    this.startBackgroundTask();
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }

  private async startBackgroundTask(): Promise<void> {
    if (this.isBackgroundRunning) {
      return;
    }
    try {
      const wantObj: Want = {
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: this.context.abilityInfo.name
      };
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [wantObj],
        requestCode: 0,
        actionType: wantAgent.OperationType.START_ABILITY,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(this.context, backgroundTaskManager.BackgroundMode.LOCATION, agent);
      this.isBackgroundRunning = true;
      hilog.info(DOMAIN, TAG, 'startBackgroundRunning succeeded');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}s', JSON.stringify(err));
    }
  }

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
