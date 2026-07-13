/**
 * RecordModePanel.ets —— 记录规则面板子组件
 *
 * 从 Mine.buildRecordModeSheet() 提取的独立 @Component，
 * 承载三档记录规则的 Radio 选择与说明。
 *
 * 布局规范（HarmonyOS Design）：
 *   - 三档模式拆为独立卡片，卡片间距 12vp
 *   - 卡片圆角 16vp（RadiusL）
 *   - 卡片内边距 16vp（Padding_level8）
 *   - 屏幕边缘 16vp
 */

import { RecordMode, MODE_CONFIG } from '../model/TrackTypes';

@Component
export struct RecordModePanel {
  @Link recordMode: RecordMode;
  onRecordModeChange: (mode: number) => void = () => {};

  private recordModeNames: string[] = ['省电', '均衡', '耗电'];
  private recordModeDescs: string[] = [
    '定位间隔约60秒，精度门槛200米。采样最稀疏、最省电，适合长时间后台挂机、对轨迹精度要求不高的日常记录。',
    '定位间隔约15秒，精度门槛100米。精度与耗电均衡，推荐作为日常默认档位。',
    '定位间隔约5秒，精度门槛30米。采样最密集、轨迹最精细，但最费电，适合骑行 / 步行导航等需要细腻轨迹的场景。'
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
