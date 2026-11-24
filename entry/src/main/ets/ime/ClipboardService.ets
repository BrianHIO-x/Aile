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
  // fresh 为 true 表示这段文字来自一次新的复制，打开剪贴板面板时补收的文字为 false
  private onText: (text: string, fresh: boolean) => void = () => {
  };
  private canCapture: () => boolean = () => false;

  // 剪贴板更新事件代表一次新的复制，重复复制同一段文字也照常送出
  private updateCallback = (): void => {
    if (this.canCapture() && this.isGranted()) {
      this.readText().then((text: string) => this.deliver(text, true));
    }
  };

  init(context: common.Context, canCapture: () => boolean, onText: (text: string, fresh: boolean) => void): void {
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
      this.readText().then((text: string) => this.deliver(text, false));
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

  private deliver(text: string, fresh: boolean): void {
    if (text.trim().length === 0 || (!fresh && text === this.lastText)) {
      return;
    }
    this.lastText = text;
    this.onText(text, fresh);
  }
}
