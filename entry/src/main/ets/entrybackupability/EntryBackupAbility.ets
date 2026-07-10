/**
 * EntryBackupAbility.ets —— 数据备份/恢复扩展 Ability
 *
 * 由系统「备份与恢复」触发；此处仅打点记录，未做额外数据处理。
 * 如需迁移 footprint.db 等用户数据，可在 onBackup / onRestore 中实现文件拷贝。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'EntryBackupAbility';

export default class EntryBackupAbility extends BackupExtensionAbility {
  // 备份开始时回调：可在此将应用沙箱数据导出到备份目录
  async onBackup() {
    hilog.info(DOMAIN, TAG, 'onBackup ok');
    await Promise.resolve();
  }

  // 恢复开始时回调：bundleVersion 为备份时的版本信息，可据此做兼容处理
  async onRestore(bundleVersion: BundleVersion) {
    hilog.info(DOMAIN, TAG, 'onRestore ok %{public}s', JSON.stringify(bundleVersion));
    await Promise.resolve();
  }
}