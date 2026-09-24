import { inputMethodEngine, InputMethodExtensionContext } from '@kit.IMEKit';
import { display, window } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { KEYBOARD_BOTTOM_INSET_VP } from '../keyboard/LayoutProfile';
import { AreaPadding, ImeState } from './ImeState';
import { Log } from './Log';

const KEYBOARD_PAGE: string = 'inputmethod/pages/KeyboardPage';
const MAX_HEIGHT_RATIO: number = 0.7;

export interface PanelGeometry {
  displayId: number;
  panelWidthPx: number;
  panelHeightPx: number;
  areaText: string;
  insetsText: string;
  density: number;
}

/**
 * 单一固定软键盘面板的创建、尺寸调整与几何测量。
 */
export class PanelController {
  private panel: inputMethodEngine.Panel | undefined = undefined;
  private creating: Promise<inputMethodEngine.Panel | undefined> | undefined = undefined;
  private generation: number = 0;
  private landscapeHeightVp: number = 300;
  private portraitHeightVp: number = 300;
  private geometry: PanelGeometry = {
    displayId: -1, panelWidthPx: 0, panelHeightPx: 0, areaText: '-', insetsText: '-', density: 1
  };
  private onGeometryChanged: () => void = () => {
  };

  private sizeChangeCallback = (size: window.Size, keyboardArea?: inputMethodEngine.KeyboardArea): void => {
    this.geometry.panelWidthPx = size.width;
    this.geometry.panelHeightPx = size.height;
    const density = this.readDensity();
    this.geometry.density = density;
    const state = ImeState.get();
    if (keyboardArea !== undefined) {
      this.geometry.areaText =
        `L${keyboardArea.left} T${keyboardArea.top} R${keyboardArea.right} B${keyboardArea.bottom}`;
      const padding: AreaPadding = {
        left: Math.max(0, keyboardArea.left) / density,
        top: Math.max(0, keyboardArea.top) / density,
        right: Math.max(0, size.width - keyboardArea.right) / density,
        bottom: Math.max(0, size.height - keyboardArea.bottom) / density
      };
      // 部分系统返回的 right、bottom 为零，表示未提供有效区域
      if (keyboardArea.right <= 0 || keyboardArea.bottom <= 0) {
        padding.right = 0;
        padding.bottom = 0;
      }
      state.keyboardPadding = padding;
    } else {
      this.geometry.areaText = 'none';
    }
    state.isLandscape = this.detectLandscape();
    this.refreshInsets();
    this.onGeometryChanged();
  };

  setGeometryListener(listener: () => void): void {
    this.onGeometryChanged = listener;
  }

  getGeometry(): PanelGeometry {
    return this.geometry;
  }

  getPanel(): inputMethodEngine.Panel | undefined {
    return this.panel;
  }

  create(context: InputMethodExtensionContext): Promise<inputMethodEngine.Panel | undefined> {
    if (this.panel !== undefined) {
      return Promise.resolve(this.panel);
    }
    if (this.creating !== undefined) {
      return this.creating;
    }
    const generation = this.generation;
    this.creating = this.doCreate(context, generation);
    return this.creating;
  }

  private async doCreate(context: InputMethodExtensionContext,
    generation: number): Promise<inputMethodEngine.Panel | undefined> {
    const ability = inputMethodEngine.getInputMethodAbility();
    const info: inputMethodEngine.PanelInfo = {
      type: inputMethodEngine.PanelType.SOFT_KEYBOARD,
      flag: inputMethodEngine.PanelFlag.FLG_FIXED
    };
    let panel: inputMethodEngine.Panel | undefined = undefined;
    try {
      panel = await ability.createPanel(context, info);
      if (generation !== this.generation) {
        await ability.destroyPanel(panel);
        return undefined;
      }
      panel.on('sizeChange', this.sizeChangeCallback);
      this.panel = panel;
      this.applyHeights(this.landscapeHeightVp, this.portraitHeightVp);
      await panel.setUiContent(KEYBOARD_PAGE);
      Log.info('panel created');
      return panel;
    } catch (error) {
      Log.error(`panel create failed, code=${(error as BusinessError).code}`);
      if (panel !== undefined) {
        try {
          panel.off('sizeChange', this.sizeChangeCallback);
          await ability.destroyPanel(panel);
        } catch (cleanupError) {
          Log.error(`panel cleanup failed, code=${(cleanupError as BusinessError).code}`);
        }
      }
      this.panel = undefined;
      return undefined;
    } finally {
      this.creating = undefined;
    }
  }

