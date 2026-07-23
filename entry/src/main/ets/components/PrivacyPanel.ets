/**
 * PrivacyPanel.ets —— 隐私设置面板子组件
 *
 * 从 SettingPanel.privacyView 提取为独立路由页面，
 * 由设置半模态 Navigation 统一 push 转场（HdsNavDestination 提供标题栏与返回按钮），
 * 不再手绘标题栏、不再依赖 isShowPrivacy 状态切换。
 *
 * 布局规范（HarmonyOS Design）：
 *   - 设置项拆为独立卡片，卡片间距 12vp
 *   - 卡片圆角 16vp（RadiusL）
 *   - 卡片内边距 16vp（Padding_level8）
 *   - 屏幕边缘 16vp
 */

@Component
export struct PrivacyPanel {
  scroller: Scroller = new Scroller();
  @Link pushSwitchOn: boolean;

  build() {
    Scroll(this.scroller) {
      Column({ space: 12 }) {
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
    .edgeEffect(EdgeEffect.None)
    .scrollBar(BarState.Off)
    .width('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
