
import { VersionModel } from '../model/Index';
import { AppStorageV2 } from '@kit.ArkUI';


@ObservedV2
export class AboutPageVM {
  @Trace currentVersion: string = '1.0.0.2';
  @Trace appId: string = 'xxxx';
  @Trace versionInfo: VersionModel = AppStorageV2.connect(VersionModel, () => new VersionModel())!;
  @Trace phoneNumber: string = '900800';
  private static _instance: AboutPageVM;

  public static get instance() {
    if (!AboutPageVM._instance) {
      AboutPageVM._instance = new AboutPageVM();
    }
    return AboutPageVM._instance;
  }

  checkUpDate(ctx: UIContext, _dialogController: CustomDialogController) {
    ctx.getPromptAction().showToast({ message: '暂不可用' });
  }

  showUpdateDialog(_ctx: UIContext, _dialogController: CustomDialogController) {
  }

  takePhone() {
  }
}