import { CommitSegment } from './CompositionController';
import { isContinuableSegment } from '../engine/UserLexicon';

// 两次确认之间的最长间隔：从前一次确认发起算起，到下一次确认发起为止。
// 用户分两次打一个词时动作接连发生，超过这个间隔的多半是两段不相干的话
export const CONTINUATION_WINDOW_MS: number = 3000;
// 同时等待回执的提交最多记这么多个，更早的直接忘掉
const MAX_PENDING_COMMITS: number = 8;

/**
 * 一次提交里可以参与组合学习的片段：用户明确确认过的真实词，按顺序完整返回。
 * 只要有一段不能参与学习（原文、合成整句、学到的组合续接、音节与字数对不上），这次提交就整体不参与：
 * 过滤掉不合格的段再取首尾，会把中间隔着别的文字的片段当成前后紧挨着的一对，学出根本不存在的组合。
 */
export function continuableSegments(segments: CommitSegment[], raw: boolean): CommitSegment[] {
  const result: CommitSegment[] = [];
  if (raw || segments.length === 0) {
    return result;
  }
  for (const segment of segments) {
    if (!isContinuableSegment(segment)) {
      return result;
    }
  }
  return segments.slice();
}

/**
 * 一次提交的发起信息。发起时就把序号、会话、上下文代次与时间记下来，
 * 异步插入排队的顺序与实际成功顺序不一致时据此核对，见 EditorAdapter.insertText 的 verified。
 */
export interface ContinuationStart {
  // 提交发起序号，由输入法总控递增，同一序号只对应一次提交
  commitId: number;
  // 编辑框会话编号，换编辑框以后旧提交不能再连
  session: number;
  // 这次提交之前的上下文代次：相邻两次确认之间只允许这一次上下文更新
  generation: number;
  // 动作发起时间，两次确认按发起时间计算间隔
  actionTime: number;
  // 这次提交里可以参与组合学习的片段，按顺序；空表示这次提交不参与
  segments: CommitSegment[];
}

// 可以学习的一对片段：上一次确认的最后一段与这一次确认的第一段
export interface ContinuationPair {
  previous: CommitSegment;
  next: CommitSegment;
}

interface PendingCommit {
  commitId: number;
  session: number;
  generation: number;
  actionTime: number;
  first: CommitSegment;
  tail: CommitSegment;
}

/**
 * 相邻两次确认的组合学习：只做纯状态判断，不读写编辑框文字，也不保存宿主文字。
 *
 * 只有同时满足下面几条的两次明确提交才连成一条续接：同一个编辑框会话、序号正好相邻、
 * 上下文只前进了一代（中间没有标点、空格、回车、数字、英文、剪贴板、删除、清空等改动上下文或文字的
 * 动作）、发起时间在 CONTINUATION_WINDOW_MS 以内，而且两次都收到了编辑框真正成功的回执。
 * 任何可能把两次确认隔开的动作都调用 break，打断以后旧提交不会再连上后面的提交。
 */
export class ContinuationTracker {
  private session: number = -1;
  private commitId: number = 0;
  private generation: number = -1;
  private actionTime: number = 0;
  private tail: CommitSegment | undefined = undefined;
  // 已经发起、还没有收到回执的提交，按发起顺序排列
  private pending: PendingCommit[] = [];
  // 自己插入、还没有被选区变化核对的字数
  private ownCaret: number = 0;
  // 宿主推送过的全文长度，-1 表示还不知道。只记长度，不保存用户文字
  private observedLength: number = -1;
  // 自己改动文字以后可以出现的全文长度，按从小到大排队。两次快速确认各自回推一次时都算对得上
  private expectedLengths: number[] = [];

  // 新会话与清空时调用：已经记下的组合线索全部作废
  reset(): void {
    this.pending = [];
    this.tail = undefined;
    this.ownCaret = 0;
    this.observedLength = -1;
    this.expectedLengths = [];
    this.session = -1;
    this.commitId = 0;
    this.generation = -1;
    this.actionTime = 0;
  }

  // 打断相邻关系：上一个成功提交不再与后面的提交连成一条续接
  break(): void {
    this.pending = [];
    this.tail = undefined;
    this.ownCaret = 0;
  }

  /**
   * 提交发起。segments 为空时这次提交不参与组合学习，直接打断。
   * 只有真正成功的回执才会让这次提交成为下一次的前一段，见 verified。
   */
  start(input: ContinuationStart): void {
    if (input.segments.length === 0) {
      this.break();
      return;
    }
    const first = input.segments[0];
    const tail = input.segments[input.segments.length - 1];
    const entry: PendingCommit = {
      commitId: input.commitId,
      session: input.session,
      generation: input.generation,
      actionTime: input.actionTime,
      first: first,
      tail: tail
    };
    this.pending.push(entry);
    while (this.pending.length > MAX_PENDING_COMMITS) {
      this.pending.shift();
    }
  }

