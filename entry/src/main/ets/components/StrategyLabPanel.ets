/**
 * StrategyLabPanel.ets —— 策略实验室面板子组件
 *
 * 从 Mine 策略实验室页面提取的独立 @Component，
 * 承载自动生效策略列表。
 *
 * 已移除策略：足迹降密、实时连线、漂移过滤、静止不记、绘制节流、抖动地板
 *
 * 布局规范（HarmonyOS Design）：
 *   - 策略卡片独立展示，卡片间距 12vp
 *   - 卡片圆角 16vp（RadiusL）
 *   - 卡片内边距 16vp（Padding_level8）
 *   - 屏幕边缘 16vp
 */

import { RecordStrategyItem } from '../model/TrackTypes';

@Component
export struct StrategyLabPanel {

  private recordStrategyItems: RecordStrategyItem[] = [
    { title: '坐标纠偏', desc: '手机GPS返回的是WGS84坐标系，国内地图使用GCJ02坐标系，两者有几十到几百米偏差。系统自动将每个定位点从WGS84转换为GCJ02，确保轨迹与地图道路对齐。' },
    { title: '距离触发采样', desc: '所有模式下，系统按固定时间间隔获取定位，但仅当新点与上一个记录点距离达到阈值时才打点记录，不足则丢弃。均衡模式阈值100米，耗电模式阈值30米。' },
    { title: '静止检测', desc: '所有模式下，连续定位点均落在小范围内（≤15米）判定为静止，静止期间不记录定位点；仅当明显远离（>30米）才视为真正移动并恢复记录。' }
  ];

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Column() {
          Text('自动生效策略')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .width('100%')
          Text('以下策略在所有定位模式下自动生效，无需手动开启：')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .margin({ top: 4 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))

        ForEach(this.recordStrategyItems,
          (item: RecordStrategyItem, index: number) => {
            Row() {
              Column({ space: 6 }) {
                Text(item.title)
                  .fontSize(16)
                  .fontColor($r('sys.color.font_primary'))
                  .fontWeight(FontWeight.Medium)
                  .textAlign(TextAlign.Start)
                Text(item.desc)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
                  .textAlign(TextAlign.Start)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .padding(16)
            .borderRadius(16)
            .backgroundColor($r('sys.color.comp_background_list_card'))
          },
          (item: RecordStrategyItem, index: number) => `str_${index}`)
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
