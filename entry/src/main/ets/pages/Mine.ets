// 「我的」页面（独立组件，由 Index 的「我的」整页承载）
//
// 三个二级面板（定位模式 / 定位权限 / 设置）+ 策略实验室，均通过组件内自带 @Builder + bindSheet 打开
// （华为官方标准做法），不再依赖 Index 传入的 @BuilderParam——这样可避免「跨组件传 builder 引用 +
// 半模态渲染」导致的闪退，也去掉了面板内嵌 Navigation 与外层整页 Navigation 的无效套娃
// （面板标题改用 bindSheet 的 title 选项；设置面板的隐私二级页改为面板内 @State 视图切换）。
//
// 业务状态/动作通过 @Link（实时双向同步）/ 普通 props / 回调接入 Index，Mine 只负责视图。

import { RecordMode, RecordStrategyItem } from '../model/TrackTypes';
import { SymbolGlyphModifier } from '@kit.ArkUI';

// 列表项：左图标 + 文字 + 右箭头
@Component
struct CardItem {
  label: ResourceStr = '';
  symbol: Resource = $r('sys.symbol.gearshape');
  onClickEvent: () => void = () => {};
  statusText: ResourceStr = '';
  statusColor: ResourceStr = $r('sys.color.ohos_id_color_warning');

