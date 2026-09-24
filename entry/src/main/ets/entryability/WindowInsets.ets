import { window } from '@kit.ArkUI';

/**
 * 应用窗口铺满全屏后，状态栏与底部手势横条占用的高度，单位 px。
 * 页面据此留出上下边距，背景延伸到系统栏下方，内容不被遮挡。
 */
@ObservedV2
export class WindowInsets {
  private static instance: WindowInsets | undefined = undefined;

  @Trace topPx: number = 0;
  @Trace bottomPx: number = 0;

  static get(): WindowInsets {
    if (WindowInsets.instance === undefined) {
      WindowInsets.instance = new WindowInsets();
    }
    return WindowInsets.instance;
  }

  update(win: window.Window): void {
    const system = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const indicator = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    this.topPx = system.topRect.height;
    this.bottomPx = Math.max(system.bottomRect.height, indicator.bottomRect.height);
  }
}
