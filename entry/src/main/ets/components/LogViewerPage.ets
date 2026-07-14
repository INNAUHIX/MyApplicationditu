import { AppLogger } from '../common/logger/AppLogger';
import { LogLevel, LogEntry } from '../common/logger/LogEntry';

@Component
export struct LogViewerPage {
  @State entries: LogEntry[] = [];
  private refreshFn: () => void = () => {};

  aboutToAppear(): void {
    this.entries = AppLogger.getEntries().slice().reverse();
    this.refreshFn = () => {
      this.entries = AppLogger.getEntries().slice().reverse();
    };
    AppLogger.addListener(this.refreshFn);
  }

  aboutToDisappear(): void {
    AppLogger.removeListener(this.refreshFn);
  }

  private formatTime(ts: number): string {
    const d: Date = new Date(ts);
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${Math.floor(d.getMilliseconds() / 100)}`;
  }

  private levelLabel(level: LogLevel): string {
    switch (level) {
      case LogLevel.DEBUG: return '调试';
      case LogLevel.INFO: return '信息';
      case LogLevel.WARN: return '警告';
      case LogLevel.ERROR: return '错误';
      default: return '';
    }
  }

  private levelColor(level: LogLevel): ResourceStr {
    switch (level) {
      case LogLevel.DEBUG: return $r('sys.color.font_tertiary');
      case LogLevel.INFO: return $r('sys.color.font_primary');
      case LogLevel.WARN: return $r('sys.color.ohos_id_color_warning');
      case LogLevel.ERROR: return $r('sys.color.ohos_id_color_warning');
      default: return $r('sys.color.font_primary');
    }
  }

  build() {
    Column() {
      Row() {
        Text(`共 ${this.entries.length} 条 · 实时刷新`)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
        Blank()
        Button('清空')
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_activated'))
          .backgroundColor(Color.Transparent)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => {
            AppLogger.clear();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      List() {
        ForEach(this.entries, (entry: LogEntry, index: number) => {
          ListItem() {
            Row() {
              if (entry.key) {
                Row()
                  .width(3)
                  .height(16)
                  .backgroundColor($r('sys.color.ohos_id_color_activated'))
                  .borderRadius(1.5)
              }
              Row({ space: 6 }) {
                Text(this.formatTime(entry.timestamp))
                  .fontSize(11)
                  .fontColor(entry.key ? $r('sys.color.ohos_id_color_activated') : $r('sys.color.font_tertiary'))
                  .fontFamily('monospace')
                  .width(78)
                Text(this.levelLabel(entry.level))
                  .fontSize(11)
                  .fontColor(this.levelColor(entry.level))
                  .width(26)
                Text(`[${entry.tag}]`)
                  .fontSize(11)
                  .fontColor($r('sys.color.font_secondary'))
                Text(entry.message)
                  .fontSize(11)
                  .fontColor(entry.key ? $r('sys.color.ohos_id_color_activated') : $r('sys.color.font_primary'))
                  .fontWeight(entry.key ? FontWeight.Medium : FontWeight.Normal)
                  .layoutWeight(1)
              }
              .layoutWeight(1)
              .padding({ left: entry.key ? 8 : 0 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
            .alignItems(VerticalAlign.Center)
            .borderRadius(entry.key ? 8 : 0)
            .backgroundColor(entry.key ? $r('sys.color.ohos_id_color_hover') : Color.Transparent)
            .margin(entry.key ? { left: 12, right: 12, top: 2, bottom: 2 } : { left: 0, right: 0, top: 0, bottom: 0 })
          }
        }, (entry: LogEntry, index: number) => `log_${entry.timestamp}_${index}`)
      }
      .layoutWeight(1)
      .divider({ strokeWidth: 0.5, color: $r('sys.color.comp_divider'), startMargin: 16, endMargin: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
