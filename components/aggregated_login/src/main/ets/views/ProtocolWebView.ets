interface ProtocolRouterParams {
  content: string;
  isSheet?: boolean;
  sheetType?: SheetType;
}

const UI = {
  BACK_WIDTH: 20,
  BACK_BACKGROUND_WIDTH: 32,
  BACK_BACKGROUND_HEIGHT: 32,
  FULL_PERCENT: '100%',
  SPACE_S: 4,
  PADDING_L: 24,
  WINDOW_BOTTOM_PADDING: 0,
  ZERO: 0,
};

@Builder
export function ProtocolWebViewBuilder() {
  ProtocolWebView()
}

@ComponentV2
struct ProtocolWebView {
  @Local content: string = '';
  @Local isSheet: boolean = false;
  @Local sheetType: SheetType = SheetType.BOTTOM;
  stack: NavPathStack = new NavPathStack();

  @Computed
  get headerPaddingTop() {
    if (!this.isSheet) {
      return undefined;
    }
    if (this.sheetType === SheetType.CENTER) {
      return UI.PADDING_L;
    }
    if (this.sheetType === SheetType.BOTTOM) {
      return UI.ZERO;
    }
    return 0;
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.chevron_backward'))
              .fontColor([$r('sys.color.icon_primary')])
              .fontSize(UI.BACK_WIDTH)
          }
          .width(UI.BACK_BACKGROUND_WIDTH)
          .height(UI.BACK_BACKGROUND_HEIGHT)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .onClick(() => {
            this.stack.pop();
          })
        }
        .width(UI.FULL_PERCENT)
        .margin({ bottom: UI.SPACE_S })

        Scroll() {
          Text(this.content)
            .width('100%')
            .padding(16)
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
      .padding({
        left: UI.PADDING_L,
        right: UI.PADDING_L,
        bottom: this.isSheet ? UI.WINDOW_BOTTOM_PADDING : UI.ZERO,
        top: this.headerPaddingTop,
      })
      .height(UI.FULL_PERCENT)
      .width(UI.FULL_PERCENT)
      .backgroundColor($r('sys.color.background_secondary'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('sys.color.background_secondary'))
    .onReady((context) => {
      this.stack = context.pathStack;
      const params = context.pathInfo.param as ProtocolRouterParams;
      if (params) {
        this.content = params.content;
        this.isSheet = params.isSheet ?? false;
        this.sheetType = params.sheetType ?? SheetType.BOTTOM;
      }
    })
  }
}
