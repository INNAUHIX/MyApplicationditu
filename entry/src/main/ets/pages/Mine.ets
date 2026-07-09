// 「我的」页面（独立组件，由 Index 的半模态面板承载）
// UI 样式与结构照搬参考项目 FitnessCenter 的「我的」页：
//   顶部视觉卡片 + 两组 CardItem 列表 + 白底圆角卡片 + 分隔线
// 仅保留视觉，不接入任何真实功能（登录 / 提交反馈 / 跳转二级页等均已删除）
//   - 设置：跳转到本项目自身的 SettingPage 二级页
//   - 其余菜单项：纯展示，无二级页、无真实触发逻辑

// NavPathStack 为 ArkUI 全局类型，无需显式 import（与 Index.ets 一致）

// 列表项：左图标 + 文字 + 右箭头，照搬参考项目 CardItem 布局
@Component
struct CardItem {
  label: ResourceStr = '';
  symbol: Resource = $r('sys.symbol.gearshape');
  onClickEvent: () => void = () => {};

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
      Image($r('app.media.ic_arrow_right'))
        .width(16)
        .height(16)
        .fillColor('#99000000')
        .margin({ right: 12 })
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
  // 由 Index 半模态的 Navigation 栈传入，用于「设置」跳转
  pathStack: NavPathStack = new NavPathStack();

  // 顶部视觉卡片：头像 + 未登录占位，不接入真实登录
  @Builder
  topProfileCard() {
    Row() {
      Image($r('app.media.default_avatar'))
        .width(48)
        .height(48)
        .backgroundColor(Color.White)
        .borderRadius(48)
        .draggable(false)
        .margin({ right: 16 })
      Column() {
        Text('未登录')
          .fontWeight(FontWeight.Medium)
          .fontSize(18)
          .fontColor('#e6000000')
          .margin({ right: 8 })
        Text('登录后享受更多服务')
          .fontSize(12)
          .fontColor('#e6000000')
      }
      .layoutWeight(1)
      .height(48)
      .alignItems(HorizontalAlign.Start)
      Image($r('app.media.ic_arrow_right'))
        .width(16)
        .height(16)
        .fillColor('#99000000')
        .draggable(false)
    }
    .width('100%')
    .backgroundColor(Color.White)
    .borderRadius(16)
    .padding(12)
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 12 })
    .onClick(() => {
      // 视觉卡片，不接入真实登录
    })
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        this.topProfileCard()

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
              CardItem({ label: '我的课程', symbol: $r('sys.symbol.book') })
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
                  this.pathStack.pushPathByName('SettingPage', null);
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
