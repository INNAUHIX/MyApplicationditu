/**
 * SettingPanel.ets —— 设置面板子组件
 *
 * 从 Mine.buildSettingSheet() + privacyRootContent() 提取的独立 @Component。
 * 承载设置项列表 + 隐私设置二级视图切换。
 * 已移除占位项：字体大小、页面跳转、Web页面、关于我们、检测版本。
 *
 * 布局规范（HarmonyOS Design）：
 *   - 设置项拆为独立卡片，卡片间距 12vp
 *   - 卡片圆角 16vp（RadiusL）
 *   - 卡片内边距 16vp（Padding_level8）
 *   - 屏幕边缘 16vp
 *   - 半模态内容区使用 Scroll + nestedScroll 配合面板手势
 */

import { SymbolGlyphModifier } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG_LOG: string = 'SettingPanel';

@Component
export struct SettingPanel {
  @Link nightModeIndex: number;
  @Link pushSwitchOn: boolean;

  onNightModeChange: (index: number) => void = () => {};

  @State isShowPrivacy: boolean = false;
  private displayModeOptions: string[] = ['跟随系统', '普通模式', '夜间模式'];
  private checkMarkModifier: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.checkmark'))
    .fontSize('20vp')
    .fontColor([$r('sys.color.ohos_id_color_activated')]);

  build() {
    Column() {
      if (this.isShowPrivacy) {
        this.privacyView()
      } else {
        this.settingList()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private settingList(): void {
    Scroll() {
      Column({ space: 12 }) {
        // 夜间模式
        Row() {
          Column({ space: 6 }) {
            Text('夜间模式')
              .fontSize(16)
              .fontColor($r('sys.color.font_primary'))
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Row() {
            Text(this.displayModeOptions[this.nightModeIndex])
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
              .margin({ right: 4 })
            SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
              .fontSize(12)
              .fontColor([$r('sys.color.font_fourth')])
          }
          .justifyContent(FlexAlign.End)
          .bindMenu(this.nightMenu)
        }
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))

        // 通知开关
        Row() {
          Column({ space: 6 }) {
            Text('通知开关')
              .fontSize(16)
              .fontColor($r('sys.color.font_primary'))
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Row() {
            Toggle({ type: ToggleType.Switch, isOn: $$this.pushSwitchOn })
              .selectedColor($r('sys.color.ohos_id_color_warning'))
          }
          .justifyContent(FlexAlign.End)
        }
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))


        // 隐私设置
        Row() {
          Column({ space: 6 }) {
            Text('隐私设置')
              .fontSize(16)
              .fontColor($r('sys.color.font_primary'))
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(24)
              .fontColor([$r('sys.color.font_fourth')])
          }
          .justifyContent(FlexAlign.End)
        }
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .onClick(() => {
          this.isShowPrivacy = true;
        })
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

  // 「隐私设置」二级视图
  @Builder
  private privacyView(): void {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('sys.color.ohos_id_color_activated')])
          .margin({ left: 12 })
          .onClick(() => {
            this.isShowPrivacy = false;
          })
        Text('隐私设置')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .height(56)
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 12 }) {
          // 个性化推荐
          Row() {
            Column({ space: 6 }) {
              Text('个性化推荐')
                .fontSize(16)
                .fontColor($r('sys.color.font_primary'))
                .fontWeight(FontWeight.Medium)
                .textAlign(TextAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Row() {
              Toggle({ type: ToggleType.Switch, isOn: $$this.pushSwitchOn })
                .selectedColor($r('sys.color.ohos_id_color_warning'))
            }
            .justifyContent(FlexAlign.End)
          }
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          // 用户协议
          Row() {
            Column({ space: 6 }) {
              Text('用户协议')
                .fontSize(16)
                .fontColor($r('sys.color.font_primary'))
                .fontWeight(FontWeight.Medium)
                .textAlign(TextAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Row() {
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(24)
                .fontColor([$r('sys.color.font_fourth')])
            }
            .justifyContent(FlexAlign.End)
          }
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          // 隐私政策
          Row() {
            Column({ space: 6 }) {
              Text('隐私政策')
                .fontSize(16)
                .fontColor($r('sys.color.font_primary'))
                .fontWeight(FontWeight.Medium)
                .textAlign(TextAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Row() {
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(24)
                .fontColor([$r('sys.color.font_fourth')])
            }
            .justifyContent(FlexAlign.End)
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
      .backgroundColor($r('sys.color.background_secondary'))
    }
  }

  @Builder
  private nightMenu(): void {
    Menu() {
      ForEach(this.displayModeOptions, (option: string, idx: number) => {
        MenuItem({ content: option })
          .selected(this.nightModeIndex === idx)
          .selectIcon(this.checkMarkModifier)
          .onClick(() => {
            this.nightModeIndex = idx;
            this.onNightModeChange(idx);
          })
      }, (option: string, idx: number) => `nm_${idx}`)
    }
  }
}
