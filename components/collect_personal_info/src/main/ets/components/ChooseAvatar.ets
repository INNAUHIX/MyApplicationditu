import { AppStorageV2 } from '@kit.ArkUI';
import { ConfigInfo } from '../common/ConfigModel';

@ComponentV2
export struct ChooseAvatar {
  @Param url: ResourceStr = '';
  @Param avatarH: Length = 48;
  @Event onChooseAvatar: (url: string) => void;
  @Local configInfo: ConfigInfo = AppStorageV2.connect(ConfigInfo, () => new ConfigInfo())!;

  build() {
    Button({ type: ButtonType.Normal }) {
      Image(this.url)
        .width(this.avatarH)
        .height(this.avatarH)
        .borderRadius('50%')
        .alt(this.configInfo.themeColor)
    }
    .width(this.avatarH)
    .height(this.avatarH)
    .borderRadius('50%')
    .backgroundColor(this.configInfo.themeColor)
    .onClick(() => {
      this.getUIContext().getPromptAction().showToast({ message: '暂不可用' });
    })
  }
}