  /**
   * 编辑框真正回复成功。返回可以学习的一对片段：上一次成功提交的最后一段与这一次的第一段。
   * 序号在这个已回执提交之前、却一直没有回执的提交说明它没有成功，不能让后面连到更早的一次。
   */
  verified(commitId: number): ContinuationPair | undefined {
    let index = -1;
    for (let i = 0; i < this.pending.length; i++) {
      if (this.pending[i].commitId === commitId) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      return undefined;
    }
    const entry = this.pending[index];
    const stale = index > 0;
    this.pending.splice(0, index + 1);
    let pair: ContinuationPair | undefined = undefined;
    if (!stale && this.canLink(entry)) {
      const previous = this.tail;
      if (previous !== undefined) {
        pair = { previous: previous, next: entry.first };
      }
    }
    this.session = entry.session;
    this.commitId = entry.commitId;
    this.generation = entry.generation;
    this.actionTime = entry.actionTime;
    this.tail = entry.tail;
    return pair;
  }

  // 编辑框回复失败或这次提交没有成功：它不会成为下一次的前一段，后面的提交也不能越过它去连
  failed(commitId: number): void {
    let index = -1;
    for (let i = 0; i < this.pending.length; i++) {
      if (this.pending[i].commitId === commitId) {
        index = i;
        break;
      }
    }
    if (index >= 0) {
      this.pending.splice(0, index + 1);
    }
    this.tail = undefined;
  }

  private canLink(entry: PendingCommit): boolean {
    if (this.tail === undefined) {
      return false;
    }
    if (entry.session !== this.session) {
      return false;
    }
    if (entry.commitId !== this.commitId + 1) {
      return false;
    }
    // 中间不允许再有别的上下文更新：字母组词不更新上下文，标点、空格、数字、英文、删除都会
    if (entry.generation !== this.generation + 1) {
      return false;
    }
    const elapsed = entry.actionTime - this.actionTime;
    return elapsed >= 0 && elapsed <= CONTINUATION_WINDOW_MS;
  }

  // ---------- 宿主改动核对：只记长度与光标位移，不保存文字 ----------

  // 自己插入的文字，等宿主回推全文或选区时核对
  noteOwnInsert(length: number): void {
    if (length <= 0) {
      return;
    }
    this.ownCaret += length;
    if (this.observedLength >= 0) {
      const last = this.expectedLengths.length > 0 ? this.expectedLengths[this.expectedLengths.length - 1] :
        this.observedLength;
      this.expectedLengths.push(last + length);
      while (this.expectedLengths.length > MAX_PENDING_COMMITS) {
        this.expectedLengths.shift();
      }
    }
  }

  // 自己删除的文字。删除本身会打断相邻关系，这里只把长度核对追平
  noteOwnDelete(length: number): void {
    if (length <= 0) {
      return;
    }
    this.ownCaret -= length;
    if (this.ownCaret < 0) {
      this.ownCaret = 0;
    }
    if (this.observedLength >= 0) {
      const last = this.expectedLengths.length > 0 ? this.expectedLengths[this.expectedLengths.length - 1] :
        this.observedLength;
      this.expectedLengths.push(Math.max(0, last - length));
    }
  }

  /**
   * 宿主推送全文时核对长度：只比长度，不看内容。长度是自己改动以后可能出现的那几个之一，
   * 说明中间只有自己的插入；其它长度说明宿主或用户在别处改了文字，返回 true 表示要打断。
   * 两次快速确认各自回推一次时，两个长度都在队列里，先到的那个不会误判。
   */
  noteTextLength(length: number): boolean {
    if (this.observedLength < 0) {
      // 第一次推送只能当作基准，之前有没有别的改动已经看不出来
      this.observedLength = length;
      this.expectedLengths = [];
      return false;
    }
    if (this.expectedLengths.length === 0) {
      if (length === this.observedLength) {
        return false;
      }
      this.observedLength = length;
      this.break();
      return true;
    }
    let index = -1;
    for (let i = 0; i < this.expectedLengths.length; i++) {
      if (this.expectedLengths[i] === length) {
        index = i;
        break;
      }
    }
    if (index >= 0) {
      // 排在它前面、比它小的那些长度已经被这次推送盖过去了
      this.expectedLengths.splice(0, index + 1);
      this.observedLength = length;
      return false;
    }
    this.expectedLengths = [];
    this.observedLength = length;
    this.break();
    return true;
  }

  /**
   * 选区变化：自己的插入会让光标正好往后走一部分或全部待核对字数，两次快速确认各自回推一次时
   * 每次只走一部分，因此小于待核对字数的位移也算对得上。其它变化（挪光标、选中别的文字、
   * 宿主替换内容）都说明两次确认不再紧挨着同一处，返回 true 表示要打断。
   */
  noteSelection(oldBegin: number, oldEnd: number, newBegin: number, newEnd: number): boolean {
    // 前后两次都必须是光标（两端相等）：原本有选区、或者新选区不是光标都说明中间选过别的东西，
    // 反过来的范围（begin > end）同样不正常，这几种都不再尝试判断
    if (oldBegin !== oldEnd || newBegin !== newEnd || oldBegin < 0 || newBegin < 0) {
      this.break();
      return true;
    }
    const delta = newBegin - oldBegin;
    if (delta === 0) {
      // 选区没有变化：保留待核对字数，等下一次真正移动光标的推送再判断
      return false;
    }
    if (delta > 0 && this.ownCaret > 0 && delta <= this.ownCaret) {
      this.ownCaret -= delta;
      return false;
    }
    this.break();
    return true;
  }

  // 诊断用：当前是否还留着上一次成功提交
  hasPrevious(): boolean {
    return this.tail !== undefined;
  }
}
