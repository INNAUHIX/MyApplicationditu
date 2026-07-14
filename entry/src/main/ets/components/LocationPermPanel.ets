/**
 * LocationPermPanel.ets —— 定位权限面板子组件
 *
 * 从 Mine.buildLocationSheet() 提取的独立 @Component，
 * 承载三项定位权限状态展示与跳转操作。
 *
 * 布局规范（HarmonyOS Design）：
 *   - 权限项拆为独立卡片，卡片间距 12vp
 *   - 卡片圆角 16vp（RadiusL）
 *   - 卡片内边距 16vp（Padding_level8）
 *   - 屏幕边缘 16vp
 *   - 半模态内容区使用 Scroll + nestedScroll 配合面板手势
 */

import { PermissionService } from '../service/PermissionService';
import { common } from '@kit.AbilityKit';

@Component
export struct LocationPermPanel {
  permSvc: PermissionService = new PermissionService();

  @Link hasApproximatelyLocation: boolean;
  @Link hasLocation: boolean;
  @Link hasBackgroundLocation: boolean;
  onRefreshPermission: () => void = () => {};

  build() {
    Scroll() {
      Column({ space: 12 }) {
        // 大致位置
        Row() {
          Column({ space: 6 }) {
            Text('大致位置')
              .fontSize(16)
              .fontColor($r('sys.color.font_primary'))
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Start)
            Text('允许 App 获取您所在的城市 / 街区级别大致位置')
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Row() {
            Text(this.hasApproximatelyLocation ? '已授权' : '未授权')
              .fontSize(14)
              .fontColor(this.hasApproximatelyLocation ? $r('sys.color.ohos_id_color_activated') : $r('sys.color.ohos_id_color_warning'))
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(24)
              .fontColor([$r('sys.color.font_fourth')])
              .margin({ left: 4 })
          }
          .justifyContent(FlexAlign.End)
        }
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .onClick(() => {
          this.handlePermissionClick('approximately');
        })

        // 精确位置
        Row() {
          Column({ space: 6 }) {
            Text('精确位置')
              .fontSize(16)
              .fontColor($r('sys.color.font_primary'))
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Start)
            Text('允许 App 获取精确 GPS 位置，用于地图标注与轨迹记录')
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Row() {
            Text(this.hasLocation ? '已授权' : '未授权')
              .fontSize(14)
              .fontColor(this.hasLocation ? $r('sys.color.ohos_id_color_activated') : $r('sys.color.ohos_id_color_warning'))
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(24)
              .fontColor([$r('sys.color.font_fourth')])
              .margin({ left: 4 })
          }
          .justifyContent(FlexAlign.End)
        }
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .onClick(() => {
          this.handlePermissionClick('location');
        })

        // 后台定位
        Row() {
          Column({ space: 6 }) {
            Text('后台定位')
              .fontSize(16)
              .fontColor($r('sys.color.font_primary'))
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Start)
            Text('允许 App 在后台持续获取位置，用于后台轨迹记录')
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Row() {
            Text(this.hasBackgroundLocation ? '已授权' : '未授权')
              .fontSize(14)
              .fontColor(this.hasBackgroundLocation ? $r('sys.color.ohos_id_color_activated') : $r('sys.color.ohos_id_color_warning'))
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(24)
              .fontColor([$r('sys.color.font_fourth')])
              .margin({ left: 4 })
          }
          .justifyContent(FlexAlign.End)
        }
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .onClick(() => {
          this.handlePermissionClick('background');
        })

        // 前往系统设置
        Row() {
          Column({ space: 6 }) {
            Text('前往系统设置')
              .fontSize(16)
              .fontColor($r('sys.color.font_primary'))
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Start)
            Text('若以上权限未授权或被拒绝，可在此前往系统设置手动开启')
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(24)
              .fontColor([$r('sys.color.font_fourth')])
          }
          .justifyContent(FlexAlign.End)
        }
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .onClick(() => {
          const ctx = getContext(this) as common.UIAbilityContext;
          this.permSvc.openPermissionSettings(ctx);
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 })
    }
    .layoutWeight(1)
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    .nestedScroll({
      scrollForward: NestedScrollMode.PARENT_FIRST,
      scrollBackward: NestedScrollMode.SELF_FIRST
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  private handlePermissionClick(type: string): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    if (type === 'approximately' && !this.hasApproximatelyLocation) {
      this.permSvc.requestPermissions(ctx).then((state) => {
        this.hasApproximatelyLocation = state.hasApproximatelyLocation;
        this.hasLocation = state.hasLocation;
        this.hasBackgroundLocation = state.hasBackgroundLocation;
        this.onRefreshPermission();
      });
    } else if (type === 'location' && !this.hasLocation) {
      this.permSvc.requestPermissions(ctx).then((state) => {
        this.hasApproximatelyLocation = state.hasApproximatelyLocation;
        this.hasLocation = state.hasLocation;
        this.hasBackgroundLocation = state.hasBackgroundLocation;
        this.onRefreshPermission();
      });
    } else if (type === 'background' && !this.hasBackgroundLocation) {
      this.getUIContext().getPromptAction().showDialog({
        title: '开启后台定位',
        message: '请在设置中将定位权限改为"始终允许"，以支持后台持续记录轨迹。',
        buttons: [
          { text: '取消', color: '#999999' },
          { text: '前往设置', color: '#007DFF' }
        ]
      }).then((result) => {
        if (result.index === 1) {
          this.permSvc.openPermissionSettings(ctx);
        }
      }).catch(() => {});
    } else {
      this.permSvc.openPermissionSettings(ctx);
    }
  }
}
