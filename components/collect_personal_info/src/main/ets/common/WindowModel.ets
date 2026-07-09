import { window } from '@kit.ArkUI';

@ObservedV2
export class WindowModel {
  uiContext?: UIContext
  @Trace windowBottomPadding: number = 0;
  public getWindowBottomPadding: () => void = () => {
    try {
      window.getLastWindow(this.uiContext?.getHostContext()).then(currentWindow => {
        const area = currentWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        this.windowBottomPadding = this.uiContext?.px2vp(area.bottomRect.height) ?? 0;
      })
    } catch (e) {
      console.error(`getWindowBottomPadding failed with error ${JSON.stringify(e)}`);
    }
  }
  public registerWindowBottomPadding() {
    this.getWindowBottomPadding();
    try {
      window.getLastWindow(this.uiContext?.getHostContext()).then(currentWindow => {
        currentWindow.on('avoidAreaChange', this.getWindowBottomPadding);
      })
    } catch (e) {
      console.error(`registerWindowBottomPadding failed with error ${JSON.stringify(e)}`);
    }
  }
  public unRegisterWindowBottomPadding() {
    try {
      window.getLastWindow(this.uiContext?.getHostContext()).then(currentWindow => {
        currentWindow.off('avoidAreaChange', this.getWindowBottomPadding);
      })
    } catch (e) {
      console.error(`unRegisterWindowBottomPadding failed with error ${JSON.stringify(e)}`);
    }
  }
  public registerKeyboardListener(callback: Callback<number>) {
    try {
      window.getLastWindow(this.uiContext?.getHostContext()).then(currentWindow => {
        const keyboardH = currentWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD).bottomRect.height;
        callback(keyboardH);
        currentWindow.on('keyboardHeightChange', callback);
      })
    } catch (e) {
      console.error(`registerKeyboardListener failed with error ${JSON.stringify(e)}`);
    }
  }
  public unRegisterKeyboardListener(callback: Callback<number>) {
    try {
      window.getLastWindow(this.uiContext?.getHostContext()).then(currentWindow => {
        currentWindow.off('keyboardHeightChange', callback);
      })
    } catch (e) {
      console.error(`unRegisterKeyboardListener failed with error ${JSON.stringify(e)}`);
    }
  }
}
