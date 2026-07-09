interface PrivacyTextItem {
  text?: string;
  type?: number;
  tag?: string;
}

interface PrivacyContent {
  privacyLabel: ResourceStr;
  privacyUrl: ResourceStr;
  privacyTag: string;
}

@ComponentV2
export struct AgreePrivacyBox {
  @Param themeColor: ResourceColor = '#0A59F7';
  @Param privacyContent: PrivacyContent[] = []
  @Param isSelected: boolean = false;
  @Local privacyText: PrivacyTextItem[] = []

  aboutToAppear(): void {
    this.privacyText = this.privacyContent.map(item => ({
      text: item.privacyLabel as string,
      type: 1,
      tag: item.privacyTag
    }));
  }

  build() {
    Row({ space: 8 }) {
      Checkbox({ name: 'privacyCheckbox', group: 'privacyCheckboxGroup' })
        .width(16)
        .height(16)
        .focusable(true)
        .focusOnTouch(true)
        .selectedColor(this.themeColor)
        .select(this.isSelected)
        .onChange((value: boolean) => {
          this.isSelected = value;
        });

      this.buildSelectView(this.themeColor)
    }
  }

  @Builder
  buildSelectView(themeColor: ResourceColor) {
    Row() {
      Text() {
        Span('已同意并阅读 ')
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .fontWeight(FontWeight.Regular)
        ForEach(this.privacyText, (item: PrivacyTextItem) => {
          Span(item?.text ?? '')
            .fontSize($r('sys.float.Body_S'))
            .fontColor(themeColor)
            .fontWeight(FontWeight.Medium)
            .focusable(true)
            .focusOnTouch(true)
            .onClick(() => {
              this.getUIContext().getPromptAction().showToast({ message: '暂不可用' });
            })
        }, (item: PrivacyTextItem, index: number) => `${item.text}_${index}`)
      }
      .width('100%')
    }
    .layoutWeight(1)
  }
}
