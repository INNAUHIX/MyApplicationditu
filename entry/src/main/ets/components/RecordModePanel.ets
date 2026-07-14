/**
 * RecordModePanel.ets —— 记录规则面板子组件
 *
 * 从 Mine.buildRecordModeSheet() 提取的独立 @Component，
 * 承载三档记录规则的 Radio 选择与说明。
 *
 * 布局规范（HarmonyOS Design）：
 *   - 两档模式拆为独立卡片，卡片间距 12vp
 *   - 卡片圆角 16vp（RadiusL）
 *   - 卡片内边距 16vp（Padding_level8）
 *   - 屏幕边缘 16vp
 */

import { RecordMode, MODE_CONFIG, SLEEP_START_HOUR, SLEEP_END_HOUR } from '../model/TrackTypes';

@Component
export struct RecordModePanel {
  @Link recordMode: RecordMode;
  @Link sleepModeEnabled: boolean;
  onRecordModeChange: (mode: number) => void = () => {};
  onSleepModeChange: (enabled: boolean) => void = () => {};

  private recordModeNames: string[] = ['均衡', '耗电'];
  private recordModeDescs: string[] = [
    `定位间隔\t${MODE_CONFIG[RecordMode.BALANCED].timeInterval}秒\n点间距\t≥${MODE_CONFIG[RecordMode.BALANCED].distanceInterval}米（距离触发）\n定位精度\t高精GPS\n每日耗电\t约8%–15%\n适用场景\t日常通勤，精度与耗电均衡，推荐默认\n\n工作方式：系统每${MODE_CONFIG[RecordMode.BALANCED].timeInterval}秒推送一次定位，App计算与上次记录点的距离，≥${MODE_CONFIG[RecordMode.BALANCED].distanceInterval}米才打点，不足则丢弃`,
    `定位间隔\t${MODE_CONFIG[RecordMode.HIGH_POWER].timeInterval}秒\n点间距\t≥${MODE_CONFIG[RecordMode.HIGH_POWER].distanceInterval}米（距离触发）\n定位精度\t高精GPS\n每日耗电\t约15%–25%\n适用场景\t骑行/步行等需要较细腻轨迹的场景\n\n工作方式：系统每${MODE_CONFIG[RecordMode.HIGH_POWER].timeInterval}秒推送一次定位，App计算与上次记录点的距离，≥${MODE_CONFIG[RecordMode.HIGH_POWER].distanceInterval}米才打点，不足则丢弃`
  ];

  build() {
    Scroll() {
      Column({ space: 12 }) {
        ForEach(this.recordModeDescs, (desc: string, index: number) => {
          Row() {
            Column({ space: 6 }) {
              Text(this.recordModeNames[index])
                .fontSize(16)
                .fontColor($r('sys.color.font_primary'))
                .fontWeight(FontWeight.Medium)
                .textAlign(TextAlign.Start)
              Text(desc)
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
                .textAlign(TextAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Radio({ value: `${index}`, group: 'recordMode' })
              .checked(this.recordMode === index)
              .radioStyle({
                checkedBackgroundColor: $r('sys.color.ohos_id_color_activated'),
                uncheckedBorderColor: $r('sys.color.comp_background_emphasize'),
                indicatorColor: $r('sys.color.comp_background_primary')
              })
              .width(24)
              .height(24)
              .onChange((isChecked: boolean) => {
                if (isChecked) {
                  this.recordMode = index as RecordMode;
                  this.onRecordModeChange(index);
                }
              })
              .margin({ left: 16 })
          }
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .onClick(() => {
            this.recordMode = index as RecordMode;
            this.onRecordModeChange(index);
          })
        }, (_desc: string, index: number) => `rm_${index}`)

        Row() {
          Column({ space: 6 }) {
            Text('睡眠模式')
              .fontSize(16)
              .fontColor($r('sys.color.font_primary'))
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Start)
            Text(`定位间隔\t60秒\n点间距\t≥200米（距离触发）\n自动时段\t${SLEEP_START_HOUR}:00-${SLEEP_END_HOUR}:00\n适用场景\t夜间自动降频省电，检测到活动自动恢复\n\n进入条件：睡眠时段内，连续10个定位点均落在15米半径内，判定为静止后进入睡眠模式（此判断独立运行，不受静止检测开关影响）\n退出条件：连续3个定位点距睡眠起点持续单调远离且累计超过100米，判定为真实移动后退出；或超过6:00自动退出\n\n工作方式：进入后切换为60秒低频定位，不记录足迹点；退出后恢复正常记录规则`)
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: $$this.sleepModeEnabled })
            .onChange((isOn: boolean) => {
              this.onSleepModeChange(isOn);
            })
            .selectedColor($r('sys.color.ohos_id_color_activated'))
            .margin({ left: 16 })
        }
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 })
    }
    .layoutWeight(1)
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    .nestedScroll({
      scrollForward: NestedScrollMode.PARENT_FIRST,
      scrollBackward: NestedScrollMode.SELF_FIRST
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
