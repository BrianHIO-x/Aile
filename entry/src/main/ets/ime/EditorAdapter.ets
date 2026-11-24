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
// 编辑框通常在几十毫秒内回复。超过这个时间仍未回复，队列不再等待，后续操作照常发送
const REPLY_TIMEOUT_MS: number = 500;
// 清空与撤销包含多次读写和等待刷新，整体的等待上限放宽
const MULTI_STEP_TIMEOUT_MS: number = 5000;
// 移动光标前读取旁边一个字的等待上限。超过这个时间仍未回复，就不再读取，直接移动光标
const CURSOR_QUERY_TIMEOUT_MS: number = 200;

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
  // 收到结束事件的会话。客户端仍然保留，每个会话只在日志里提示一次
  private stoppedSession: number = -1;
  private reportedSession: number = -1;
  // 编辑框不回复的会话。卓易通、出境易里的安卓编辑框执行操作后可能一直不回复，
  // 这类会话里每个操作发出后立即放行下一个，发送顺序由输入法框架保证
  private silentSession: number = -1;
  private lateReportedSession: number = -1;
  // 读不到光标两侧文字的会话，这类会话移动光标时不再先读取
  private blindCursorSession: number = -1;
  // 读到过光标旁边文字的会话。之后再读不到文字，才算光标到了文字两端
  private textSeenSession: number = -1;

  bind(client: inputMethodEngine.InputClient, sessionId: number): void {
    this.client = client;
    this.sessionId = sessionId;
  }

  /**
   * 卓易通、出境易等安卓兼容环境可能先推送新会话的开始事件，再推送旧会话的结束事件。
   * 结束事件因此不能清掉客户端，否则新会话的所有输入都会被丢弃。编辑框确实失效时，操作失败只记日志。
   */
  markStopped(sessionId: number): void {
    if (this.sessionId === sessionId) {
      this.stoppedSession = sessionId;
    }
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

  /**
   * 插入文字。verified 只在编辑框真正回复成功时调用一次：超时按已送达返回 true 时不调用，
   * 回复失败也不调用。调用方据此区分“已经发出”和“确实成功”，见 ImeController 的相邻提交学习。
   */
  insertText(text: string, verified?: () => void): Promise<boolean> {
    return this.enqueue('insertText', (client: inputMethodEngine.InputClient) => client.insertText(text), verified);
  }

  // deleteForward 删除光标前的文本
  deleteBeforeCursor(length: number): Promise<boolean> {
    return this.enqueue('deleteForward', (client: inputMethodEngine.InputClient) => client.deleteForward(length));
  }

  /**
   * 清空编辑框。框架没有整段删除的接口，这里读取光标前后的文字，再按长度分别删除，删除后复查直到两侧为空。
   * pressText 是按下删除键之前编辑框推送的全文。按住期间连续删掉的字符无法再读取，
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
      }, failed, MULTI_STEP_TIMEOUT_MS);
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
      }, true, MULTI_STEP_TIMEOUT_MS);
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
   * 卓易通、出境易里的安卓编辑框可能不回复读取，也可能读不到文字。这时不再判断行首行尾，
   * 直接发出移动，到了文字两端由编辑框自己忽略。
   */
  moveCursorInLine(right: boolean): Promise<boolean> {
    const session = this.sessionId;
    return this.enqueueTask<boolean>('moveCursor', false,
      async (client: inputMethodEngine.InputClient): Promise<boolean> => {
        const direction = right ? inputMethodEngine.Direction.CURSOR_RIGHT : inputMethodEngine.Direction.CURSOR_LEFT;
        if (session !== this.silentSession && session !== this.blindCursorSession) {
          // getForward 读取光标前的文字，getBackward 读取光标后的文字
          const next = await this.queryWithin(session, right ? client.getBackward(1) : client.getForward(1));
          if (next === '\n' || next === '\r') {
            return false;
          }
          if (next !== undefined && next.length > 0) {
            this.textSeenSession = session;
          } else if (next !== undefined && this.textSeenSession === session) {
            // 这个会话读到过文字，读不到时说明已经到了文字两端
            return false;
          }
        }
        const moving = client.moveCursor(direction);
        if (session === this.silentSession) {
          // 编辑框不回复时不等回复，否则每移动一个字都要等到超时
          moving.catch((error: BusinessError) => {
            this.reportOnce(session, `moveCursor failed, code=${error.code}, session=${session}`);
          });
          return true;
        }
        await moving;
        return true;
      });
  }

  sendKeyFunction(action: number): Promise<boolean> {
    return this.enqueue('sendKeyFunction', (client: inputMethodEngine.InputClient) => client.sendKeyFunction(action));
  }

  /**
   * 等待一次读取的结果，超时或失败时返回 undefined。读取失败的会话改为不读取直接移动光标，
   * 其他操作照常等待回复。
   */
  private queryWithin(session: number, pending: Promise<string>): Promise<string | undefined> {
    return new Promise<string | undefined>((resolve: (value: string | undefined) => void) => {
      let settled = false;
      const giveUp = (reason: string): void => {
        settled = true;
        if (this.blindCursorSession !== session) {
          this.blindCursorSession = session;
          Log.warn(`cursor query ${reason}, session=${session}`);
        }
        resolve(undefined);
      };
      const timer = setTimeout(() => giveUp(`no reply in ${CURSOR_QUERY_TIMEOUT_MS}ms`), CURSOR_QUERY_TIMEOUT_MS);
      pending.then((text: string) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(text);
        }
      }).catch((error: BusinessError) => {
        if (!settled) {
          clearTimeout(timer);
          giveUp(`failed, code=${error.code}`);
        }
      });
    });
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

  // 插入、删除与功能键等操作已经发出，编辑框迟迟不回复时按已送达处理，避免提交的文字被当作失败退回
  // onVerified 只在编辑框真的回复成功时调用，见 insertText
  private enqueue(name: string, operation: EditorOperation, onVerified?: () => void): Promise<boolean> {
    const session = this.sessionId;
    return this.enqueueTask<boolean>(name, false, async (client: inputMethodEngine.InputClient): Promise<boolean> => {
      const ok = await operation(client);
      if (!ok) {
        Log.warn(`${name} returned false, session=${session}`);
      }
      return ok;
    }, true, REPLY_TIMEOUT_MS, onVerified);
  }

  /**
   * 操作按调用顺序排队执行。前一个操作收到回复，或者等待超过 timeoutMs，下一个操作才开始。
   * 编辑框一直不回复时，这次操作按 assumed 返回，整个会话随后改为发出即放行，队列不会因此卡死。
   */
  private enqueueTask<T>(name: string, fallback: T, operation: (client: inputMethodEngine.InputClient) => Promise<T>,
    assumed: T = fallback, timeoutMs: number = REPLY_TIMEOUT_MS, onVerified?: (value: T) => void): Promise<T> {
    const session = this.sessionId;
    let release: () => void = () => {
    };
    const gate = new Promise<void>((resolve: (value: void | PromiseLike<void>) => void) => {
      release = () => resolve();
    });
    const previous = this.tail;
    this.tail = gate;
    return previous.then(async (): Promise<T> => {
      try {
        const client = this.client;
        if (client === undefined || session !== this.sessionId) {
          if (client === undefined) {
            this.reportOnce(session, `${name} dropped, no client, session=${session}`);
          }
          return fallback;
        }
        if (session === this.stoppedSession) {
          this.reportOnce(session, `${name} after inputStop, session=${session}`);
        }
        const pending = operation(client);
        if (session === this.silentSession) {
          release();
        }
        return await this.awaitReply<T>(name, session, pending, fallback, assumed, timeoutMs, onVerified);
      } finally {
        release();
      }
    });
  }

  /**
   * 等待编辑框回复。超时后返回 assumed，并把会话标记为不回复；迟到的回复只在日志里记一次耗时，帮助判断编辑框是否只是太慢。
   */
  private awaitReply<T>(name: string, session: number, pending: Promise<T>, fallback: T, assumed: T,
    timeoutMs: number, onVerified?: (value: T) => void): Promise<T> {
    return new Promise<T>((resolve: (value: T | PromiseLike<T>) => void) => {
      const start = Date.now();
      let settled = false;
      const timer = setTimeout(() => {
        settled = true;
        if (this.silentSession !== session) {
          this.silentSession = session;
          Log.warn(`${name} no reply in ${timeoutMs}ms, session=${session}`);
        }
        resolve(assumed);
      }, timeoutMs);
      pending.then((value: T) => {
        if (settled) {
          this.reportLate(session, `${name} replied after ${Date.now() - start}ms, session=${session}`);
          return;
        }
        settled = true;
        clearTimeout(timer);
        // 排队执行时这一次操作还在队首，先回调再放行下一个，回调顺序与提交顺序一致
        if (onVerified !== undefined) {
          onVerified(value);
        }
        resolve(value);
      }).catch((error: BusinessError) => {
        Log.error(`${name} failed, code=${error.code}, session=${session}`);
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(fallback);
        }
      });
    });
  }

  private reportLate(session: number, message: string): void {
    if (this.lateReportedSession !== session) {
      this.lateReportedSession = session;
      Log.warn(message);
    }
  }

  private reportOnce(session: number, message: string): void {
    if (this.reportedSession !== session) {
      this.reportedSession = session;
      Log.warn(message);
    }
  }
}
