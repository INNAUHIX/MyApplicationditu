import { AppStorageV2 } from '@kit.ArkUI';
import { CommonConstants } from '../constants/CommonConstants';
import { FontModel } from '../models/FontModel';
import { ToastDialog as promptAction } from '@hw-agconnect/ui-toast';

@ComponentV2
export struct LogoutBtn {
  @Once @Param visible: boolean = false;
  @Event signOutApi: () => Promise<void> = () => new Promise((resolve) => resolve());
  @Local isLoading: boolean = false;
  @Local fontModel: FontModel = AppStorageV2.connect(FontModel, () => new FontModel())!;

  build() {
    Column() {
      Button() {
        Row({ space: CommonConstants.SPACE_XS }) {
          LoadingProgress()
            .width(16)
            .aspectRatio(1)
            .color($r('sys.color.icon_secondary'))
            .visibility(this.isLoading ? Visibility.Visible : Visibility.None)
          Text(this.signOutBtnLabel)
            .fontSize(this.fontModel.getFg(16))
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .maxFontScale(2)
        }
      }
      .width(CommonConstants.FULL_PERCENT)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .padding({ top: CommonConstants.PADDING_M, bottom: CommonConstants.PADDING_M })
      .enabled(!this.isLoading)
      .onClick(() => {
        this.onSignOutBtnClick();
      })
    }
    .visibility(this.visible ? Visibility.Visible : Visibility.None)
    .margin({ top: CommonConstants.PADDING_L })
  }

  onSignOutBtnClick() {
    promptAction.showToast({ message: '功能不可用' });
  }

  @Computed
  get signOutBtnLabel() {
    return '退出登录'
  }
}
