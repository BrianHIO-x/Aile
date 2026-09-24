import {
  Candidate,
  CandidateProvider,
  CandidateSource,
  LetterAlternative,
  QueryOptions,
  RawCandidateProvider
} from '../engine/EngineTypes';
import { NO_TAP, TapSample } from '../keyboard/TouchModel';

export const CANDIDATE_LIMIT: number = 150;
const SEPARATOR_CHAR: string = '\'';
const MAX_CODE_LENGTH: number = 64;

export interface CommitSegment {
  text: string;
  code: string;
  syllables: string[];
  source: CandidateSource;
  // 这段拼音每个字母的按键落点记录，撤回片段后纠错仍然有效
  alternatives: LetterAlternative[][];
  // 与 code 逐字对应的落点，提交成功后用来学习每个按键的偏移
  taps: TapSample[];
}

export interface CommitResult {
  text: string;
  segments: CommitSegment[];
  raw: boolean;
}

export interface CompositionSnapshot {
  rawCode: string;
  alternatives: LetterAlternative[][];
  taps: TapSample[];
  segments: CommitSegment[];
}

/**
 * 提交成功后接收学习事件的对象，由用户词库实现。
 */
export interface CommitLearner {
  learn(result: CommitResult, previousText: string): void;
  flush(): void;
  clear(): void;
  forget(syllables: string[], word: string): boolean;
}

/**
 * 组词状态机：已选片段暂存在候选栏，剩余拼音继续组词，全部消费后一次性产生提交结果。
 */
export class CompositionController {
  private provider: CandidateProvider = new RawCandidateProvider();
  private rawCode: string = '';
  // 与 rawCode 逐字对应的按键落点记录，数组只整体替换，已交给引擎的查询选项不会被改动
  private alternatives: LetterAlternative[][] = [];
  // 与 rawCode 逐字对应的落点，与 alternatives 一样只整体替换
  private taps: TapSample[] = [];
  private fuzzy: boolean = false;
  private queryOptions: QueryOptions = { fuzzy: false, alternatives: [] };
  private segments: CommitSegment[] = [];
  private candidates: Candidate[] = [];
  private previousText: string = '';
  private revision: number = 0;

  setProvider(provider: CandidateProvider): void {
    this.provider = provider;
    this.refresh();
  }

  getRevision(): number {
    return this.revision;
  }

  isComposing(): boolean {
    return this.rawCode.length > 0 || this.segments.length > 0;
  }

  getCandidates(): Candidate[] {
    return this.candidates;
  }

  getRawCode(): string {
    return this.rawCode;
  }

  setPreviousText(text: string): void {
    this.previousText = text;
  }

  setFuzzy(fuzzy: boolean): void {
    if (this.fuzzy === fuzzy) {
      return;
    }
    this.fuzzy = fuzzy;
    this.refresh();
  }

  preeditText(): string {
    let text = '';
    for (const segment of this.segments) {
      text += segment.text;
    }
    if (this.rawCode.length > 0) {
      text += this.provider.isReady() ? this.provider.formatCode(this.rawCode, this.queryOptions) : this.rawCode;
    }
    return text;
  }

  /**
   * alternatives 为这次按键落点附近的其他字母，分隔符与没有落点记录的输入为空数组。
   */
  appendCode(ch: string, alternatives: LetterAlternative[] = [], tap: TapSample = NO_TAP): void {
    if (this.rawCode.length >= MAX_CODE_LENGTH) {
      return;
    }
    this.rawCode += ch;
    this.alternatives = this.alternatives.concat([alternatives]);
    this.taps = this.taps.concat([tap]);
    this.refresh();
  }

  /**
   * 分词键插入音节分隔符，拼音为空或末尾已是分隔符时忽略。
   */
  appendSeparator(): boolean {
    if (this.rawCode.length === 0 || this.rawCode.endsWith(SEPARATOR_CHAR)) {
      return false;
    }
    this.appendCode(SEPARATOR_CHAR);
    return true;
  }

