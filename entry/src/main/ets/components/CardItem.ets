/**
 * CardItem.ets —— 通用列表项组件
 *
 * 从 Mine 内部提取的可复用列表项：左图标 + 文字 + 右侧状态文字/箭头
 * statusText 使用 @Prop 确保父组件状态变化时能同步更新显示
 */

@Component
export struct CardItem {
  label: ResourceStr = '';
  symbol: Resource = $r('sys.symbol.gearshape');
  onClickEvent: () => void = () => {};
  @Prop statusText: ResourceStr = '';
  statusColor: ResourceStr = $r('sys.color.ohos_id_color_warning');

  build() {
    Row() {
      Row() {
        SymbolGlyph(this.symbol)
          .fontSize(24)
          .fontColor([$r('sys.color.font_primary')])
          .margin({ left: 12 })
        Text(this.label)
          .fontSize(16)
          .fontColor($r('sys.color.font_primary'))
          .margin({ left: 12 })
      }
      Row() {
        if (this.statusText) {
          Text(this.statusText)
            .fontSize(13)
            .fontColor(this.statusColor)
            .margin({ right: 8 })
        }
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(24)
          .fontColor([$r('sys.color.font_fourth')])
          .margin({ right: 12 })
      }
    }
    .width('100%')
    .height(56)
    .padding({ top: 14, bottom: 14 })
    .justifyContent(FlexAlign.SpaceBetween)
    .onClick(() => {
      this.onClickEvent?.();
    })
  }
}
