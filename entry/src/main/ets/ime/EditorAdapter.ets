import { inputMethodEngine } from '@kit.IMEKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './Log';

type EditorOperation = (client: inputMethodEngine.InputClient) => Promise<boolean>;

// 光标一侧超过该长度时不执行清空。撤销内容最多为两侧之和，读取与撤销时的单次传输量也受此限制
export const CLEAR_TEXT_LIMIT: number = 20000;
// 编辑框在下一帧才执行删除或插入，操作后等待刷新再复查
const SETTLE_MS: number = 50;
const CLEAR_VERIFY_ROUNDS: number = 3;
const RESTORE_SETTLE_ROUNDS: number = 6;
// 撤销时分段插入，避免单次跨进程传输过大
const RESTORE_CHUNK: number = 4000;

export enum ClearStatus {
  CLEARED = 'cleared',
  EMPTY = 'empty',
  TOO_LONG = 'tooLong',
  FAILED = 'failed'
}

/**
 * text 为清空前编辑框的全部文字，caret 为清空前光标在 text 中的位置，供撤销时恢复。
 */
export interface ClearResult {
  status: ClearStatus;
  text: string;
  caret: number;
}

function wait(ms: number): Promise<void> {
  return new Promise<void>((resolve: (value: void | PromiseLike<void>) => void) => {
    setTimeout(() => resolve(), ms);
  });
}

function isHighSurrogate(code: number): boolean {
  return code >= 0xd800 && code <= 0xdbff;
}

/**
 * 所有编辑操作按用户动作顺序串行执行，执行前校验会话编号，旧会话的操作直接丢弃。
 */
export class EditorAdapter {
  private client: inputMethodEngine.InputClient | undefined = undefined;
  private sessionId: number = 0;
  private tail: Promise<void> = Promise.resolve();

  bind(client: inputMethodEngine.InputClient, sessionId: number): void {
    this.client = client;
    this.sessionId = sessionId;
  }

  unbind(sessionId: number): void {
    if (this.sessionId === sessionId) {
      this.client = undefined;
    }
  }

  isBound(): boolean {
    return this.client !== undefined;
  }

  currentSession(): number {
    return this.sessionId;
  }

  getClient(): inputMethodEngine.InputClient | undefined {
    return this.client;
  }

  insertText(text: string): Promise<boolean> {
    return this.enqueue('insertText', (client: inputMethodEngine.InputClient) => client.insertText(text));
  }

  // deleteForward 删除光标前的文本
  deleteBeforeCursor(length: number): Promise<boolean> {
    return this.enqueue('deleteForward', (client: inputMethodEngine.InputClient) => client.deleteForward(length));
  }

  /**
   * 清空编辑框。框架没有整段删除的接口，这里读取光标前后的文字，再按长度分别删除，删除后复查直到两侧为空。
   * pressText 是按下删除键之前编辑框推送的全文。按下时已经删掉的字符或选中内容无法再读取，
   * 全文与读到的两侧文字吻合时，撤销内容取按下前的全文。
   */
  clearText(pressText: string): Promise<ClearResult> {
    const session = this.sessionId;
    const failed: ClearResult = { status: ClearStatus.FAILED, text: '', caret: 0 };
    return this.enqueueTask<ClearResult>('clearText', failed,
      async (client: inputMethodEngine.InputClient): Promise<ClearResult> => {
        const sides = await Promise.all([client.getForward(CLEAR_TEXT_LIMIT), client.getBackward(CLEAR_TEXT_LIMIT)]);
        const before = sides[0];
        const after = sides[1];
        if (before.length >= CLEAR_TEXT_LIMIT || after.length >= CLEAR_TEXT_LIMIT) {
          const tooLong: ClearResult = { status: ClearStatus.TOO_LONG, text: '', caret: 0 };
          return tooLong;
        }
        if (before.length === 0 && after.length === 0) {
          const empty: ClearResult = { status: ClearStatus.EMPTY, text: '', caret: 0 };
          return empty;
        }
        if (session !== this.sessionId) {
          return failed;
        }
        await this.deleteAround(client, before.length, after.length);
        for (let round = 0; round < CLEAR_VERIFY_ROUNDS; round++) {
          await wait(SETTLE_MS);
          if (session !== this.sessionId) {
            break;
          }
          const rest = await Promise.all([client.getForward(CLEAR_TEXT_LIMIT), client.getBackward(CLEAR_TEXT_LIMIT)]);
          if (rest[0].length === 0 && rest[1].length === 0) {
            break;
          }
          await this.deleteAround(client, rest[0].length, rest[1].length);
        }
        const matchesPress = pressText.length >= before.length + after.length && pressText.startsWith(before) &&
          pressText.endsWith(after);
        const result: ClearResult = {
          status: ClearStatus.CLEARED,
          text: matchesPress ? pressText : before + after,
          caret: matchesPress ? pressText.length - after.length : before.length
        };
        return result;
      });
  }

  /**
   * 撤销清空：编辑框仍为空时分段插入原文，再把光标放回清空前的位置。编辑框已有内容时不做任何修改。
   */
  restoreText(text: string, caret: number): Promise<boolean> {
    const session = this.sessionId;
    return this.enqueueTask<boolean>('restoreText', false,
      async (client: inputMethodEngine.InputClient): Promise<boolean> => {
        const edges = await Promise.all([client.getForward(1), client.getBackward(1)]);
        if (edges[0].length > 0 || edges[1].length > 0) {
          return false;
        }
        let start = 0;
        while (start < text.length) {
          if (session !== this.sessionId) {
            return false;
          }
          let end = Math.min(text.length, start + RESTORE_CHUNK);
          // 分段边界不能落在代理对中间，否则跨进程转码时字符会损坏
          if (end < text.length && isHighSurrogate(text.charCodeAt(end - 1))) {
            end--;
          }
          const ok = await client.insertText(text.substring(start, end));
          if (!ok) {
            return false;
          }
          start = end;
        }
        if (caret < text.length) {
          await this.placeCaret(client, session, text, caret);
        }
        return true;
      });
  }

