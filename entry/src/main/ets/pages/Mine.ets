// 「我的」页面（独立组件，由 Index 的半模态面板承载）
// UI 样式与结构照搬参考项目 FitnessCenter 的「我的」页：
//   顶部视觉卡片 + 两组 CardItem 列表 + 白底圆角卡片 + 分隔线
// 仅保留视觉，不接入任何真实功能（登录 / 提交反馈 / 跳转二级页等均已删除）
//   - 设置：打开本项目独立的「设置」半模态面板
//   - 其余菜单项：纯展示，无二级页、无真实触发逻辑

// NavPathStack 为 ArkUI 全局类型，无需显式 import（与 Index.ets 一致）

// 列表项：左图标 + 文字 + 右箭头，照搬参考项目 CardItem 布局
@Component
struct CardItem {
  label: ResourceStr = '';
  symbol: Resource = $r('sys.symbol.gearshape');
  onClickEvent: () => void = () => {};
  statusText: ResourceStr = '';
  statusColor: ResourceStr = '#F44336';

  build() {
    Row() {
      Row() {
        SymbolGlyph(this.symbol)
          .fontSize(24)
          .fontColor(['#e6000000'])
          .margin({ left: 12 })
        Text(this.label)
          .fontSize(16)
          .fontColor('#e6000000')
          .margin({ left: 12 })
      }
      Row() {
        if (this.statusText) {
          Text(this.statusText)
            .fontSize(13)
            .fontColor(this.statusColor)
            .margin({ right: 8 })
        }
        Image($r('app.media.ic_arrow_right'))
          .width(16)
          .height(16)
          .fillColor('#99000000')
          .margin({ right: 12 })
      }
    }
    .width('100%')
    .height(56)
    .padding({ top: 14, bottom: 14 })
    .justifyContent(FlexAlign.SpaceBetween)
    .onClick(() => {
      this.onClickEvent?.();
    })
  }
}

@Component
export struct Mine {
  // 点击「设置」时由 Index 打开独立的设置半模态面板
  onSettingClick: () => void = () => {};
  // 点击「定位权限」时由 Index 跳转到系统定位权限设置页
  onLocationPermissionClick: () => void = () => {};
  // 定位权限是否异常（无前台定位能力），用于在「定位权限」项右侧提示红色文案
  locationAbnormal: boolean = false;

  build() {
    Scroll() {
      Column({ space: 16 }) {
        // 第一组：我的卡项 / 预约记录 / 我的课程 / 我的订单
        Column() {
          List() {
            ListItem() {
              CardItem({ label: '我的卡项', symbol: $r('sys.symbol.creditcard') })
            }
            ListItem() {
              CardItem({ label: '预约记录', symbol: $r('sys.symbol.calendar') })
            }
            ListItem() {
              CardItem({
                label: '定位权限',
                symbol: $r('sys.symbol.position_badge_exclamationmark'),
                statusText: this.locationAbnormal ? '权限异常' : '',
                statusColor: '#F44336',
                onClickEvent: () => {
                  this.onLocationPermissionClick();
                }
              })
            }
            ListItem() {
              CardItem({ label: '我的订单', symbol: $r('sys.symbol.bag') })
            }
          }
          .width('100%')
          .divider({
            strokeWidth: '1px',
            color: $r('sys.color.comp_divider'),
            startMargin: 28,
            endMargin: 28
          })
        }
        .borderRadius(20)
        .backgroundColor(Color.White)

        // 第二组：意见反馈 / 设置（设置跳本项目自身二级页）
        Column() {
          List() {
            ListItem() {
              CardItem({ label: '意见反馈', symbol: $r('sys.symbol.doc_plaintext_and_pencil') })
            }
            ListItem() {
              CardItem({
                label: '设置',
                symbol: $r('sys.symbol.gearshape'),
                onClickEvent: () => {
                  this.onSettingClick();
                }
              })
            }
          }
          .width('100%')
          .divider({
            strokeWidth: '1px',
            color: $r('sys.color.comp_divider'),
            startMargin: 28,
            endMargin: 28
          })
        }
        .borderRadius(20)
        .backgroundColor(Color.White)
      }
      .margin({ bottom: 80 })
      .padding({ left: 16, right: 16, top: 12 })
    }
    .layoutWeight(1)
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
