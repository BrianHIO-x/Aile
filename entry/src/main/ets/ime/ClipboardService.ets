import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { Log } from './Log';

export const PASTEBOARD_PERMISSION: Permissions = 'ohos.permission.READ_PASTEBOARD';

/**
 * 系统剪贴板读取。持续收录需要用户在 Aile 应用中授予读取权限；
 * 未授权时只能通过粘贴控件读取一次，控件点击成功后系统临时放行。
 */
export class ClipboardService {
  private context: common.Context | undefined = undefined;
  private subscribed: boolean = false;
  private lastText: string = '';
  private onText: (text: string) => void = () => {
  };
  private canCapture: () => boolean = () => false;

  private updateCallback = (): void => {
    if (this.canCapture() && this.isGranted()) {
      this.readText().then((text: string) => this.deliver(text));
    }
  };

  init(context: common.Context, canCapture: () => boolean, onText: (text: string) => void): void {
    this.context = context;
    this.canCapture = canCapture;
    this.onText = onText;
    if (this.subscribed) {
      return;
    }
    try {
      pasteboard.getSystemPasteboard().on('update', this.updateCallback);
      this.subscribed = true;
    } catch (error) {
      Log.warn(`pasteboard subscribe failed, code=${(error as BusinessError).code}`);
    }
  }

  destroy(): void {
    if (this.subscribed) {
      try {
        pasteboard.getSystemPasteboard().off('update', this.updateCallback);
      } catch (error) {
        Log.warn(`pasteboard unsubscribe failed, code=${(error as BusinessError).code}`);
      }
      this.subscribed = false;
    }
    this.context = undefined;
  }

  isGranted(): boolean {
    const context = this.context;
    if (context === undefined) {
      return false;
    }
    try {
      const status = abilityAccessCtrl.createAtManager()
        .checkAccessTokenSync(context.applicationInfo.accessTokenId, PASTEBOARD_PERMISSION);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      return false;
    }
  }

  /**
   * 已授权时把当前剪贴板文字交给收录回调，用于打开剪贴板面板时补收。
   */
  captureNow(): void {
    if (this.canCapture() && this.isGranted()) {
      this.readText().then((text: string) => this.deliver(text));
    }
  }

  /**
   * 读取当前剪贴板中的纯文本，没有文本或读取失败时返回空串。日志只记录错误码。
   */
  async readText(): Promise<string> {
    try {
      const board = pasteboard.getSystemPasteboard();
      if (!board.hasDataType(pasteboard.MIMETYPE_TEXT_PLAIN)) {
        return '';
      }
      const data = await board.getData();
      return data.getPrimaryText() ?? '';
    } catch (error) {
      Log.warn(`pasteboard read failed, code=${(error as BusinessError).code}`);
      return '';
    }
  }

  private deliver(text: string): void {
    if (text.trim().length === 0 || text === this.lastText) {
      return;
    }
    this.lastText = text;
    this.onText(text);
  }
}
