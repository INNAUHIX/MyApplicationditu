/**
 * MapToolSheet.ets —— 地图工具半模态面板子组件
 *
 * 从 FootprintTab.buildMapToolSheetContent() 提取的独立 @Component，
 * 承载轨迹切换 / 地图样式 / 我的位置 三个工具项。
 */

import {
  TIME_VIEW_OVERVIEW
} from '../model/TrackTypes';
import {
  SegmentButton,
  SegmentButtonOptions,
  ItemRestriction,
  SegmentButtonTextItem
} from '@kit.ArkUI';

@Component
export struct MapToolSheet {
  @Link displayMode: number;
  @Link mapStyleIndex: number;
  @Link myLocationOn: boolean;
  @Link timeViewIndex: number;
  @Link display2SelectedIndexes: number[];
  @Link mapStyle2SelectedIndexes: number[];
  onSwitchDisplayMode: (mode: number) => void = () => {};
  onSwitchMapStyle: (index: number) => void = () => {};
  onToggleMyLocation: (isOn: boolean) => void = () => {};

  @State display2SegmentOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [
      { text: '折线' },
      { text: '海量点' }
    ] as ItemRestriction<SegmentButtonTextItem>,
    selectedBackgroundColor: $r('sys.color.ohos_id_color_activated'),
    fontColor: $r('sys.color.font_secondary'),
    selectedFontColor: $r('sys.color.ohos_id_color_primary_contrary'),
    fontSize: 14,
    selectedFontSize: 14,
    fontWeight: FontWeight.Regular,
    selectedFontWeight: FontWeight.Medium,
    buttonPadding: { top: 10, right: 4, bottom: 10, left: 4 }
  });
  @State mapStyleSegmentOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [
      { text: '经典' },
      { text: '暗夜' },
      { text: '浅白' },
      { text: '测试' }
    ] as ItemRestriction<SegmentButtonTextItem>,
    selectedBackgroundColor: $r('sys.color.ohos_id_color_activated'),
    fontColor: $r('sys.color.font_secondary'),
    selectedFontColor: $r('sys.color.ohos_id_color_primary_contrary'),
    fontSize: 14,
    selectedFontSize: 14,
    fontWeight: FontWeight.Regular,
    selectedFontWeight: FontWeight.Medium,
    buttonPadding: { top: 10, right: 4, bottom: 10, left: 4 }
  });

  build() {
    Column() {
      Column() {
        Row() {
          Text('轨迹切换')
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
          Blank()
          SegmentButton({
            options: this.display2SegmentOptions,
            selectedIndexes: $display2SelectedIndexes,
            onItemClicked: (index: number) => {
              this.onSwitchDisplayMode(index);
            }
          })
          .width(220)
          .enabled(this.timeViewIndex !== TIME_VIEW_OVERVIEW)
          .opacity(this.timeViewIndex === TIME_VIEW_OVERVIEW ? 0.4 : 1)
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding({ top: 16, bottom: 16, left: 12, right: 12 })
      }
      .width('100%')
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(16)
      .margin({ bottom: 12 })

      Column() {
        Row() {
          Text('地图样式')
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
          Blank()
          SegmentButton({
            options: this.mapStyleSegmentOptions,
            selectedIndexes: $mapStyle2SelectedIndexes,
            onItemClicked: (index: number) => {
              this.onSwitchMapStyle(index);
            }
          })
          .width(200)
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding({ top: 16, bottom: 16, left: 12, right: 12 })
      }
      .width('100%')
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(16)
      .margin({ bottom: 12 })

      Column() {
        Row() {
          Text('我的位置')
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.myLocationOn })
            .onChange((isOn: boolean) => {
              this.myLocationOn = isOn;
              this.onToggleMyLocation(isOn);
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding({ top: 16, bottom: 16, left: 12, right: 12 })
      }
      .width('100%')
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(16)
      .margin({ bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