  /**
   * 预上屏文字替换编辑框中现有的预上屏内容，文字为空时清除预上屏内容。编辑框不支持预上屏时返回 false。
   */
  setPreviewText(text: string): Promise<boolean> {
    return this.enqueueTask<boolean>('setPreviewText', false,
      async (client: inputMethodEngine.InputClient): Promise<boolean> => {
        const range: inputMethodEngine.Range = { start: -1, end: -1 };
        await client.setPreviewText(text, range);
        return true;
      });
  }

  // 结束预上屏，编辑框保留当前的预上屏文字
  finishTextPreview(): Promise<boolean> {
    return this.enqueueTask<boolean>('finishTextPreview', false,
      async (client: inputMethodEngine.InputClient): Promise<boolean> => {
        await client.finishTextPreview();
        return true;
      });
  }

  /**
   * 读取光标两侧的文字并拼接。任一侧达到 limit 时返回 undefined，调用方据此判断文字过长。
   */
  readText(limit: number): Promise<string | undefined> {
    return this.enqueueTask<string | undefined>('readText', '',
      async (client: inputMethodEngine.InputClient): Promise<string | undefined> => {
        const sides = await Promise.all([client.getForward(limit), client.getBackward(limit)]);
        if (sides[0].length >= limit || sides[1].length >= limit) {
          return undefined;
        }
        return sides[0] + sides[1];
      });
  }

  /**
   * 光标在当前行内左移或右移一个字。移动方向上紧邻换行符或已到文字两端时不移动，返回 false。
   * 自动换行没有换行符，输入法也拿不到排版结果，一段自动换行的长文字按一行处理。
   */
  moveCursorInLine(right: boolean): Promise<boolean> {
    return this.enqueueTask<boolean>('moveCursor', false,
      async (client: inputMethodEngine.InputClient): Promise<boolean> => {
        // getForward 读取光标前的文字，getBackward 读取光标后的文字
        const next = right ? await client.getBackward(1) : await client.getForward(1);
        if (next.length === 0 || next === '\n' || next === '\r') {
          return false;
        }
        await client.moveCursor(right ? inputMethodEngine.Direction.CURSOR_RIGHT :
          inputMethodEngine.Direction.CURSOR_LEFT);
        return true;
      });
  }

  sendKeyFunction(action: number): Promise<boolean> {
    return this.enqueue('sendKeyFunction', (client: inputMethodEngine.InputClient) => client.sendKeyFunction(action));
  }

  // deleteForward 删除光标前的文字，deleteBackward 删除光标后的文字
  private async deleteAround(client: inputMethodEngine.InputClient, before: number, after: number): Promise<void> {
    if (before > 0) {
      await client.deleteForward(before);
    }
    if (after > 0) {
      await client.deleteBackward(after);
    }
  }

  /**
   * 插入在下一帧生效，光标到达文末后再设置位置，避免位置被较短的旧内容截断。部分编辑框不支持查询光标，失败时保留在文末。
   * 系统输入框收到输入法设置的选区时总会弹出手柄和菜单。这里先选中光标后的一个字符，再左移一次，
   * 光标落在选区起点，菜单随之收起。
   */
  private async placeCaret(client: inputMethodEngine.InputClient, session: number, text: string,
    caret: number): Promise<void> {
    try {
      for (let round = 0; round < RESTORE_SETTLE_ROUNDS; round++) {
        if ((await client.getTextIndexAtCursor()) >= text.length) {
          break;
        }
        await wait(SETTLE_MS);
      }
      if (session !== this.sessionId) {
        return;
      }
      const end = isHighSurrogate(text.charCodeAt(caret)) ? caret + 2 : caret + 1;
      const range: inputMethodEngine.Range = { start: caret, end: Math.min(end, text.length) };
      await client.selectByRange(range);
      await client.moveCursor(inputMethodEngine.Direction.CURSOR_LEFT);
    } catch (error) {
      Log.warn(`restore caret failed, code=${(error as BusinessError).code}`);
    }
  }

  private enqueue(name: string, operation: EditorOperation): Promise<boolean> {
    const session = this.sessionId;
    return this.enqueueTask<boolean>(name, false, async (client: inputMethodEngine.InputClient): Promise<boolean> => {
      const ok = await operation(client);
      if (!ok) {
        Log.warn(`${name} returned false, session=${session}`);
      }
      return ok;
    });
  }

  private enqueueTask<T>(name: string, fallback: T,
    operation: (client: inputMethodEngine.InputClient) => Promise<T>): Promise<T> {
    const session = this.sessionId;
    const run: Promise<T> = this.tail.then(async (): Promise<T> => {
      const client = this.client;
      if (client === undefined || session !== this.sessionId) {
        return fallback;
      }
      try {
        return await operation(client);
      } catch (error) {
        const code = (error as BusinessError).code;
        Log.error(`${name} failed, code=${code}, session=${session}`);
        return fallback;
      }
    });
    this.tail = run.then((): void => {
    });
    return run;
  }
}
