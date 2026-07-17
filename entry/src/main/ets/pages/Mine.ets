/**
 * Mine.ets —— 「我的」Tab 组件（瘦身版）
 *
 * 从 1223 行瘦身至 ≤200 行，具体措施：
 *   - 移除全部占位/未实现功能项（字体大小/页面跳转/Web页面/关于我们/检测版本/
 *     我的订单/意见反馈/退出登录/自定义开关/自定义下拉）
 *   - 3 个半模态面板拆为独立 @Component 子组件
 *   - 策略实验室通过顶层 Navigation 导航跳转（二级页面覆盖Tab栏）
 */

import { RecordMode, MODE_CONFIG } from '../model/TrackTypes';
import { CardItem } from '../components/CardItem';
import { RecordModePanel } from '../components/RecordModePanel';
import { LocationPermPanel } from '../components/LocationPermPanel';
import { SettingPanel } from '../components/SettingPanel';
import { PermissionService } from '../service/PermissionService';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG_LOG: string = 'Mine';

@Component
export struct Mine {
  permSvc: PermissionService = new PermissionService();
  mainNavStack: NavPathStack | null = null;

  @Link recordMode: RecordMode;
  @Link sleepModeEnabled: boolean;
  @Link hasApproximatelyLocation: boolean;
  @Link hasLocation: boolean;
  @Link hasBackgroundLocation: boolean;
  @Link nightModeIndex: number;


  @State pushSwitchOn: boolean = false;

  onRefreshPermission: () => void = () => {};
  onNightModeChange: (index: number) => void = () => {};
  onRecordModeChange: (mode: number) => void = () => {};
  onSleepModeChange: (enabled: boolean) => void = () => {};

  safeBottom: number = 0;

  @State isShowRecordMode: boolean = false;
  @State isShowLocation: boolean = false;
  @State isShowSetting: boolean = false;

  private isLocationAbnormal(): boolean {
    return !(this.hasApproximatelyLocation && this.hasLocation && this.hasBackgroundLocation);
  }

  build() {
    Column() {
      Text('我的')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 16 }) {
          Column() {
            Column() {
              CardItem({
                label: '记录规则',
                symbol: $r('sys.symbol.local_badge_gearshape'),
                statusText: MODE_CONFIG[this.recordMode].label,
                statusColor: $r('sys.color.font_secondary'),
                onClickEvent: () => { this.isShowRecordMode = true; }
              })
              Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
              CardItem({
                label: '策略实验室',
                symbol: $r('sys.symbol.person_shield_fill'),
                onClickEvent: () => { this.mainNavStack?.pushPath({ name: 'StrategyLab' }); }
              })
              Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
              CardItem({
                label: '定位权限',
                symbol: $r('sys.symbol.position_badge_exclamationmark'),
                statusText: this.isLocationAbnormal() ? '权限异常' : '',
                statusColor: $r('sys.color.ohos_id_color_warning'),
                onClickEvent: () => {
                  this.onRefreshPermission();
                  this.isShowLocation = true;
                }
              })
            }
            .width('100%')
          }
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          Column() {
            Column() {
              CardItem({
                label: '设置',
                symbol: $r('sys.symbol.gearshape'),
                onClickEvent: () => { this.isShowSetting = true; }
              })
            }
            .width('100%')
          }
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          Column() {
            Column()
              .width(0)
              .height(0)
              .bindSheet($$this.isShowRecordMode, this.recordModeSheet(), {
                title: { title: '记录规则' },
                onDisappear: () => { this.isShowRecordMode = false; }
              })
            Column()
              .width(0)
              .height(0)
              .bindSheet($$this.isShowLocation, this.locationSheet(), {
                title: { title: '定位权限' },
                onDisappear: () => { this.isShowLocation = false; }
              })
            Column()
              .width(0)
              .height(0)
              .bindSheet($$this.isShowSetting, this.settingSheet(), {
                title: { title: '设置' },
                onDisappear: () => { this.isShowSetting = false; }
              })
          }
          .width(0)
          .height(0)
        }
        .margin({ bottom: this.safeBottom })
        .padding({ left: 16, right: 16, top: 4 })
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

  @Builder
  private recordModeSheet(): void {
    RecordModePanel({
      recordMode: $recordMode,
      sleepModeEnabled: $sleepModeEnabled,
      onRecordModeChange: (mode: number) => { this.onRecordModeChange(mode); },
      onSleepModeChange: (enabled: boolean) => { this.onSleepModeChange(enabled); }
    })
  }

  @Builder
  private locationSheet(): void {
    LocationPermPanel({
      permSvc: this.permSvc,
      hasApproximatelyLocation: $hasApproximatelyLocation,
      hasLocation: $hasLocation,
      hasBackgroundLocation: $hasBackgroundLocation,
      onRefreshPermission: () => { this.onRefreshPermission(); }
    })
  }

  @Builder
  private settingSheet(): void {
    SettingPanel({
      nightModeIndex: $nightModeIndex,
      pushSwitchOn: $pushSwitchOn,

      onNightModeChange: (i: number) => { this.onNightModeChange(i); }
    })
  }
}
