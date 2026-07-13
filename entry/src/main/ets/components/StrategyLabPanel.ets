/**
 * StrategyLabPanel.ets —— 策略实验室面板子组件
 *
 * 从 Mine.buildStrategyLabSheet() 提取的独立 @Component，
 * 承载自动生效策略列表 + 抖动地板阈值切换。
 *
 * 已移除策略：足迹降密、实时连线、漂移过滤
 *
 * 布局规范（HarmonyOS Design）：
 *   - 策略卡片独立展示，卡片间距 12vp
 *   - 卡片圆角 16vp（RadiusL）
 *   - 卡片内边距 16vp（Padding_level8）
 *   - 屏幕边缘 16vp
 *   - 半模态内容区使用 Scroll + nestedScroll 配合面板手势
 */

import { RecordStrategyItem, SHAKE_FLOOR_OPTIONS } from '../model/TrackTypes';

@Component
export struct StrategyLabPanel {
  @Link shakeFloorIndex: number;
  @State isShowShakeSheet: boolean = false;

  private recordStrategyItems: RecordStrategyItem[] = [
    { title: '静止降频', desc: '连续定位点均落在小范围内（≤15米）判定为静止，自动把定位间隔降到30秒或档位间隔的较大值省电；仅当明显远离（>30米）才视为真正移动并恢复档位间隔。' },
    { title: '静止不记', desc: '定位上报速度低于步行速度（约3.6km/h）时视为原地未动，不记录，避免静止漂移画蛇添足。' },
    { title: '抖动地板', desc: '与上一个折线点距离不足当前阈值视为原地抖动，直接丢弃，防止轨迹回绕。点击右侧可查看详情并切换阈值。' },
    { title: '批量落库', desc: '轨迹点先进缓冲，每8秒定时一次性写入数据库，降低存储写入频率。' },
    { title: '绘制节流', desc: '折线每新增50点、海量点每新增20点且最多每30秒刷新一次，避免高频重绘卡顿。' }
  ];
  private shakeFloorOptions: string[] = ['5米', '10米', '15米'];

  build() {
    Scroll() {
      Column({ space: 12 }) {
        // 说明区
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

        // 策略卡片
        ForEach(this.recordStrategyItems,
          (item: RecordStrategyItem, index: number) => {
            if (item.title === '抖动地板') {
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
                Row() {
                  Text(this.shakeFloorOptions[this.shakeFloorIndex])
                    .fontSize(14)
                    .fontColor($r('sys.color.font_secondary'))
                    .margin({ right: 4 })
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(16)
                    .fontColor([$r('sys.color.font_fourth')])
                }
                .justifyContent(FlexAlign.End)
                .onClick(() => { this.isShowShakeSheet = true; })
              }
              .padding(16)
              .borderRadius(16)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .bindSheet($$this.isShowShakeSheet, this.shakeFloorSheet(), {
                title: { title: '抖动地板阈值' },
                detents: [SheetSize.MEDIUM],
                dragBar: true, showClose: true,
                onDisappear: () => { this.isShowShakeSheet = false; }
              })
            } else {
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
            }
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

  @Builder
  private shakeFloorSheet(): void {
    Scroll() {
      Column({ space: 12 }) {
        // 抖动地板介绍
        Column() {
          Text('什么是抖动地板？')
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .width('100%')
          Text('当实时定位点与上一个已记录的折线轨迹点的距离不足设置阈值时，系统判定为原地抖动/漂移，直接丢弃该点，避免在轨迹上画出锯齿状的毛刺线。阈值越大，过滤效果越强，但过高的阈值可能导致轨迹不够精细。')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .margin({ top: 8 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))

        // 选项标题
        Text('选择抖动阈值')
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .fontWeight(FontWeight.Medium)
          .width('100%')

        // 选项卡片
        ForEach(this.shakeFloorOptions, (option: string, idx: number) => {
          Row() {
            Column({ space: 6 }) {
              Text(option)
                .fontSize(16)
                .fontColor($r('sys.color.font_primary'))
                .fontWeight(this.shakeFloorIndex === idx ? FontWeight.Medium : FontWeight.Regular)
                .textAlign(TextAlign.Start)
              Text(this.getShakeFloorDesc(idx))
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
                .textAlign(TextAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Radio({ value: `${idx}`, group: 'shakeFloor' })
              .checked(this.shakeFloorIndex === idx)
              .radioStyle({
                checkedBackgroundColor: $r('sys.color.ohos_id_color_activated'),
                uncheckedBorderColor: $r('sys.color.comp_background_emphasize'),
                indicatorColor: $r('sys.color.comp_background_primary')
              })
              .width(24)
              .height(24)
              .onChange((isChecked: boolean) => {
                if (isChecked) {
                  this.shakeFloorIndex = idx;
                  this.isShowShakeSheet = false;
                }
              })
              .margin({ left: 16 })
          }
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .onClick(() => {
            this.shakeFloorIndex = idx;
            this.isShowShakeSheet = false;
          })
        }, (option: string, idx: number) => `sf_${idx}`)
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

  private getShakeFloorDesc(idx: number): string {
    switch (idx) {
      case 0: return '默认值。过滤轻微的 GPS 随机抖动，轨迹平滑，适合大部分日常场景。';
      case 1: return '加大过滤力度，显著减少漂移毛刺，但弯道处的轨迹可能略被拉直。';
      case 2: return '最强过滤，仅记录明显的位置变化，轨迹最平滑但细节损失较多。';
      default: return '';
    }
  }
}
