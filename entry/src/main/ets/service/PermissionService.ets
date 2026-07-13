/**
 * PermissionService.ets —— 定位权限服务
 *
 * 从 Index 原 refreshPermissionState / checkAccessToken / requestPermissions /
 * requestBackgroundLocationPermission / guideToLocationSettings / openPermissionSettings 抽取。
 * 仅负责「权限」相关逻辑，不触碰地图与轨迹；UI 上下文（UIContext）与能力上下文
 * （UIAbilityContext）由调用方显式传入，保持服务类对组件的无侵入依赖。
 */

import { abilityAccessCtrl, bundleManager, common, Permissions, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { UIContext } from '@kit.ArkUI';
import { TAG } from '../model/TrackTypes';

// 三项定位权限的授权状态快照
export interface PermissionState {
  hasApproximatelyLocation: boolean;
  hasLocation: boolean;
  hasBackgroundLocation: boolean;
}

export class PermissionService {
  // 查询指定权限是否已授权：通过 bundleInfo 获取 tokenId，再调用 atManager.checkAccessToken
  async checkAccessToken(permission: Permissions): Promise<abilityAccessCtrl.GrantStatus> {
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

  // 读取三项定位权限(大致/精确/后台)的当前授权状态
  async refreshPermissionState(): Promise<PermissionState> {
    let hasForeground = await this.checkAccessToken('ohos.permission.APPROXIMATELY_LOCATION');
    let hasLocation = await this.checkAccessToken('ohos.permission.LOCATION');
    let hasBackground = await this.checkAccessToken('ohos.permission.LOCATION_IN_BACKGROUND');
    return {
      hasApproximatelyLocation: hasForeground === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED,
      hasLocation: hasLocation === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED,
      hasBackgroundLocation: hasBackground === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
    };
  }

  // 向前台定位权限(大致 + 精确)发起授权申请；返回申请后的最新权限状态快照
  async requestPermissions(context: common.UIAbilityContext): Promise<PermissionState> {
    let atManager = abilityAccessCtrl.createAtManager();
    let permissions: Array<Permissions> = [
      'ohos.permission.APPROXIMATELY_LOCATION',
      'ohos.permission.LOCATION'
    ];
    try {
      let result = await atManager.requestPermissionsFromUser(context, permissions);
      let authResults: Array<number> = result.authResults;
      let hasApproximately = authResults[0] === 0;
      let hasLocation = authResults[1] === 0;
      let hasBackground = (await this.checkAccessToken('ohos.permission.LOCATION_IN_BACKGROUND')) ===
        abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      if (hasApproximately && hasLocation) {
        if (!hasBackground) {
          // 前台已授权但后台未授权：由调用方决定后续引导；此处仅返回状态
        }
      } else {
        // 用户拒绝或系统不再弹授权框：弹出应用内引导对话框，避免点击后无任何反应
        console.warn(TAG, 'Location permission denied, please grant in Settings');
        this.guideToLocationSettings(context);
      }
      return {
        hasApproximatelyLocation: hasApproximately,
        hasLocation: hasLocation,
        hasBackgroundLocation: hasBackground
      };
    } catch (err) {
      let error = err as BusinessError;
      console.error(`Failed to request permissions from user. Code: ${error.code}, message: ${error.message}`);
      return {
        hasApproximatelyLocation: false,
        hasLocation: false,
        hasBackgroundLocation: false
      };
    }
  }

  // 弹窗引导用户去系统设置将定位改为「始终允许」，以支持后台持续记录轨迹
  requestBackgroundLocationPermission(uiContext: UIContext): void {
    uiContext.getPromptAction().showDialog({
      title: '开启后台定位',
      message: '请在设置中将定位权限改为"始终允许"，并开启"精确定位"，以支持后台持续记录轨迹。',
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '开启权限', color: '#007DFF' }
      ]
    }).then((result) => {
      if (result.index === 1) {
        this.openPermissionSettingsFromUI(uiContext);
      }
    }).catch((err: BusinessError) => {
      console.error(`showDialog failed. Code: ${err.code}, message: ${err.message}`);
    });
  }

  // 前台定位权限被拒 / 系统不再弹授权框时，弹出应用内引导对话框，
  // 提示并引导用户前往系统设置手动开启「大致位置」与「精确位置」
  guideToLocationSettings(context: common.UIAbilityContext): void {
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
          this.openPermissionSettings(context);
        }
      }
    });
  }

  // 跳转到系统「应用信息」设置页，便于用户手动修改定位权限
  async openPermissionSettings(context: common.UIAbilityContext): Promise<void> {
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

  // 用于后台权限弹窗「开启权限」按钮：从 UIContext 反查 UIAbilityContext 后跳转设置
  private openPermissionSettingsFromUI(uiContext: UIContext): void {
    try {
      let context = uiContext.getHostContext() as common.UIAbilityContext;
      this.openPermissionSettings(context);
    } catch (err) {
      let error = err as BusinessError;
      console.error(`Failed to get host context. Code: ${error.code}, message: ${error.message}`);
    }
  }
}