  /**
   * 优先删除拼音字母，拼音为空时撤回最后一个已选片段并恢复其拼音。
   */
  backspace(): boolean {
    if (this.rawCode.length > 0) {
      this.rawCode = this.rawCode.substring(0, this.rawCode.length - 1);
      this.alternatives = this.alternatives.slice(0, this.rawCode.length);
      this.taps = this.taps.slice(0, this.rawCode.length);
      this.refresh();
      return true;
    }
    if (this.segments.length > 0) {
      const last = this.segments.pop() as CommitSegment;
      this.rawCode = last.code;
      this.alternatives = last.alternatives;
      this.taps = last.taps;
      this.refresh();
      return true;
    }
    return false;
  }

  select(index: number): CommitResult | undefined {
    if (index < 0 || index >= this.candidates.length) {
      return undefined;
    }
    const candidate = this.candidates[index];
    const consumed = Math.max(1, Math.min(candidate.consumedCodeLength, this.rawCode.length));
    const segment: CommitSegment = {
      text: candidate.text,
      code: this.rawCode.substring(0, consumed),
      syllables: candidate.syllables,
      source: candidate.source,
      alternatives: this.alternatives.slice(0, consumed),
      taps: this.taps.slice(0, consumed)
    };
    this.segments.push(segment);
    this.rawCode = this.rawCode.substring(consumed);
    this.alternatives = this.alternatives.slice(consumed);
    this.taps = this.taps.slice(consumed);
    if (this.rawCode.length === 0) {
      return this.finish(false);
    }
    this.refresh();
    return undefined;
  }

  selectFirst(): CommitResult | undefined {
    if (this.rawCode.length === 0 && this.segments.length > 0) {
      return this.finish(false);
    }
    if (this.candidates.length === 0) {
      return this.isComposing() ? this.commitRaw() : undefined;
    }
    return this.select(0);
  }

  /**
   * 连续确认首候选直到全部消费，用于标点、翻页等需要立即结束组词的场景。
   */
  commitBest(): CommitResult | undefined {
    let guard = 0;
    while (this.isComposing() && guard < MAX_CODE_LENGTH) {
      const result = this.selectFirst();
      if (result !== undefined) {
        return result;
      }
      guard++;
    }
    return this.isComposing() ? this.commitRaw() : undefined;
  }

  /**
   * 已选片段保留汉字，剩余拼音按原文提交，结果不参与学习。
   */
  commitRaw(): CommitResult {
    if (this.rawCode.length > 0) {
      const segment: CommitSegment = {
        text: this.rawCode, code: this.rawCode, syllables: [], source: CandidateSource.RAW,
        alternatives: this.alternatives, taps: this.taps
      };
      this.segments.push(segment);
      this.rawCode = '';
      this.alternatives = [];
      this.taps = [];
    }
    return this.finish(true);
  }

  snapshot(): CompositionSnapshot {
    const copy: CompositionSnapshot = {
      rawCode: this.rawCode, alternatives: this.alternatives, taps: this.taps, segments: this.segments.slice()
    };
    return copy;
  }

  restore(snapshot: CompositionSnapshot): void {
    this.rawCode = snapshot.rawCode;
    this.alternatives = snapshot.alternatives;
    this.taps = snapshot.taps;
    this.segments = snapshot.segments.slice();
    this.refresh();
  }

  reset(): void {
    this.rawCode = '';
    this.alternatives = [];
    this.taps = [];
    this.segments = [];
    this.candidates = [];
    this.revision++;
  }

  refresh(): void {
    this.revision++;
    if (this.rawCode.length === 0) {
      this.candidates = [];
      return;
    }
    const context = this.contextText();
    this.queryOptions = { fuzzy: this.fuzzy, alternatives: this.alternatives };
    this.candidates = this.provider.query(this.rawCode, context, CANDIDATE_LIMIT, this.queryOptions);
  }

  private contextText(): string {
    if (this.segments.length > 0) {
      return this.segments[this.segments.length - 1].text;
    }
    return this.previousText;
  }

  private finish(raw: boolean): CommitResult {
    let text = '';
    for (const segment of this.segments) {
      text += segment.text;
    }
    const result: CommitResult = { text: text, segments: this.segments, raw: raw };
    this.segments = [];
    this.rawCode = '';
    this.alternatives = [];
    this.taps = [];
    this.candidates = [];
    this.revision++;
    return result;
  }
}
