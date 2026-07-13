/**
 * Mine.ets —— 「我的」Tab 组件（瘦身版）
 *
 * 从 1223 行瘦身至 ≤200 行，具体措施：
 *   - 移除全部占位/未实现功能项（字体大小/页面跳转/Web页面/关于我们/检测版本/
 *     我的订单/意见反馈/退出登录/自定义开关/自定义下拉）
 *   - 3 个半模态面板拆为独立 @Component 子组件
 *   - 策略实验室改为正常页面导航跳转
 */

import { RecordMode } from '../model/TrackTypes';
import { CardItem } from '../components/CardItem';
import { RecordModePanel } from '../components/RecordModePanel';
import { LocationPermPanel } from '../components/LocationPermPanel';
import { SettingPanel } from '../components/SettingPanel';
import { PermissionService } from '../service/PermissionService';

@Component
export struct Mine {
  // ===== 服务实例（由 Index 传入，共享同一实例）=====
  permSvc: PermissionService = new PermissionService();
  pageNavStack: NavPathStack = new NavPathStack();

  // ===== 实时业务状态（@Link 双向同步 Index 的 @State）=====
  @Link recordMode: RecordMode;
  @Link hasApproximatelyLocation: boolean;
  @Link hasLocation: boolean;
  @Link hasBackgroundLocation: boolean;
  @Link nightModeIndex: number;
  @Link shakeFloorIndex: number;
  @Link trackCount: number;

  // 内部状态：通知开关（用于设置面板 + 隐私设置 Toggle 绑定）
  @State pushSwitchOn: boolean = false;

  // ===== 动作回调 =====
  onClearTrack: () => void = () => {};
  onRefreshPermission: () => void = () => {};
  onNightModeChange: (index: number) => void = () => {};
  onRecordModeChange: (mode: number) => void = () => {};

  recordModeNames: string[] = ['省电', '均衡', '耗电', '智能采样'];

  // 布局
  safeBottom: number = 80;

  // ===== 面板显隐 =====
  @State isShowRecordMode: boolean = false;
  @State isShowLocation: boolean = false;
  @State isShowSetting: boolean = false;

  // 综合判断：三档位置权限是否异常
  private isLocationAbnormal(): boolean {
    return !(this.hasApproximatelyLocation && this.hasLocation && this.hasBackgroundLocation);
  }

  build() {
    Navigation() {
      Scroll() {
      Column({ space: 16 }) {
        // 第一组：定位模式 / 策略实验室 / 定位权限
        Column() {
          Column() {
            CardItem({
              label: '记录规则',
              symbol: $r('sys.symbol.local_badge_gearshape'),
              statusText: this.recordModeNames[this.recordMode],
              statusColor: $r('sys.color.font_secondary'),
              onClickEvent: () => { this.isShowRecordMode = true; }
            })
            Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
            CardItem({
              label: '策略实验室',
              symbol: $r('sys.symbol.person_shield_fill'),
              onClickEvent: () => { this.pageNavStack.pushPath({ name: 'StrategyLab' }); }
            })
            Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
            CardItem({
              label: '定位权限',
              symbol: $r('sys.symbol.position_badge_exclamationmark'),
              statusText: this.isLocationAbnormal() ? '权限异常' : '',
              statusColor: $r('sys.color.ohos_id_color_warning'),
              onClickEvent: () => {
                this.onRefreshPermission();
                this.isShowLocation = true;
              }
            })
            Divider().strokeWidth('1px').color($r('sys.color.comp_divider')).margin({ left: 48, right: 12 })
            CardItem({
              label: '日志记录',
              symbol: $r('sys.symbol.doc_text'),
              onClickEvent: () => { this.pageNavStack.pushPath({ name: 'LogRecords' }); }
            })
          }
          .width('100%')
        }
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))

        // 第二组：设置
        Column() {
          Column() {
            CardItem({
              label: '设置',
              symbol: $r('sys.symbol.gearshape'),
              onClickEvent: () => { this.isShowSetting = true; }
            })
          }
          .width('100%')
        }
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))

        // 三个半模态面板绑定宿主
        Column() {
          Column()
            .width(0)
            .height(0)
            .bindSheet($$this.isShowRecordMode, this.recordModeSheet(), {
              title: { title: '记录规则' }, height: SheetSize.LARGE, dragBar: true, showClose: true,
              onDisappear: () => { this.isShowRecordMode = false; }
            })
          Column()
            .width(0)
            .height(0)
            .bindSheet($$this.isShowLocation, this.locationSheet(), {
              title: { title: '定位权限' }, height: SheetSize.LARGE, dragBar: true, showClose: true,
              onDisappear: () => { this.isShowLocation = false; }
            })
          Column()
            .width(0)
            .height(0)
            .bindSheet($$this.isShowSetting, this.settingSheet(), {
              title: { title: '设置' }, height: SheetSize.LARGE, dragBar: true, showClose: true,
              onDisappear: () => { this.isShowSetting = false; }
            })
        }
        .width(0)
        .height(0)
      }
      .margin({ bottom: this.safeBottom })
      .padding({ left: 16, right: 16, top: 12 })
    }
    .layoutWeight(1)
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    }
    .title('我的')
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(true)
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  // ===== 面板 @Builder =====

  @Builder
  private recordModeSheet(): void {
    RecordModePanel({
      recordMode: $recordMode,
      onRecordModeChange: (mode: number) => { this.onRecordModeChange(mode); }
    })
  }

  @Builder
  private locationSheet(): void {
    LocationPermPanel({
      permSvc: this.permSvc,
      hasApproximatelyLocation: $hasApproximatelyLocation,
      hasLocation: $hasLocation,
      hasBackgroundLocation: $hasBackgroundLocation,
      onRefreshPermission: () => { this.onRefreshPermission(); }
    })
  }

  @Builder
  private settingSheet(): void {
    SettingPanel({
      nightModeIndex: $nightModeIndex,
      pushSwitchOn: $pushSwitchOn,
      trackCount: $trackCount,
      onClearTrack: () => { this.onClearTrack(); },
      onNightModeChange: (i: number) => { this.onNightModeChange(i); }
    })
  }
}
