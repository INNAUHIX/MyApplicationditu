@ComponentV2
export struct ChooseAvatar {
  @Param url: ResourceStr = '';
  @Param avatarH: Length = 48;
  @Event onChooseAvatar: (url: string) => void;

  build() {
    Button({ type: ButtonType.Normal }) {
      Image(this.url)
        .width(this.avatarH)
        .height(this.avatarH)
        .borderRadius('50%')
        .alt('#0A59F7')
    }
    .width(this.avatarH)
    .height(this.avatarH)
    .borderRadius('50%')
    .backgroundColor('#0A59F7')
    .onClick(() => {
      this.getUIContext().getPromptAction().showToast({ message: '暂不可用' });
    })
  }
}