  async destroy(): Promise<void> {
    this.generation++;
    const panel = this.panel;
    this.panel = undefined;
    if (panel === undefined) {
      return;
    }
    try {
      panel.off('sizeChange', this.sizeChangeCallback);
      await inputMethodEngine.getInputMethodAbility().destroyPanel(panel);
    } catch (error) {
      Log.error(`panel destroy failed, code=${(error as BusinessError).code}`);
    }
  }

  /**
   * 横竖屏高度一次提交，宽度取对应方向的屏幕宽度，高度限制在屏幕高度的 70% 以内。
   */
  applyHeights(landscapeVp: number, portraitVp: number): void {
    this.landscapeHeightVp = landscapeVp;
    this.portraitHeightVp = portraitVp;
    const panel = this.panel;
    if (panel === undefined) {
      return;
    }
    try {
      const screen = display.getDefaultDisplaySync();
      const density = screen.densityPixels > 0 ? screen.densityPixels : 1;
      const longSide = Math.max(screen.width, screen.height);
      const shortSide = Math.min(screen.width, screen.height);
      // 键盘高度之外追加底部留白，按键大小不受影响
      const landscapeHeight = Math.min(Math.round((landscapeVp + KEYBOARD_BOTTOM_INSET_VP) * density),
        Math.floor(shortSide * MAX_HEIGHT_RATIO));
      const portraitHeight = Math.min(Math.round((portraitVp + KEYBOARD_BOTTOM_INSET_VP) * density),
        Math.floor(longSide * MAX_HEIGHT_RATIO));
      const landscapeRect: window.Rect = { left: 0, top: 0, width: longSide, height: landscapeHeight };
      const portraitRect: window.Rect = { left: 0, top: 0, width: shortSide, height: portraitHeight };
      const panelRect: inputMethodEngine.PanelRect = { landscapeRect: landscapeRect, portraitRect: portraitRect };
      panel.adjustPanelRect(inputMethodEngine.PanelFlag.FLG_FIXED, panelRect);
    } catch (error) {
      Log.error(`adjustPanelRect failed, code=${(error as BusinessError).code}`);
    }
  }

  async refreshInsets(): Promise<void> {
    const panel = this.panel;
    if (panel === undefined) {
      return;
    }
    try {
      const displayId = await panel.getDisplayId();
      this.geometry.displayId = displayId;
      if (deviceInfo.sdkApiVersion >= 21) {
        const insets = await panel.getSystemPanelCurrentInsets(displayId);
        this.geometry.insetsText = `L${insets.left} R${insets.right} B${insets.bottom}`;
      } else {
        this.geometry.insetsText = `unsupported api ${deviceInfo.sdkApiVersion}`;
      }
      Log.info(`geometry display=${displayId} panel=${this.geometry.panelWidthPx}x${this.geometry.panelHeightPx} ` +
        `area=${this.geometry.areaText} insets=${this.geometry.insetsText}`);
      this.onGeometryChanged();
    } catch (error) {
      this.geometry.insetsText = `error ${(error as BusinessError).code}`;
      this.onGeometryChanged();
    }
  }

  private readDensity(): number {
    try {
      const density = display.getDefaultDisplaySync().densityPixels;
      return density > 0 ? density : 1;
    } catch (error) {
      return 1;
    }
  }

  detectLandscape(): boolean {
    try {
      const screen = display.getDefaultDisplaySync();
      return screen.width >= screen.height;
    } catch (error) {
      return true;
    }
  }
}
