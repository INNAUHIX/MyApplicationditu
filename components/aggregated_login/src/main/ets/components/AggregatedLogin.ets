import { AgreePrivacyBox } from './AgreePrivacyBox';

interface PrivacyContent {
  privacyLabel: ResourceStr;
  privacyUrl: ResourceStr;
  privacyTag: string;
}

interface Channel {
  type: number;
  name: string;
  icon: ResourceStr;
  extraInfo: object;
}

const UI = {
  SHEET_TITLE_H: 56,
  MIN_HEIGHT_8: 8,
  ICON_WIDTH: 64,
  ICON_HEIGHT: 64,
  BTN_HEIGHT: 48,
  FONT_LINES: 1,
  CONTENT_MARGIN_TOP: 24,
  PADDING_S: 8,
  FULL_PERCENT: '100%',
  MAX_WIDTH: 360,
  PADDING_M: 16,
  PADDING_L: 24,
  WINDOW_BOTTOM_PADDING: 0,
  ZERO: 0,
  BACK_WIDTH: 20,
  BACK_BACKGROUND_WIDTH: 32,
  BACK_BACKGROUND_HEIGHT: 32,
};

@Builder
export function AggregatedLoginBuilder() {
  AggregatedLogin()
}

@ComponentV2
export struct AggregatedLogin {
  @Param icon: ResourceStr = '';
  @Param themeColor: ResourceColor = '#0A59F7';
  @Param isSheet: boolean = false;
  @Param privacyContent: PrivacyContent[] = [];
  @Param loginTypes: Channel[] = [];
  @Local anonymousPhone: string = '183******12';
  @Local isSelected: boolean = false;

  @Builder
  coreInfo() {
    Column() {
      Scroll() {
        Column() {
          if (this.isSheet) {
            Column().height(UI.SHEET_TITLE_H)
          } else {
            Column()
              .layoutWeight(1)
              .constraintSize({ minHeight: UI.MIN_HEIGHT_8 })
          }

          Image(this.icon)
            .width(UI.ICON_WIDTH)
            .height(UI.ICON_HEIGHT)

          Column() {
            Text(this.anonymousPhone)
              .fontSize($r('sys.float.Title_L'))
              .fontColor($r('sys.color.font_primary'))
              .fontWeight(FontWeight.Bold)
              .height(UI.BTN_HEIGHT)
              .textAlign(TextAlign.Center)
              .maxLines(UI.FONT_LINES);

            Text('华为账号绑定号码')
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_secondary'))
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Center)
              .maxLines(UI.FONT_LINES)
              .margin({ top: UI.PADDING_S });
          }
          .margin({ top: UI.CONTENT_MARGIN_TOP });

          Column() {
            Button('华为账号登录')
              .width(UI.FULL_PERCENT)
              .height(UI.BTN_HEIGHT)
              .constraintSize({ maxWidth: UI.MAX_WIDTH })
              .fontSize($r('sys.float.Body_L'))
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
              .backgroundColor(this.themeColor)
              .onClick(() => {
                this.getUIContext().getPromptAction().showToast({ message: '暂不可用' });
              });
          }
          .height(UI.BTN_HEIGHT)
          .width(UI.FULL_PERCENT)
          .constraintSize({ maxWidth: UI.MAX_WIDTH })
          .margin({ top: UI.SHEET_TITLE_H });

          Button($r('app.string.login_in_other'))
            .width(UI.FULL_PERCENT)
            .height(UI.BTN_HEIGHT)
            .constraintSize({ maxWidth: UI.MAX_WIDTH })
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .margin({ top: UI.PADDING_M })
            .onClick(() => {
              this.getUIContext().getPromptAction().showToast({ message: '暂不可用' });
            })

          Column().layoutWeight(3)
            .constraintSize({ minHeight: 12 })
        }
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      AgreePrivacyBox({
        themeColor: this.themeColor,
        privacyContent: this.privacyContent,
        isSelected: this.isSelected,
      })
        .padding({ top: UI.PADDING_M, bottom: UI.PADDING_M })
        .constraintSize({ maxWidth: UI.MAX_WIDTH })
        .height(UI.SHEET_TITLE_H)
        .width(UI.FULL_PERCENT)
    }
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('sys.color.background_secondary'))
    .padding({
      left: UI.PADDING_L, right: UI.PADDING_L,
      bottom: this.isSheet ? UI.WINDOW_BOTTOM_PADDING : UI.ZERO
    })
    .layoutWeight(1)
  }

  build() {
    Column() {
      if (!this.isSheet) {
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
            this.getUIContext().getPromptAction().showToast({ message: '暂不可用' });
          })
        }
        .padding({ left: UI.PADDING_L, right: UI.PADDING_L })
        .width(UI.FULL_PERCENT)
        .height(UI.SHEET_TITLE_H)
      }

      this.coreInfo()
    }
    .height(UI.FULL_PERCENT)
    .width(UI.FULL_PERCENT)
  }
}
