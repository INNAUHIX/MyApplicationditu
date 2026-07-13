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

  private recordModeNames: string[] = ['省电', '均衡', '耗电', '智能采样'];
  private recordModeDescs: string[] = [
    '定位场景\t日常服务（低频）\n定位间隔\t约60秒\n定位精度\t高精GPS\n每日耗电\t约3%–8%\n适用场景\t长时间后台挂机，对轨迹精度要求不高的日常记录',
    '定位场景\t轨迹追踪（按间隔）\n定位间隔\t20秒\n点间距\t100米（距离触发）\n定位精度\t高精GPS\n每日耗电\t约8%–15%\n适用场景\t日常通勤，精度与耗电均衡，推荐默认\n\n工作方式：系统每20秒推送一次定位，App计算与上次记录点的距离，≥100米才打点，不足则丢弃；速度<0.5m/s时跳过，过滤静止漂移',
    '定位场景\t导航级（高频）\n定位间隔\t约1–5秒\n定位精度\t高精GPS\n每日耗电\t约20%–35%\n适用场景\t骑行/步行导航等需要细腻轨迹的场景',
    '定位场景\t日常服务（低频）\n定位间隔\t120秒（兜底）\n点间距\t100米（距离触发）\n定位精度\t平衡GPS\n每日耗电\t约4%–10%\n适用场景\t全天默认，不动不记，动了才记\n\n工作方式：系统每2分钟推送一次定位，App计算与上次记录点的距离，≥100米才打点，不足则丢弃；速度<0.5m/s时跳过，过滤静止漂移'
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
