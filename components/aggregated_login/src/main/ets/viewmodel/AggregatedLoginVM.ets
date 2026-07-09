import { common } from '@kit.AbilityKit';
import { PersistenceV2, promptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';

import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LoginChannelType, LoginErrorCode } from '../common/Constant';
import { ExtraInfo, LoginParams, NavParam, PrivacyContent } from '../model/Index';
import { ApiController, LoginEventDispatcher } from '../utils/Utils';
import { LoginSheetUtils } from '../utils/LoginSheetUtils';

@ObservedV2
export class AggregatedLoginVM {
  private static _instance: AggregatedLoginVM | null;
  @Trace isSelected: boolean = false;
  // 控制登录中不可点击协议和复选框的状态变量
  @Trace enableStatus: boolean = true;
  @Trace unionID: string = '';
  @Trace openID: string = '';
  @Trace authorizationCode: string | undefined = '';
  @Trace anonymousPhone: string = '';
  @Trace persistenceData: PersistenceData =
    PersistenceV2.connect(PersistenceData, 'PhoneData', () => new PersistenceData())!
  @Trace phoneNum: string = ''
  @Trace verifyCode: string = '';
  @Trace verifyCodeTime: number = 0;
  @Trace isLoading: boolean = false;
  @Trace timer: number = 0;
  isSheet: boolean = false;
  autoSheet: boolean = false;
  isPersistence: boolean = false;
  uiContext?: UIContext;

  @Trace apiController: ApiController = new ApiController(
    () => new Promise(() => {
    }), () => new Promise(() => {
  }), () => new Promise(() => {
  }));
  logTag: string = 'QuickLoginButtonComponent';
  domainId: number = 0x0000;
  obtainVerifyCode: () => Promise<void> = () => new Promise(() => {
  });


  public static getInstance(reCreate: boolean = false) {
    if (!AggregatedLoginVM._instance || reCreate) {
      AggregatedLoginVM._instance = new AggregatedLoginVM();
    }
    return AggregatedLoginVM._instance;
  }

  public static clearInstance() {
    AggregatedLoginVM._instance = null;
  }

  public resetInstance() {
    this.isSelected = false
    this.enableStatus = true
    this.phoneNum = ''
    this.verifyCode = ''
    this.verifyCodeTime = 0
    clearInterval(this.timer)
  }

  setValue(isSheet: boolean, autoSheet: boolean, isPersistence: boolean, apiController: ApiController,
    uiContext: UIContext, obtainVerifyCode: () => Promise<void>) {
    this.isSheet = isSheet;
    this.autoSheet = autoSheet;
    this.isPersistence = isPersistence;
    this.apiController = apiController;
    this.uiContext = uiContext;
    this.obtainVerifyCode = obtainVerifyCode;
  }

  wechatLogin(_extraInfo: ExtraInfo, _uiContext: UIContext) {
    try {
      this.uiContext?.getPromptAction().showToast({ message: '微信登录暂不可用' });
    } catch (error) {
      hilog.error(this.domainId, this.logTag,
        `Failed to showToast. Code is ${error.code}, Message is ${error.message}`);
    }
  }

  registerOnWXRespCallback() {
  }

  unregisterOnWXRespCallback() {
  }

  phoneLogin(pathStack: NavPathStack, paraPram: NavParam) {
    pathStack.pushPathByName('OtherLoginPage', paraPram);
  }


  /**
   * 点击登录按钮
   **/
  validateLogin(): boolean {
    if (this.verifyCode === '' || (this.isPersistence ? this.persistenceData.phoneNumber : this.phoneNum) === '') {
      try {
        this.uiContext?.getPromptAction().showToast({ message: '手机号或验证码不能为空！' })
      } catch (error) {
        hilog.error(this.domainId, this.logTag,
          `Failed to showToast. Code is ${error.code}, Message is ${error.message}`);
      }
      return false
    }
    if (!/^\d{6}$/.test(this.verifyCode)) {
      try {
        this.uiContext?.getPromptAction().showToast({ message: '验证码不正确！' })
      } catch (error) {
        hilog.error(this.domainId, this.logTag,
          `Failed to showToast. Code is ${error.code}, Message is ${error.message}`);
      }
      return false
    }
    if (!/^1[3-9]\d{9}$/.test(this.isPersistence ? this.persistenceData.phoneNumber : this.phoneNum)) {
      try {
        this.uiContext?.getPromptAction().showToast({ message: '手机号码不正确！' })
      } catch (error) {
        hilog.error(this.domainId, this.logTag,
          `Failed to showToast. Code is ${error.code}, Message is ${error.message}`);
      }
      return false
    }
    return true
  }

