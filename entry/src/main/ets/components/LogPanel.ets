import { LogRecord, LogLevel, LOG_CATEGORY_STYLES } from '../model/TrackTypes';
import { LogService } from '../service/LogService';
import { getDayKey } from '../common/TrackUtils';

@Component
export struct LogPanel {
  scroller: Scroller = new Scroller();
  logSvc: LogService = new LogService();

  @State currentDateKey: string = '';
  @State dateList: string[] = [];
  @State logRecords: LogRecord[] = [];

  aboutToAppear(): void {
    const today: string = getDayKey(Date.now());
    this.currentDateKey = today;
    this.loadDates();
    this.loadLogs();
  }

  private loadDates(): void {
    this.logSvc.queryDates().then((dates: string[]) => {
      this.dateList = dates;
      if (dates.length > 0 && !dates.includes(this.currentDateKey)) {
        this.currentDateKey = dates[0];
        this.loadLogs();
      }
    });
  }

  private loadLogs(): void {
    this.logSvc.queryByDate(this.currentDateKey).then((records: LogRecord[]) => {
      this.logRecords = records;
    });
  }

  private prevDate(): void {
    const idx: number = this.dateList.indexOf(this.currentDateKey);
    if (idx >= 0 && idx < this.dateList.length - 1) {
      this.currentDateKey = this.dateList[idx + 1];
      this.loadLogs();
    }
  }

  private nextDate(): void {
    const idx: number = this.dateList.indexOf(this.currentDateKey);
    if (idx > 0) {
      this.currentDateKey = this.dateList[idx - 1];
      this.loadLogs();
    }
  }

  private formatTime(ts: number): string {
    const d: Date = new Date(ts);
    const h: string = d.getHours().toString().padStart(2, '0');
    const m: string = d.getMinutes().toString().padStart(2, '0');
    const s: string = d.getSeconds().toString().padStart(2, '0');
    return `${h}:${m}:${s}`;
  }

  private getTagColor(tag: string): string {
    const style = LOG_CATEGORY_STYLES[tag];
    if (style !== undefined) {
      return style.color;
    }
    return '#999999';
  }

  private showClearDialog(): void {
    this.getUIContext().showAlertDialog({
      title: '清除日志',
      message: '确定要清除所有日志吗？此操作不可恢复。',
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '清除',
        action: () => {
          this.logSvc.clearAll().then(() => {
            this.logRecords = [];
            this.dateList = [];
            this.currentDateKey = getDayKey(Date.now());
          });
        }
      }
    });
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(18)
          .fontColor([$r('sys.color.ohos_id_color_primary')])
          .onClick(() => { this.prevDate(); })

        Text(this.currentDateKey)
          .fontSize(15)
          .fontColor($r('sys.color.font_primary'))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([$r('sys.color.ohos_id_color_primary')])
          .onClick(() => { this.nextDate(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      if (this.logRecords.length === 0) {
        Column() {
          Text('暂无日志')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .margin({ top: 40 })
        }
        .layoutWeight(1)
        .width('100%')
      } else {
        Scroll(this.scroller) {
          Column({ space: 0 }) {
            ForEach(this.logRecords, (record: LogRecord, index: number) => {
              Row({ space: 8 }) {
                Circle({ width: 8, height: 8 })
                  .fill(this.getTagColor(record.tag))

                Text(this.formatTime(record.timestamp))
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
                  .fontFamily('monospace')
                  .width(64)

                Text(record.tag)
                  .fontSize(12)
                  .fontColor(this.getTagColor(record.tag))
                  .fontWeight(FontWeight.Medium)
                  .width(32)

                Text(record.message)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_primary'))
                  .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              .alignItems(VerticalAlign.Center)
            }, (record: LogRecord, index: number) => `${record.id ?? index}`)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }

      Row() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(18)
          .fontColor([$r('sys.color.ohos_id_color_emphasize')])
        Text('清除所有日志')
          .fontSize(14)
          .fontColor($r('sys.color.ohos_id_color_emphasize'))
          .margin({ left: 4 })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 12 })
      .onClick(() => { this.showClearDialog(); })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
