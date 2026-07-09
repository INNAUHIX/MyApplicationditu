import { common } from '@kit.AbilityKit';
import { ToastDialog as promptAction } from '@hw-agconnect/ui-toast';
import { BaseViewModel } from '../models/BaseViewModel';
import { SettingItem, SettingGroup } from '../types/SettingItem';
import { SettingPageEnum, SettingType, SupportedSetting } from '../types/SettingType';
import { AboutModel, AgreementModel, IFontModel, WebModel } from '../models/CustomConfigModel';
import { lightDarkOptions } from '../constants/LightDarkOptions';

const TAG = '[SettingViewModel]';

@ObservedV2
export class SettingViewModel extends BaseViewModel {
  @Trace settingList: SettingGroup[] = [];
  @Trace callbackId: number = 0;
  public uiContext: UIContext | null = null;
  public context: common.UIAbilityContext | null = null;

  handleSettingList(list: SettingGroup[]) {
    this.settingList = list;
    this.settingList.forEach((v: SettingGroup) => {
      v.list.forEach(async (item: SettingItem) => {
        switch (item.supportedType) {
          case SupportedSetting.PRIVACY:
            this.handlePrivacy(item);
            break;
          case SupportedSetting.PUSH_SWITCH:
            this.handlePush(item);
            break;
          case SupportedSetting.CLEAR_CACHE:
            this.handleCache(item);
            break;
          case SupportedSetting.LIGHT_DARK_MODE:
            this.handleDark(item);
            break;
          case SupportedSetting.FONT_SIZE:
            this.handleFont(item);
            break;
          case SupportedSetting.CHECK_VERSION:
            this.handleVersionCheck(item);
            break;
          case SupportedSetting.ABOUT:
            this.handleAbout(item);
            break;
          case SupportedSetting.WEB:
            this.handleWeb(item);
            break;
        }
      })
    })
  }

  handlePrivacy(item: SettingItem) {
    item.setType(SettingType.ROUTER)
      .setLabel(item.label ?? '隐私设置')
      .setRouterParam({ routerName: SettingPageEnum.SETTING_PRIVACY });
    this.handleGlobalAgreement(item.extraParams as AgreementModel);
  }

  handlePush(item: SettingItem) {
    item.setType(SettingType.SWITCH)
      .setLabel(item.label ?? '通知开关')
      .setSwitchValue(true)
      .setClickEvent(() => {
        promptAction.showToast({ message: '功能不可用' });
      })
  }

  async handleCache(item: SettingItem) {
    item.setType(SettingType.TEXT)
      .setLabel(item.label ?? '清理缓存')
      .setNormalText('0.00M')
      .setClickEvent(() => {
        promptAction.showToast({ message: '功能不可用' });
      })
  }

  handleDark(item: SettingItem) {
    item.setType(SettingType.SELECT)
      .setLabel(item.label ?? '夜间模式')
      .setSelectOptions(item.selectOptions ?? lightDarkOptions)
      .setSelectEvent((index: number) => {
        promptAction.showToast({ message: '功能不可用' });
      })
  }

  handleFont(item: SettingItem) {
    item.setType(SettingType.ROUTER)
      .setLabel(item.label ?? '字体大小')
      .setRouterParam({ routerName: SettingPageEnum.SETTING_FONT });
    this.handleGlobalFont(item.extraParams as IFontModel);
  }

  handleVersionCheck(item: SettingItem) {
    item.setType(SettingType.TEXT)
      .setLabel(item.label ?? '检测版本')
      .setClickEvent(() => {
        promptAction.showToast({ message: '功能不可用' });
      })
  }

  handleAbout(item: SettingItem) {
    item.setType(SettingType.ROUTER)
      .setLabel(item.label ?? '关于我们')
      .setRouterParam({ routerName: SettingPageEnum.SETTING_ABOUT });
    this.handleGlobalAbout(item.extraParams as AboutModel);
  }

  handleWeb(item: SettingItem) {
    item.setRouterParam({
      routerName: SettingPageEnum.SETTING_AGREEMENT,
      routerParams: (item.extraParams as WebModel).src,
    })
  }

  handleGlobalAgreement(agreementInfo: AgreementModel) {
    if (agreementInfo.userAgreement) {
      this.configInfo.agreementModel.userAgreement = agreementInfo.userAgreement;
    }
    if (agreementInfo.privacyPolicy) {
      this.configInfo.agreementModel.privacyPolicy = agreementInfo.privacyPolicy;
    }
    if (agreementInfo.thirtyItem) {
      this.configInfo.agreementModel.thirtyItem = agreementInfo.thirtyItem;
    }
    if (agreementInfo.personalCollection) {
      this.configInfo.agreementModel.personalCollection = agreementInfo.personalCollection;
    }
  }

  handleGlobalAbout(aboutModel: AboutModel) {
    if (aboutModel.icpText) {
      this.configInfo.aboutModel.icpText = aboutModel.icpText;
    }
    if (aboutModel.copyrightText) {
      this.configInfo.aboutModel.copyrightText = aboutModel.copyrightText;
    }
    if (aboutModel.hotline) {
      this.configInfo.aboutModel.hotline = aboutModel.hotline;
    }
  }

  handleGlobalFont(fontModel: IFontModel) {
    this.fontModel.followSystem = fontModel.followSystem ?? false;
    this.fontModel.fontSizeRatio = fontModel.fontSizeRatio ?? 1;
    this.fontModel.onChange = () => {
      fontModel.onChange?.(this.fontModel.followSystem, this.fontModel.fontSizeRatio,
        this.fontModel.sysFontSizeScale);
    };
  }

  getLatestPushStatus() {
  }

  getCache() {
    return Promise.resolve('0.00M');
  }

  onConfigurationUpdate(): void {
  }

  offConfigurationUpdate() {
  }
}
