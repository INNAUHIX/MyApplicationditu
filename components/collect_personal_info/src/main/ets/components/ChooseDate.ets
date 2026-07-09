@ComponentV2
export struct ChooseDate {
  // 初始化传入的日期
  @Once @Param date: Date | null = null;
  // 日期选择后的回调
  @Event onDateSelected: (date: Date) => void;
  // 关闭半模态
  @Event onClose: () => void = () => {
  };
  @Local tempDate: Date = new Date();

  aboutToAppear(): void {
    this.tempDate = this.date || new Date();
  }

  build() {
    Column({ space: 32 }) {
      Text() {
        Span(this.dateStr)
        Span(' ')
        Span(this.weekStr)
      }
      .fontSize($r('sys.float.Title_S'))
      .fontColor($r('sys.color.font_primary'))
      .fontWeight(FontWeight.Bold)
      .padding(24)

      DatePicker({
        selected: this.date,
        start: new Date('1900-02-01'),
        end: new Date(),
      })
        .selectedTextStyle({ color: '#0A59F7' })
        .onDateChange((date: Date) => {
          this.tempDate = date;
        })

      Blank()

      Row({ space: 4 }) {
        Button('取消')
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontColor('#0A59F7')
          .fontSize($r('sys.float.Body_L'))
          .layoutWeight(1)
          .onClick(() => {
            this.onClose();
          })
        Button('确定')
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontColor('#0A59F7')
          .fontSize($r('sys.float.Body_L'))
          .layoutWeight(1)
          .onClick(() => {
            this.onDateSelected(this.tempDate ?? new Date());
          })
      }
      .width('100%')
    }
  }

  @Computed
  get dateStr() {
    return `${this.tempDate.getFullYear()}年${this.tempDate.getMonth() + 1}月${this.tempDate.getDate()}日`;
  }

  @Computed
  get weekStr() {
    const days = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
    return days[this.tempDate.getDay()];
  }
}