  /**
   * 点击登录按钮
   **/
  clickLogInButton(): void {
    if (!this.isSelected) {
      try {
        this.uiContext?.getPromptAction().showToast({ message: $r('app.string.select_the_agreement') });
      } catch (error) {
        hilog.error(this.domainId, this.logTag,
          `Failed to showToast. Code is ${error.code}, Message is ${error.message}`);
      }
      return;
    }
    if (!this.validateLogin()) {
      return
    }
    let loginParams: LoginParams = {
      phoneNumbers: this.isPersistence ? this.persistenceData.phoneNumber : this.phoneNum,
      verifyCode: this.verifyCode
    }
    this.isLoading = true
    this.apiController.verifyCode(loginParams).then(() => {
      this.isLoading = false
      if (this.isSheet && this.autoSheet) {
        LoginSheetUtils.close()
      }
    })
  }

  /**
   * 获取验证码计数
   **/
  getVerifyCode(): void {
    if ((this.isPersistence ? this.persistenceData.phoneNumber : this.phoneNum) === '' ||
      !/^1[3-9]\d{9}$/.test(this.isPersistence ? this.persistenceData.phoneNumber : this.phoneNum)) {
      try {
        this.uiContext?.getPromptAction().showToast({ message: '请输入正确的手机号' })
      } catch (error) {
        hilog.error(this.domainId, this.logTag,
          `Failed to showToast. Code is ${error.code}, Message is ${error.message}`);
      }
    } else {
      this.obtainVerifyCode().then(() => {
        this.verifyCodeTime = 60;
        this.timer = setInterval(() => {
          this.verifyCodeTime--;
          if (!this.verifyCodeTime) {
            clearInterval(this.timer)
          }
        }, 1000)
      })
    }
  }

  agreePrivacyChange(_value: boolean) {
  }

  getQuickLoginAnonymousPhone() {
    this.anonymousPhone = '183******12';
  }

  generatePrivacyText(_dynamicContents: PrivacyContent[]): object[] {
    return [];
  }
  }

  getQuickLoginAnonymousPhone() {
    // 创建授权请求，并设置参数
    const authRequest = new authentication.HuaweiIDProvider().createAuthorizationWithHuaweiIDRequest();
    // 获取匿名手机号需传quickLoginAnonymousPhone这个scope，传参之前需要先申请“华为账号一键登录”权限
    authRequest.scopes = ['quickLoginAnonymousPhone'];
    // 获取code需传如下permission
    authRequest.permissions = ['serviceauthcode'];
    // 用于防跨站点请求伪造
    authRequest.state = util.generateRandomUUID();
    // 一键登录场景该参数必须设置为false
    authRequest.forceAuthorization = false;
    const controller = new authentication.AuthenticationController();
    try {
      controller.executeRequest(authRequest).then((response: authentication.AuthorizationWithHuaweiIDResponse) => {
        // 获取到UnionID、OpenID、匿名手机号
        this.unionID = response.data?.unionID ?? '';
        this.openID = response.data?.openID ?? '';
        this.authorizationCode = response.data!.authorizationCode;
        const anonymousPhone = response.data?.extraInfo?.quickLoginAnonymousPhone as string;
        if (anonymousPhone) {
          hilog.info(this.domainId, this.logTag, 'Succeeded in authentication.');
          this.anonymousPhone = anonymousPhone;
          return;
        }
        hilog.info(this.domainId, this.logTag, 'Succeeded in authentication. AnonymousPhone is empty.');
      }).catch((error: BusinessError) => {
        // todo 以下内容配置好可用的调试证书和client_id后删除，当前为模拟数据
        this.unionID = util.generateRandomUUID();
        this.openID = util.generateRandomUUID();
        this.anonymousPhone = '183******12';
        hilog.error(this.domainId, this.logTag,
          `Failed to execute request. Code is ${error.code}, Message is ${error.message}`);
      });
    } catch (error) {
      hilog.info(this.domainId, 'testTag', 'quick login failed ' + JSON.stringify(error));
    }
  }

  generatePrivacyText(dynamicContents: PrivacyContent[]): loginComponentManager.PrivacyText[] {
    const privacyText: loginComponentManager.PrivacyText[] = [];

    // 添加固定文本“已同意并阅读 ”
    privacyText.push(this.fixedTexts[0]);

    // 添加动态协议内容
    dynamicContents.forEach((content, index) => {
      // 添加协议名称为RICH_TEXT类型，包含链接
      privacyText.push({
        text: content.privacyLabel,
        type: loginComponentManager.TextType.RICH_TEXT,
        tag: content.privacyTag,
      });

      // 添加“ 和 ”
      if (dynamicContents.length > 1) {
        if (index === dynamicContents.length - 2) {
          privacyText.push(this.fixedTexts[1]);
        }
      }
    });
    return privacyText;
  }

  resetParam() {
    clearInterval(this.timer)
    this.verifyCodeTime = 0
    this.phoneNum = ''
    this.verifyCode = ''
  }


  // 处理点击一键登录后的方法。
  private handleLoginWithHuaweiIDButton(_error: BusinessError | undefined,
    _response?: object) {
  }
}

@ObservedV2
class PersistenceData {
  @Trace phoneNumber: string = ''
}