  build() {
    Row() {
      Row() {
        SymbolGlyph(this.symbol)
          .fontSize(24)
          .fontColor([$r('sys.color.font_primary')])
          .margin({ left: 12 })
        Text(this.label)
          .fontSize(16)
          .fontColor($r('sys.color.font_primary'))
          .margin({ left: 12 })
      }
      Row() {
        if (this.statusText) {
          Text(this.statusText)
            .fontSize(13)
            .fontColor(this.statusColor)
            .margin({ right: 8 })
        }
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(24)
          .fontColor([$r('sys.color.font_fourth')])
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
  // ===== 实时业务状态（@Link 双向同步 Index 的 @State）=====
  @Link recordMode: RecordMode;                      // 当前定位模式（= Index.currentMode）
  @Link hasApproximatelyLocation: boolean;           // 大致位置授权
  @Link hasLocation: boolean;                        // 精确位置授权
  @Link hasBackgroundLocation: boolean;              // 后台定位授权
  @Link nightModeIndex: number;                      // 地图日/夜间：0 跟随系统 /1 普通 /2 夜间
  @Link customSelectIndex: number;                   // 自定义下拉选择
  @Link pushSwitchOn: boolean;                       // 通知开关
  @Link customSwitchOn: boolean;                     // 自定义开关
  @Link trackCount: number;                          // 当前可见轨迹点数量
  @Link shakeFloorIndex: number;                     // 抖动地板阈值档位：0=5米，1=10米，2=15米

  // ===== 普通展示数据（Index 构造时一次性传入）=====
  safeBottom: number = 80;

  // 静态数据（从 Index 迁移，面板内展示用，不随运行变化）
  recordModeNames: string[] = ['省电', '平衡', '耗电'];
  recordModeDescs: string[] = [
    '定位间隔约60秒，精度门槛200米。采样最稀疏、最省电，适合长时间后台挂机、对轨迹精度要求不高的日常记录。',
    '定位间隔约15秒，精度门槛100米。精度与耗电均衡，推荐作为日常默认档位。',
    '定位间隔约5秒，精度门槛30米。采样最密集、轨迹最精细，但最费电，适合骑行 / 步行导航等需要细腻轨迹的场景。'
  ];
  recordStrategyItems: RecordStrategyItem[] = [
    { title: '静止降频', desc: '连续定位点均落在小范围内（≤15米）判定为静止，自动把定位间隔降到30秒或档位间隔的较大值省电；仅当明显远离（>30米）才视为真正移动并恢复档位间隔。' },
    { title: '漂移过滤', desc: '单点定位精度超出当前模式门槛（省电200米/平衡100米/耗电30米）时整体丢弃，不计入轨迹。' },
    { title: '静止不记', desc: '定位上报速度低于步行速度（约3.6km/h）时视为原地未动，不记录，避免静止漂移画蛇添足。' },
    { title: '抖动地板', desc: '与上一个折线点距离不足当前阈值视为原地抖动，直接丢弃，防止轨迹回绕。阈值可在策略实验室切换。' },
    { title: '足迹降密', desc: '海量点（足迹点）按各模式距离门槛抽样记录：省电≥200米、平衡≥50米、耗电≥20米才记一次，降低点数密度与渲染压力。' },
    { title: '批量落库', desc: '轨迹点先进缓冲，每8秒定时一次性写入数据库，降低存储写入频率。' },
    { title: '绘制节流', desc: '折线每新增50点、海量点每新增20点且最多每30秒刷新一次，避免高频重绘卡顿。' },
    { title: '实时连线', desc: '已确认折线末端实时连到你当前位置（仅过精度门槛、不入库），让红线始终延伸到脚下，消除停下时的终点断点与等待下一个确认点的空白。' }
  ];
  displayModeOptions: string[] = ['跟随系统', '普通模式', '夜间模式'];
  customSelectOptions: string[] = ['选项1', '选项2', '选项3'];
  shakeFloorOptions: string[] = ['5米', '10米', '15米'];

  // ===== 动作回调（回传 Index 执行真实逻辑）=====
  onRecordModeChange: (mode: number) => void = () => {};
  onRequestPermissions: () => void = () => {};
  onOpenPermissionSettings: () => void = () => {};
  onRequestBackgroundPermission: () => void = () => {};
  onNightModeChange: (index: number) => void = () => {};
  onClearTrack: () => void = () => {};
  onLocationPermissionRefresh: () => void = () => {};

  // ===== 面板显隐 =====
  @State isShowRecordMode: boolean = false;
  @State isShowLocation: boolean = false;
  @State isShowSetting: boolean = false;
  @State isShowStrategyLab: boolean = false;

  // ===== 面板内 UI 状态 =====
  // 官方 Menu 组件下拉的「已选项」勾标（.selectIcon），用激活色
  private checkMarkModifier: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.checkmark')).fontSize('20vp').fontColor([$r('sys.color.ohos_id_color_activated')]);
  @State isShowPrivacy: boolean = false;

  // 综合判断：三档位置权限是否异常（无前台精确/大致/后台能力）
  private isLocationAbnormal(): boolean {
    return !(this.hasApproximatelyLocation && this.hasLocation && this.hasBackgroundLocation);
  }

  // ===================== 定位模式面板 =====================
  @Builder
  buildRecordModeSheet(): void {
    this.recordModeRootContent()
  }

  @Builder
  recordModeRootContent() {
    Column() {
      Scroll() {
        Column({ space: 12 }) {
          List() {
            ForEach(this.recordModeDescs, (desc: string, index: number) => {
              ListItem() {
                Row() {
                  Column({ space: 6 }) {
                    Text(this.recordModeNames[index])
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                    Text(desc)
                      .fontSize(12)
                      .fontColor($r('sys.color.font_secondary'))
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Radio({ value: `${index}`, group: 'recordMode' })
                    .checked(this.recordMode === index)
                    .radioStyle({
                      checkedBackgroundColor: $r('sys.color.ohos_id_color_activated'),
                      uncheckedBorderColor: $r('sys.color.comp_background_emphasize'),
                      indicatorColor: $r('sys.color.comp_background_primary')
                    })
                    .width(24)
                    .height(24)
                    .onChange((isChecked: boolean) => {
                      if (isChecked) {
                        this.onRecordModeChange(index);
                      }
                    })
                    .margin({ left: 16 })
                }
                .padding({ top: 16, bottom: 16, left: 12, right: 12 })
                .constraintSize({ minHeight: 64 })
                .borderRadius(16)
                .onClick(() => {
                  this.onRecordModeChange(index);
                })
              }
            }, (_desc: string, index: number) => `rm_${index}`)
          }
          .width('100%')
          .height('auto')
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .padding(4)
          .divider({
            strokeWidth: '1px',
            color: $r('sys.color.comp_divider'),
            startMargin: 12,
            endMargin: 12
          })

        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_secondary'))
    }
  }

  // ===================== 定位权限面板 =====================
  @Builder
  buildLocationSheet(): void {
    this.locationRootContent()
  }

  @Builder
  locationRootContent() {
    Column() {
      Scroll() {
        Column({ space: 12 }) {
          List() {
            ListItem() {
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
                .margin({ left: 16 })
              }
              .padding({ top: 16, bottom: 16, left: 12, right: 12 })
              .constraintSize({ minHeight: 64 })
              .borderRadius(16)
              .onClick(() => {
                if (!this.hasApproximatelyLocation) {
                  this.onRequestPermissions();
                } else {
                  this.onOpenPermissionSettings();
                }
              })
            }

            ListItem() {
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
                .margin({ left: 16 })
              }
              .padding({ top: 16, bottom: 16, left: 12, right: 12 })
              .constraintSize({ minHeight: 64 })
              .borderRadius(16)
              .onClick(() => {
                if (!this.hasLocation) {
                  this.onRequestPermissions();
                } else {
                  this.onOpenPermissionSettings();
                }
              })
            }

            ListItem() {
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
                .margin({ left: 16 })
              }
              .padding({ top: 16, bottom: 16, left: 12, right: 12 })
              .constraintSize({ minHeight: 64 })
              .borderRadius(16)
              .onClick(() => {
                if (!this.hasBackgroundLocation) {
                  this.onRequestBackgroundPermission();
                } else {
                  this.onOpenPermissionSettings();
                }
              })
            }
          }
          .width('100%')
          .height('auto')
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .padding(4)
          .divider({
            strokeWidth: '1px',
            color: $r('sys.color.comp_divider'),
            startMargin: 12,
            endMargin: 12
          })

          List() {
            ListItem() {
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
                    .margin({ left: 4 })
                }
                .justifyContent(FlexAlign.End)
                .margin({ left: 16 })
              }
              .padding({ top: 16, bottom: 16, left: 12, right: 12 })
              .constraintSize({ minHeight: 64 })
              .borderRadius(16)
              .onClick(() => {
                this.onOpenPermissionSettings();
              })
            }
          }
          .width('100%')
          .height('auto')
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .padding(4)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_secondary'))
    }
  }

  // ===================== 设置面板 =====================
  @Builder
  buildSettingSheet(): void {
    Column() {
      if (this.isShowPrivacy) {
        this.privacyRootContent()
      } else {
        this.settingRootContent()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  settingRootContent() {
    Column() {
      Scroll() {
        Column({ space: 12 }) {
          Column() {
            Row() {
              Text('固定模板')
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 16, bottom: 8 })

            List() {
              ListItem() {
                Row() {
                  Column({ space: 2 }) {
                    Text('字体大小')
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row() {
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(24)
                      .fontColor([$r('sys.color.font_fourth')])
                      .margin({ left: 4 })
                  }
                  .justifyContent(FlexAlign.End)
                  .margin({ left: 16 })
                }
                .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                .constraintSize({ minHeight: 48 })
                .borderRadius(16)
              }

              ListItem() {
                Row() {
                  Column({ space: 2 }) {
                    Text('夜间模式')
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row() {
                    Text(this.displayModeOptions[this.nightModeIndex])
                      .fontSize(14)
                      .fontColor($r('sys.color.font_secondary'))
                      .maxFontScale(1.3)
                      .constraintSize({ maxWidth: '50%' })
                    SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
                      .fontSize(12)
                      .fontColor([$r('sys.color.font_fourth')])
                      .margin({ left: 4 })
                  }
                  .justifyContent(FlexAlign.End)
                  .margin({ left: 16 })
                  // 官方 Menu 组件下拉：点击该行弹出系统菜单，已选项原生打勾
                  .bindMenu(this.displayModeMenu)
                }
                .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                .constraintSize({ minHeight: 48 })
                .borderRadius(16)
              }

              ListItem() {
                Row() {
                  Column({ space: 2 }) {
                    Text('通知开关')
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row() {
                    Toggle({ type: ToggleType.Switch, isOn: $$this.pushSwitchOn })
                      .selectedColor($r('sys.color.ohos_id_color_warning'))
                  }
                  .justifyContent(FlexAlign.End)
                  .margin({ left: 16 })
                }
                .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                .constraintSize({ minHeight: 48 })
                .borderRadius(16)
              }

              ListItem() {
                Row() {
                  Column({ space: 2 }) {
                    Text('删除轨迹')
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row() {
                    Text(`${this.trackCount}`)
                      .fontSize(14)
                      .fontColor($r('sys.color.font_secondary'))
                      .maxFontScale(1.3)
                      .constraintSize({ maxWidth: '50%' })
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(24)
                      .fontColor([$r('sys.color.font_fourth')])
                      .margin({ left: 4 })
                  }
                  .justifyContent(FlexAlign.End)
                  .margin({ left: 16 })
                }
                .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                .constraintSize({ minHeight: 48 })
                .borderRadius(16)
                .onClick(() => {
                  this.onClearTrack();
                })
              }

              ListItem() {
                Row() {
                  Column({ space: 2 }) {
                    Text('检测版本')
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row() {
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(24)
                      .fontColor([$r('sys.color.font_fourth')])
                      .margin({ left: 4 })
                  }
                  .justifyContent(FlexAlign.End)
                  .margin({ left: 16 })
                }
                .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                .constraintSize({ minHeight: 48 })
                .borderRadius(16)
              }

              ListItem() {
                Row() {
                  Column({ space: 2 }) {
                    Text('关于我们')
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row() {
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(24)
                      .fontColor([$r('sys.color.font_fourth')])
                      .margin({ left: 4 })
                  }
                  .justifyContent(FlexAlign.End)
                  .margin({ left: 16 })
                }
                .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                .constraintSize({ minHeight: 48 })
                .borderRadius(16)
              }

              ListItem() {
                Row() {
                  Column({ space: 2 }) {
                    Text('隐私设置')
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row() {
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(24)
                      .fontColor([$r('sys.color.font_fourth')])
                      .margin({ left: 4 })
                  }
                  .justifyContent(FlexAlign.End)
                  .margin({ left: 16 })
                }
                .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                .constraintSize({ minHeight: 48 })
                .borderRadius(16)
                .onClick(() => {
                  this.isShowPrivacy = true;
                })
              }

              ListItem() {
                Row() {
                  Column({ space: 2 }) {
                    Text('Web页面')
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row() {
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(24)
                      .fontColor([$r('sys.color.font_fourth')])
                      .margin({ left: 4 })
                  }
                  .justifyContent(FlexAlign.End)
                  .margin({ left: 16 })
                }
                .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                .constraintSize({ minHeight: 48 })
                .borderRadius(16)
              }
            }
            .width('100%')
            .height('auto')
            .borderRadius(20)
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .padding(4)
            .divider({
              strokeWidth: '1px',
              color: $r('sys.color.comp_divider'),
              startMargin: 12,
              endMargin: 12,
            })
          }
          .alignItems(HorizontalAlign.Start)

          Column() {
            Row() {
              Text('自定义')
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 16, bottom: 8 })

            List() {
              ListItem() {
                Row() {
                  Column({ space: 2 }) {
                    Text('页面跳转')
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row() {
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(24)
                      .fontColor([$r('sys.color.font_fourth')])
                      .margin({ left: 4 })
                  }
                  .justifyContent(FlexAlign.End)
                  .margin({ left: 16 })
                }
                .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                .constraintSize({ minHeight: 48 })
                .borderRadius(16)
              }

              ListItem() {
                Row() {
                  Column({ space: 2 }) {
                    Text('开关标题')
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                    Text('副标题')
                      .fontSize(12)
                      .fontColor($r('sys.color.font_secondary'))
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row() {
                    Toggle({ type: ToggleType.Switch, isOn: $$this.customSwitchOn })
                      .selectedColor($r('sys.color.ohos_id_color_warning'))
                  }
                  .justifyContent(FlexAlign.End)
                  .margin({ left: 16 })
                }
                .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                .constraintSize({ minHeight: 48 })
                .borderRadius(16)
              }

              ListItem() {
                Row() {
                  Column({ space: 2 }) {
                    Text('下拉选择')
                      .fontSize(16)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row() {
                    Text(this.customSelectOptions[this.customSelectIndex])
                      .fontSize(14)
                      .fontColor($r('sys.color.font_secondary'))
                      .maxFontScale(1.3)
                      .constraintSize({ maxWidth: '50%' })
                    SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
                      .fontSize(12)
                      .fontColor([$r('sys.color.font_fourth')])
                      .margin({ left: 4 })
                  }
                  .justifyContent(FlexAlign.End)
                  .margin({ left: 16 })
                  // 官方 Menu 组件下拉：点击该行弹出系统菜单，已选项原生打勾
                  .bindMenu(this.customMenu)
                }
                .padding({ top: 12, bottom: 12, left: 8, right: 8 })
                .constraintSize({ minHeight: 48 })
                .borderRadius(16)
              }
            }
            .width('100%')
            .height('auto')
            .borderRadius(20)
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .padding(4)
            .divider({
              strokeWidth: '1px',
              color: $r('sys.color.comp_divider'),
              startMargin: 12,
              endMargin: 12,
            })
          }
          .alignItems(HorizontalAlign.Start)

          Column() {
            Button('退出登录')
              .width('100%')
              .backgroundColor($r('sys.color.comp_background_tertiary'))
              .fontColor($r('sys.color.font_primary'))
              .fontWeight(FontWeight.Medium)
              .fontSize(16)
              .padding({ top: 12, bottom: 12 })
          }
          .margin({ top: 16 })
        }
        .padding({ top: 12 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
      .backgroundColor($r('sys.color.background_secondary'))
    }
  }

  // 「隐私设置」二级视图（取代原 NavPathStack + NavDestination 多级导航，消除套娃）
  @Builder
  privacyRootContent() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('sys.color.ohos_id_color_activated')])
          .margin({ left: 12 })
          .onClick(() => {
            this.isShowPrivacy = false;
          })
        Text('隐私设置')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .height(56)
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 12 }) {
          List() {
            ListItem() {
              Row() {
                Column({ space: 2 }) {
                  Text('个性化推荐')
                    .fontSize(16)
                    .fontColor($r('sys.color.font_primary'))
                    .fontWeight(FontWeight.Medium)
                    .textAlign(TextAlign.Start)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  Toggle({ type: ToggleType.Switch, isOn: true })
                    .selectedColor($r('sys.color.ohos_id_color_warning'))
                }
                .justifyContent(FlexAlign.End)
                .margin({ left: 16 })
              }
              .padding({ top: 12, bottom: 12, left: 8, right: 8 })
              .constraintSize({ minHeight: 48 })
              .borderRadius(16)
            }
          }
          .width('100%')
          .height('auto')
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .padding(4)

          List() {
            ListItem() {
              Row() {
                Column({ space: 2 }) {
                  Text('通知开关')
                    .fontSize(16)
                    .fontColor($r('sys.color.font_primary'))
                    .fontWeight(FontWeight.Medium)
                    .textAlign(TextAlign.Start)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  Toggle({ type: ToggleType.Switch, isOn: true })
                    .selectedColor($r('sys.color.ohos_id_color_warning'))
                }
                .justifyContent(FlexAlign.End)
                .margin({ left: 16 })
              }
              .padding({ top: 12, bottom: 12, left: 8, right: 8 })
              .constraintSize({ minHeight: 48 })
              .borderRadius(16)
            }
          }
          .width('100%')
          .height('auto')
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .padding(4)

          List() {
            ListItem() {
              Row() {
                Column({ space: 2 }) {
                  Text('用户协议')
                    .fontSize(16)
                    .fontColor($r('sys.color.font_primary'))
                    .fontWeight(FontWeight.Medium)
                    .textAlign(TextAlign.Start)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(24)
                    .fontColor([$r('sys.color.font_fourth')])
                    .margin({ left: 4 })
                }
                .justifyContent(FlexAlign.End)
                .margin({ left: 16 })
              }
              .padding({ top: 12, bottom: 12, left: 8, right: 8 })
              .constraintSize({ minHeight: 48 })
              .borderRadius(16)
            }

            ListItem() {
              Row() {
                Column({ space: 2 }) {
                  Text('隐私政策')
                    .fontSize(16)
                    .fontColor($r('sys.color.font_primary'))
                    .fontWeight(FontWeight.Medium)
                    .textAlign(TextAlign.Start)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Row() {
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(24)
                    .fontColor([$r('sys.color.font_fourth')])
                    .margin({ left: 4 })
                }
                .justifyContent(FlexAlign.End)
                .margin({ left: 16 })
              }
              .padding({ top: 12, bottom: 12, left: 8, right: 8 })
              .constraintSize({ minHeight: 48 })
              .borderRadius(16)
            }
          }
          .width('100%')
          .height('auto')
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .padding(4)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
      .width('100%')
      .backgroundColor($r('sys.color.background_secondary'))
    }
  }

  // ===================== 策略实验室面板 =====================
  @Builder
  buildStrategyLabSheet(): void {
    Scroll() {
      Column({ space: 12 }) {
        // 自动生效策略（原「定位模式」面板的「防漂移与性能策略」，统一收到策略实验室）
        // 标题独立成块，每项策略各自为独立白卡容器（不再整体包进一个外层白卡）
        Column() {
          Text('自动生效策略')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .width('100%')
          Text('以下策略在所有定位模式下自动生效，无需手动开启：')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .margin({ top: 4 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 16, bottom: 4 })

        ForEach(this.recordStrategyItems,
          (item: RecordStrategyItem, _index: number) => {
            if (item.title === '抖动地板') {
              Column() {
                Row() {
                  Column({ space: 4 }) {
                    Text(item.title)
                      .fontSize(13)
                      .fontColor($r('sys.color.font_primary'))
                      .fontWeight(FontWeight.Medium)
                    Text(item.desc)
                      .fontSize(12)
                      .fontColor($r('sys.color.font_secondary'))
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Row() {
                    Text(this.shakeFloorOptions[this.shakeFloorIndex])
                      .fontSize(13)
                      .fontColor($r('sys.color.font_secondary'))
                      .margin({ left: 12 })
                    SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
                      .fontSize(12)
                      .fontColor([$r('sys.color.font_fourth')])
                      .margin({ left: 4 })
                  }
                  .justifyContent(FlexAlign.End)
                }
                .width('100%')
                // 官方 Menu 组件下拉：点击该行弹出系统菜单，已选项原生打勾
                .bindMenu(this.shakeMenu)
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(12)
            } else {
              Column() {
                Text(item.title)
                  .fontSize(13)
                  .fontColor($r('sys.color.font_primary'))
                  .fontWeight(FontWeight.Medium)
                Text(item.desc)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
                  .margin({ top: 4 })
                  .textAlign(TextAlign.Start)
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(12)
            }
          },
          (item: RecordStrategyItem, index: number) => `str_${index}`)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4 })
    }
    .layoutWeight(1)
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  // 官方 Menu 组件下拉：bindMenu + Menu/MenuItem + .selected/.selectIcon 原生打勾
  @Builder
  displayModeMenu() {
    Menu() {
      MenuItem({ content: this.displayModeOptions[0] })
        .selected(this.nightModeIndex === 0)
        .selectIcon(this.checkMarkModifier)
        .onClick(() => { this.nightModeIndex = 0; this.onNightModeChange(0); })
      MenuItem({ content: this.displayModeOptions[1] })
        .selected(this.nightModeIndex === 1)
        .selectIcon(this.checkMarkModifier)
        .onClick(() => { this.nightModeIndex = 1; this.onNightModeChange(1); })
      MenuItem({ content: this.displayModeOptions[2] })
        .selected(this.nightModeIndex === 2)
        .selectIcon(this.checkMarkModifier)
        .onClick(() => { this.nightModeIndex = 2; this.onNightModeChange(2); })
    }
  }

  @Builder
  customMenu() {
    Menu() {
      MenuItem({ content: this.customSelectOptions[0] })
        .selected(this.customSelectIndex === 0)
        .selectIcon(this.checkMarkModifier)
        .onClick(() => { this.customSelectIndex = 0; })
      MenuItem({ content: this.customSelectOptions[1] })
        .selected(this.customSelectIndex === 1)
        .selectIcon(this.checkMarkModifier)
        .onClick(() => { this.customSelectIndex = 1; })
      MenuItem({ content: this.customSelectOptions[2] })
        .selected(this.customSelectIndex === 2)
        .selectIcon(this.checkMarkModifier)
        .onClick(() => { this.customSelectIndex = 2; })
    }
  }

  @Builder
  shakeMenu() {
    Menu() {
      MenuItem({ content: this.shakeFloorOptions[0] })
        .selected(this.shakeFloorIndex === 0)
        .selectIcon(this.checkMarkModifier)
        .onClick(() => { this.shakeFloorIndex = 0; })
      MenuItem({ content: this.shakeFloorOptions[1] })
        .selected(this.shakeFloorIndex === 1)
        .selectIcon(this.checkMarkModifier)
        .onClick(() => { this.shakeFloorIndex = 1; })
      MenuItem({ content: this.shakeFloorOptions[2] })
        .selected(this.shakeFloorIndex === 2)
        .selectIcon(this.checkMarkModifier)
        .onClick(() => { this.shakeFloorIndex = 2; })
    }
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        // 第一组：定位模式 / 策略实验室 / 定位权限 / 我的订单
        Column() {
          Column() {
            CardItem({
              label: '定位模式',
              symbol: $r('sys.symbol.local_badge_gearshape'),
              statusText: this.recordModeNames[this.recordMode],
              statusColor: $r('sys.color.font_secondary'),
              onClickEvent: () => {
                this.isShowRecordMode = true;
              }
            })
            Divider()
              .strokeWidth('1px')
              .color($r('sys.color.comp_divider'))
              .margin({ left: 48, right: 12 })
            CardItem({
              label: '策略实验室',
              symbol: $r('sys.symbol.person_shield_fill'),
              onClickEvent: () => {
                this.isShowStrategyLab = true;
              }
            })
            Divider()
              .strokeWidth('1px')
              .color($r('sys.color.comp_divider'))
              .margin({ left: 48, right: 12 })
            CardItem({
              label: '定位权限',
              symbol: $r('sys.symbol.position_badge_exclamationmark'),
              statusText: this.isLocationAbnormal() ? '权限异常' : '',
              statusColor: $r('sys.color.ohos_id_color_warning'),
              onClickEvent: () => {
                this.onLocationPermissionRefresh();
                this.isShowLocation = true;
              }
            })
            Divider()
              .strokeWidth('1px')
              .color($r('sys.color.comp_divider'))
              .margin({ left: 48, right: 12 })
            CardItem({ label: '我的订单', symbol: $r('sys.symbol.bag') })
          }
          .width('100%')
        }
        .borderRadius(20)
        .backgroundColor($r('sys.color.comp_background_list_card'))

        // 第二组：意见反馈 / 设置
        Column() {
          Column() {
            CardItem({ label: '意见反馈', symbol: $r('sys.symbol.doc_plaintext_and_pencil') })
            Divider()
              .strokeWidth('1px')
              .color($r('sys.color.comp_divider'))
              .margin({ left: 48, right: 12 })
            CardItem({
              label: '设置',
              symbol: $r('sys.symbol.gearshape'),
              onClickEvent: () => {
                this.isShowSetting = true;
              }
            })
          }
          .width('100%')
        }
        .borderRadius(20)
        .backgroundColor($r('sys.color.comp_background_list_card'))

        // 四个半模态面板绑定宿主：包进一个零尺寸父 Column，整体只占一次间距、不占视觉空间
        // 每个面板独占一个子节点（避免「多 bindSheet 叠同一节点互相覆盖」）；
        // 全部用组件内自带 @Builder（bindSheet 调 this.buildXxxSheet()），不再用 @BuilderParam 跨组件传引用
        Column() {
          Column()
            .width(0)
            .height(0)
            .bindSheet($$this.isShowRecordMode, this.buildRecordModeSheet(), {
              title: { title: '定位模式' },
              height: SheetSize.LARGE,
              dragBar: true,
              showClose: true,
              onDisappear: () => {
                this.isShowRecordMode = false;
              }
            })
          Column()
            .width(0)
            .height(0)
            .bindSheet($$this.isShowLocation, this.buildLocationSheet(), {
              title: { title: '定位权限' },
              height: SheetSize.LARGE,
              dragBar: true,
              showClose: true,
              onDisappear: () => {
                this.isShowLocation = false;
              }
            })
          Column()
            .width(0)
            .height(0)
            .bindSheet($$this.isShowSetting, this.buildSettingSheet(), {
              title: { title: '设置' },
              height: SheetSize.LARGE,
              dragBar: true,
              showClose: true,
              onDisappear: () => {
                this.isShowSetting = false;
                this.isShowPrivacy = false;
              }
            })
          Column()
            .width(0)
            .height(0)
      .bindSheet($$this.isShowStrategyLab, this.buildStrategyLabSheet(), {
        title: { title: '策略实验室' },
        height: SheetSize.LARGE,
        dragBar: true,
        showClose: true,
        onDisappear: () => {
          this.isShowStrategyLab = false;
        }
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
      .backgroundColor($r('sys.color.background_secondary'))
  }
}
