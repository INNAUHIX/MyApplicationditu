/**
 * MapStyleViewModel.ets —— 地图样式偏好管理
 *
 * 将 Index 的 saveMapStyle/loadMapStyle 逻辑迁入统一管理，
 * 与 TimeViewModel 的偏好管理一致，均使用 preferences API。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PREF_NAME, PREF_KEY_MAP_STYLE } from '../model/TrackTypes';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG_LOG: string = 'MapStyleVM';

export class MapStyleViewModel {
  private context?: common.UIAbilityContext;
  private mapStyleIndex: number = 0;

  setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  get styleIndex(): number {
    return this.mapStyleIndex;
  }

  // 保存地图样式偏好：切换即持久化，下次重进按上次选择恢复
  saveMapStyle(index: number): void {
    this.mapStyleIndex = index;
    if (!this.context) {
      return;
    }
    try {
      const pref = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      pref.putSync(PREF_KEY_MAP_STYLE, index);
      pref.flushSync();
    } catch (e) {
      const error = e as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'saveMapStyle failed, code: %{public}d, message: %{public}s', error.code, error.message);
    }
  }

  // 加载地图样式偏好，默认 0（经典样式）
  loadMapStyle(): number {
    if (!this.context) {
      return 0;
    }
    try {
      const pref = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      let idx: number = pref.getSync(PREF_KEY_MAP_STYLE, 0) as number;
      if (idx < 0 || idx > 3) {
        idx = 0;
      }
      this.mapStyleIndex = idx;
      return idx;
    } catch (e) {
      const error = e as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'loadMapStyle failed, code: %{public}d, message: %{public}s', error.code, error.message);
      return 0;
    }
  }
}
