/**
 * StatsTab.ets —— 统计 Tab 组件
 *
 * 从 Index 拆出的独立 Tab 组件，承载足迹统计页面：
 *   - 华为官方 Navigation 标题栏 + List 列表
 *   - 累计里程 / 足迹点 / 记录天数 指标卡片
 *   - 平均每日里程 / 最长单日里程 / 首次记录 / 最近记录

 *   - 最近 7 天每日里程与点数分布
 *   - 当前视图可见集汇总（里程 + 足迹点）
 */

import { TimeViewModel } from '../viewmodel/TimeViewModel';
import {
  StatDayItem,
  TIME_VIEW_OVERVIEW,
  TIME_VIEW_CUSTOM
} from '../model/TrackTypes';
import { computeStats as computeStatsUtil, formatDistance, formatStatDate } from '../common/TrackUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG_LOG: string = 'StatsTab';

@Component
export struct StatsTab {
  // 服务实例（由 Index 传入，共享同一实例）
  timeModel: TimeViewModel = new TimeViewModel();

  // 布局参数
  @Prop navBarHeight: number = 0;
  @Prop statusBarHeight: number = 0;

  // 跨 Tab 双向状态
  @Link trackCount: number;
  @Link totalDistance: number;

  @Link timeViewIndex: number;

  // 统计内部状态
  @State statTotalDistance: number = 0;
  @State statTrackCount: number = 0;
  @State statActiveDays: number = 0;
  @State statAvgDailyDist: number = 0;
  @State statMaxDailyDist: number = 0;
  @State statFirstTs: number = 0;
  @State statLastTs: number = 0;
  @State statRecent7: StatDayItem[] = [];

  // T026: 统计计算（Tab 切入时由 Index 触发，或组件 aboutToAppear 自动执行）
  computeStats(): void {
    const result = computeStatsUtil(this.timeModel.allPoints);
    this.statTotalDistance = result.totalDistance;
    this.statTrackCount = result.trackCount;
    this.statActiveDays = result.activeDays;
    this.statAvgDailyDist = result.avgDailyDist;
    this.statMaxDailyDist = result.maxDailyDist;
    this.statFirstTs = result.firstTs;
    this.statLastTs = result.lastTs;
    this.statRecent7 = result.recent7;
  }

  aboutToAppear(): void {
    this.computeStats();
  }

  build() {
    Navigation() {
      List() {
        if (this.statTrackCount === 0) {
          ListItem() {
            Column() {
              Text('暂无足迹数据')
                .fontSize(14)
                .fontColor($r('sys.color.font_primary'))
                .opacity(0.5)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 40, bottom: 40 })
          }
        } else {
          ListItem() {
            Row({ space: 12 }) {
              Column({ space: 4 }) {
                Text(`${(this.statTotalDistance / 1000).toFixed(2)}`)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('sys.color.font_primary'))
                Text('累计里程')
                  .fontSize(12)
                  .fontColor($r('sys.color.font_primary'))
                  .opacity(0.6)
              }
              .layoutWeight(1)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(16)
              .padding(16)
              .alignItems(HorizontalAlign.Center)

              Column({ space: 4 }) {
                Text(`${this.statTrackCount}`)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('sys.color.font_primary'))
                Text('足迹点')
                  .fontSize(12)
                  .fontColor($r('sys.color.font_primary'))
                  .opacity(0.6)
              }
              .layoutWeight(1)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(16)
              .padding(16)
              .alignItems(HorizontalAlign.Center)

              Column({ space: 4 }) {
                Text(`${this.statActiveDays}`)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('sys.color.font_primary'))
                Text('记录天数')
                  .fontSize(12)
                  .fontColor($r('sys.color.font_primary'))
                  .opacity(0.6)
              }
              .layoutWeight(1)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(16)
              .padding(16)
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .margin({ bottom: 16 })
          }

          ListItem() {
            Column({ space: 12 }) {
              Row({ space: 12 }) {
                this.buildStatItem(formatDistance(this.statAvgDailyDist), '平均每日里程')
                this.buildStatItem(formatDistance(this.statMaxDailyDist), '最长单日里程')
              }
              .width('100%')

              Row({ space: 12 }) {
                this.buildStatItem(formatStatDate(this.statFirstTs), '首次记录')
                this.buildStatItem(formatStatDate(this.statLastTs), '最近记录')
              }
              .width('100%')
            }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(16)
            .padding(16)
            .margin({ bottom: 16 })
          }

          ListItem() {

            Column({ space: 10 }) {
              Text('最近 7 天')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .width('100%')

              ForEach(this.statRecent7, (item: StatDayItem) => {
                Column({ space: 4 }) {
                  Row() {
                    Text(item.label)
                      .fontSize(12)
                      .fontColor($r('sys.color.font_primary'))
                      .opacity(0.7)
                    Blank()
                    Text(`${item.count} 点 · ${formatDistance(item.distance)}`)
                      .fontSize(12)
                      .fontColor($r('sys.color.font_primary'))
                      .opacity(0.7)
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.SpaceBetween)

                  Row() {
                    Column()
                      .width(this.statMaxDailyDist > 0
                        ? `${Math.min(100, (item.distance / this.statMaxDailyDist) * 100)}%`
                        : '0%')
                      .height(6)
                      .backgroundColor($r('sys.color.ohos_id_color_activated'))
                      .borderRadius(3)
                    Blank()
                  }
                  .width('100%')
                  .height(6)
                  .backgroundColor($r('sys.color.ohos_id_color_activated'))
                  .opacity(0.15)
                  .borderRadius(3)
                }
                .width('100%')
              }, (item: StatDayItem) => item.label)
            }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(16)
            .padding(16)
            .margin({ bottom: 16 })
          }

          ListItem() {
            Column({ space: 8 }) {
              Text(this.timeViewIndex === TIME_VIEW_OVERVIEW ? '当前视图（总览）'
                : this.timeViewIndex === TIME_VIEW_CUSTOM ? '当前视图（自定义）' : '当前视图（今日）')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .width('100%')

              Row({ space: 12 }) {
                Column({ space: 2 }) {
                  Text(formatDistance(this.totalDistance))
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                  Text('里程')
                    .fontSize(12)
                    .fontColor($r('sys.color.font_primary'))
                    .opacity(0.6)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)

                Column({ space: 2 }) {
                  Text(`${this.trackCount}`)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                  Text('足迹点')
                    .fontSize(12)
                    .fontColor($r('sys.color.font_primary'))
                    .opacity(0.6)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
              }
              .width('100%')
            }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(16)
            .padding(16)
            .margin({ bottom: 16 })
          }
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, bottom: this.navBarHeight + 96 })
      .backgroundColor($r('sys.color.background_secondary'))
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
    }
    .title('足迹统计', { backgroundColor: $r('sys.color.background_secondary') })
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .padding({ top: this.statusBarHeight })
    .backgroundColor($r('sys.color.background_secondary'))
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
  }

  // 统计面板内的单行指标
  @Builder
  private buildStatItem(value: string, label: string): void {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      Text(label)
        .fontSize(12)
        .fontColor($r('sys.color.font_primary'))
        .opacity(0.6)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }
}
