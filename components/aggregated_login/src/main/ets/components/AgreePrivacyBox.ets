import { hilog } from '@kit.PerformanceAnalysisKit';
import { AggregatedLoginVM } from '../viewmodel/AggregatedLoginVM';
import { Constants } from '../common/Constant';
import { PrivacyContent } from '../model/Index';

interface PrivacyTextItem {
  text?: string;
  type?: number;
  tag?: string;
}

@ComponentV2
export struct AgreePrivacyBox {
  @Local vm: AggregatedLoginVM = AggregatedLoginVM.getInstance(false);
  @Param themeColor: ResourceColor = '#0A59F7';
  @Param privacyContent: PrivacyContent[] = []
  @Param routerModule: NavPathStack = new NavPathStack()
  @Param isSheet: boolean = false;
  @Param sheetType: SheetType = SheetType.BOTTOM;
  selectedContent: PrivacyContent | undefined = new PrivacyContent()
  privacyText: PrivacyTextItem[] = []

  aboutToAppear(): void {
    this.privacyText = this.privacyContent.map(item => ({
      text: item.privacyLabel as string,
      type: 1,
      tag: item.privacyTag
    }));
  }

  build() {
    Row({ space: Constants.SPACE_M }) {
      Checkbox({ name: 'privacyCheckbox', group: 'privacyCheckboxGroup' })
        .width(Constants.BOX_WIDTH)
        .height(Constants.BOX_HEIGHT)
        .focusable(true)
        .focusOnTouch(true)
        .selectedColor(this.themeColor)
        .select(this.vm.isSelected)
        .enabled(this.vm.enableStatus)
        .onChange((value: boolean) => {
          hilog.info(0x0001, 'CheckBoxComponent', `agreementChecked: ${value}`);
          this.vm.agreePrivacyChange(value)
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
      .width(Constants.FULL_PERCENT)
    }
    .layoutWeight(1)
  }
}