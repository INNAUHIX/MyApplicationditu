/**
 * SettingPanel.ets —— 通用设置面板子组件
 *
 * 承载夜间模式与通知开关。
 * 隐私设置已提取为独立路由页面 PrivacyPanel（由设置半模态 Navigation 统一 push 转场），
 * 本组件不再内嵌 if/else 页面切换。
 *
 * 布局规范（HarmonyOS Design）：
 *   - 设置项拆为独立卡片，卡片间距 12vp
 *   - 卡片圆角 16vp（RadiusL）
 *   - 卡片内边距 16vp（Padding_level8）
 *   - 屏幕边缘 16vp
 *   - 半模态内容区使用 Scroll + nestedScroll 配合面板手势
 */

import { SymbolGlyphModifier } from '@kit.ArkUI';

@Component
export struct SettingPanel {
  scroller: Scroller = new Scroller();
  @Link nightModeIndex: number;
  @Link pushSwitchOn: boolean;

  onNightModeChange: (index: number) => void = () => {};

  private displayModeOptions: string[] = ['跟随系统', '普通模式', '夜间模式'];
  private checkMarkModifier: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.checkmark'))
    .fontSize('20vp')
    .fontColor([$r('sys.color.ohos_id_color_activated')]);

  build() {
    Scroll(this.scroller) {
      Column({ space: 12 }) {
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
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 })
    }
    .layoutWeight(1)
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.None)
    .scrollBar(BarState.Off)
    .width('100%')
    .backgroundColor($r('sys.color.background_secondary'))
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
