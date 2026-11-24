import {
  Candidate,
  CandidateMeta,
  CandidateOrigin,
  CandidateProvider,
  CandidateSource,
  LetterAlternative,
  QueryOptions,
  RawCandidateProvider
} from '../engine/EngineTypes';
import { NO_TAP, TapSample } from '../keyboard/TouchModel';
import { CandidateView } from './ImeState';
import {
  CandidateSnapshot,
  charsSupplementLimit,
  emptyCandidateSnapshot,
  isSingleCharacter,
  rankCandidates
} from './CandidateRanking';

export const CANDIDATE_LIMIT: number = 150;
const SEPARATOR_CHAR: string = '\'';
const MAX_CODE_LENGTH: number = 64;
// 学到的组合续接每次最多补几条，补在固定项或引擎首选之后的前几位
const CONTINUATION_LIMIT: number = 2;
// 自由选词左侧按首音节筛选时，从引擎补查该音节单字条数的上限
const SYLLABLE_SUPPLEMENT_LIMIT: number = 40;

export interface CommitSegment {
  text: string;
  code: string;
  syllables: string[];
  source: CandidateSource;
  // 这段拼音每个字母的按键落点记录，撤回片段后纠错仍然有效
  alternatives: LetterAlternative[][];
  // 与 code 逐字对应的落点，提交成功后用来学习每个按键的偏移
  taps: TapSample[];
  // 这一段候选的来源，学到的组合续接为 CONTINUATION。来自词库的片段与旧调用方没有这一项
  origin?: CandidateOrigin;
}

export interface CommitResult {
  text: string;
  segments: CommitSegment[];
  raw: boolean;
}

/**
 * 一次点按候选的解析结果。accepted 为 false 表示事件来自旧版本或与当前候选不符，调用方不应刷新候选。
 */
export interface CandidateSelection {
  accepted: boolean;
  result: CommitResult | undefined;
}

// 候选消耗的字符数必须是正整数，并且不超过当前剩余的拼音
function validConsumed(length: number, codeLength: number): boolean {
  return length > 0 && length <= codeLength && Math.floor(length) === length;
}

// 候选的来源标记，词库候选与旧版本候选按 LEXICON 处理
function originOf(candidate: Candidate): CandidateOrigin {
  const meta = candidate.meta;
  return meta !== undefined && meta.origin !== undefined ? meta.origin : CandidateOrigin.LEXICON;
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
  /**
   * 前后两次提交真的相邻时调用：上一次提交的最后一段与这一次提交的第一段都来自用户明确确认的真实词，
   * 中间没有标点、空格、回车、光标移动、宿主改动或会话切换，两次都在学习开启的同一个编辑框里提交成功。
   * 学习器把后一段记成前一段的续接，下次输入串与上一次的拼音完全相等时补一条组合候选。
   * 是否相邻由 ContinuationTracker 判定，本方法只负责记录。
   */
  learnContinuation(previous: CommitSegment, next: CommitSegment): void;
  flush(): void;
  clear(): void;
}

/**
 * 用户长按候选做的固定首位与删除，由用户词库实现。code 为候选消耗的那段拼音，原样包括分隔符。
 */
export interface CandidateRules {
  // 引擎列出候选以后调用：去掉删除过的候选，把这串拼音固定的候选挪到首位
  arrange(code: string, candidates: Candidate[]): Candidate[];
  isPinned(code: string, word: string): boolean;
  pin(code: string, syllables: string[], word: string): void;
  unpin(code: string): void;
  remove(syllables: string[], word: string): void;
  restoreRemoved(): boolean;
  /**
   * 学到的组合续接：只有输入串与记下的码完全相等、而且前一个词正好读完整串列在这次候选里时，
   * 才返回由这两个词合成的外层候选。返回的候选由组词控制器补在候选池第二位，
   * 不进入音节词格、简拼与 Viterbi；删除与固定仍由 arrange 过滤和复排。
   */
  suggestContinuations(code: string, candidates: Candidate[]): Candidate[];
}

/**
 * 组词状态机：已选片段暂存在候选栏，剩余拼音继续组词，全部消费后一次性产生提交结果。
 */
export class CompositionController {
  private provider: CandidateProvider = new RawCandidateProvider();
  private rules: CandidateRules | undefined = undefined;
  private rawCode: string = '';
  // 与 rawCode 逐字对应的按键落点记录，数组只整体替换，已交给引擎的查询选项不会被改动
  private alternatives: LetterAlternative[][] = [];
  // 与 rawCode 逐字对应的落点，与 alternatives 一样只整体替换
  private taps: TapSample[] = [];
  private fuzzy: boolean = false;
  private queryOptions: QueryOptions = { fuzzy: false, alternatives: [] };
  private segments: CommitSegment[] = [];
  private candidates: Candidate[] = [];
  // 候选池对应的普通栏、全部、词语、单字顺序，随候选一起生成，界面只消费这一份快照
  private rankedSnapshot: CandidateSnapshot = emptyCandidateSnapshot();
  // 未按左侧首音节筛选前的完整候选池与排序快照，取消拼音筛选时直接恢复
  private baseCandidates: Candidate[] = [];
  private baseSnapshot: CandidateSnapshot = emptyCandidateSnapshot();
  // 自由选词当前选中的首音节筛选，空串表示未筛选
  private activeSyllable: string = '';
  // 主查询返回的拼音切分。补查会覆盖引擎的最近一次查询，显示切分因此在主查询之后单独留一份
  private formattedCode: string = '';
  private previousText: string = '';
  private revision: number = 0;

  setProvider(provider: CandidateProvider): void {
    this.provider = provider;
    this.refresh();
  }

  setRules(rules: CandidateRules | undefined): void {
    this.rules = rules;
    this.refresh();
  }

  getRevision(): number {
    return this.revision;
  }

  // 已经选定的汉字片段，显示在拼音前面
  chosenText(): string {
    let text = '';
    for (const segment of this.segments) {
      text += segment.text;
    }
    return text;
  }

  isComposing(): boolean {
    return this.rawCode.length > 0 || this.segments.length > 0;
  }

  getCandidates(): Candidate[] {
    return this.candidates;
  }

  // 与 getCandidates 同一版本的排序快照：数字是候选池里的原始序号
  getSnapshot(): CandidateSnapshot {
    return this.rankedSnapshot;
  }

  getBaseCandidates(): Candidate[] {
    return this.baseCandidates;
  }

  getBaseSnapshot(): CandidateSnapshot {
    return this.baseSnapshot;
  }

  getActiveSyllable(): string {
    return this.activeSyllable;
  }

  isFuzzy(): boolean {
    return this.fuzzy;
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
    let text = this.chosenText();
    if (this.rawCode.length > 0) {
      text += this.formattedCode;
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

  /**
   * 点按候选栏或自由选词里的候选。view 必须属于当前组词版本，并且 id、文字与消耗长度都与当前候选一致，
   * 否则视为陈旧事件直接返回 accepted: false，不刷新候选。
   */
  selectCandidate(view: CandidateView): CandidateSelection {
    const candidate = this.resolveView(view);
    if (candidate === undefined) {
      const rejected: CandidateSelection = { accepted: false, result: undefined };
      return rejected;
    }
    const selection: CandidateSelection = { accepted: true, result: this.take(candidate, view.consumedCodeLength) };
    return selection;
  }

  /**
   * 长按菜单等需要确认候选仍属于当前版本的地方。返回 undefined 表示这一版候选已经失效。
   */
  matchCandidate(view: CandidateView): Candidate | undefined {
    return this.resolveView(view);
  }

  // view 消耗的那段拼音，view 已经失效时为空串
  consumedCodeFor(view: CandidateView): string {
    if (this.resolveView(view) === undefined) {
      return '';
    }
    return this.rawCode.substring(0, view.consumedCodeLength);
  }

  selectFirst(): CommitResult | undefined {
    if (this.rawCode.length === 0 && this.segments.length > 0) {
      return this.finish(false);
    }
    // 空格与普通栏第一项一致：排序可能把完整读音的单字提到引擎首选之前
    for (const index of this.rankedSnapshot.bar) {
      if (index >= 0 && index < this.candidates.length) {
        const candidate = this.candidates[index];
        if (validConsumed(candidate.consumedCodeLength, this.rawCode.length)) {
          return this.take(candidate, candidate.consumedCodeLength);
        }
      }
    }
    for (const candidate of this.candidates) {
      if (validConsumed(candidate.consumedCodeLength, this.rawCode.length)) {
        return this.take(candidate, candidate.consumedCodeLength);
      }
    }
    return this.isComposing() ? this.commitRaw() : undefined;
  }

  private resolveView(view: CandidateView): Candidate | undefined {
    if (view.revision !== this.revision) {
      return undefined;
    }
    if (!validConsumed(view.consumedCodeLength, this.rawCode.length)) {
      return undefined;
    }
    if (view.index < 0 || view.index >= this.candidates.length || Math.floor(view.index) !== view.index) {
      return undefined;
    }
    const candidate = this.candidates[view.index];
    if (candidate.id !== view.id || candidate.text !== view.text ||
      candidate.consumedCodeLength !== view.consumedCodeLength) {
      return undefined;
    }
    return candidate;
  }

  // 消费掉候选对应的前缀，并把同一段落的 alternatives 与 taps 一起切走
  private take(candidate: Candidate, consumed: number): CommitResult | undefined {
    const segment: CommitSegment = {
      text: candidate.text,
      code: this.rawCode.substring(0, consumed),
      syllables: candidate.syllables,
      source: candidate.source,
      origin: originOf(candidate),
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

  /**
   * 连续确认首候选直到全部消费，用于标点、翻页等需要立即结束组词的场景。
   */
  commitBest(): CommitResult | undefined {
    if (this.activeSyllable.length > 0) {
      this.setSyllableFilter('', 0);
    }
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
    this.rankedSnapshot = emptyCandidateSnapshot();
    this.baseCandidates = [];
    this.baseSnapshot = emptyCandidateSnapshot();
    this.activeSyllable = '';
    this.formattedCode = '';
    this.revision++;
  }

  /**
   * 按自由选词左侧选中的首音节筛选当前候选，不改写原始拼音输入；传入空串恢复完整候选。
   * consumedLength 为补查该音节单字时从 rawCode 开头消耗的字符数（0 表示仅筛已有候选）。
   */
  setSyllableFilter(syllable: string, consumedLength: number): void {
    if (syllable.length === 0 || this.rawCode.length === 0) {
      if (this.activeSyllable.length === 0) {
        return;
      }
      this.activeSyllable = '';
      this.candidates = this.baseCandidates;
      this.rankedSnapshot = this.baseSnapshot;
      this.revision++;
      return;
    }
    this.activeSyllable = syllable;
    const filtered: Candidate[] = [];
    const order = this.baseSnapshot.all;
    for (const index of order) {
      if (index < 0 || index >= this.baseCandidates.length) {
        continue;
      }
      const candidate = this.baseCandidates[index];
      if (candidate.source !== CandidateSource.RAW && candidate.syllables.length > 0 &&
        candidate.syllables[0] === syllable && !this.containsText(filtered, candidate.text)) {
        filtered.push(candidate);
      }
    }
    if (consumedLength > 0 && consumedLength <= this.rawCode.length) {
      const extra = this.supplementSyllable(syllable, consumedLength, filtered);
      for (const candidate of extra) {
        filtered.push(candidate);
      }
    }
    const snapshot = rankCandidates(this.rawCode, filtered, false);
    this.candidates = filtered;
    this.rankedSnapshot = snapshot;
    this.revision++;
  }

  refresh(): void {
    this.revision++;
    this.activeSyllable = '';
    if (this.rawCode.length === 0) {
      this.candidates = [];
      this.rankedSnapshot = emptyCandidateSnapshot();
      this.baseCandidates = [];
      this.baseSnapshot = emptyCandidateSnapshot();
      this.formattedCode = '';
      return;
    }
    const context = this.contextText();
    this.queryOptions = { fuzzy: this.fuzzy, alternatives: this.alternatives };
    const candidates = this.provider.query(this.rawCode, context, CANDIDATE_LIMIT, this.queryOptions);
    // 主查询还在引擎的最近一次查询缓存里，先把拼音切分取出来；后面的补查会覆盖那份缓存
    this.formattedCode = this.provider.isReady() ? this.provider.formatCode(this.rawCode, this.queryOptions) :
      this.rawCode;
    // 用户词库与中文词库一起加载，加载好以前没有固定与删除的记录
    const rules = this.rules;
    let pool = rules !== undefined ? rules.arrange(this.rawCode, candidates) : candidates;
    // 学到的组合续接按完整输入串补在固定项与引擎首选之后，见 withContinuations
    if (rules !== undefined) {
      pool = this.withContinuations(rules, pool);
    }
    // 用户显式固定的首位不动，其余排序照常
    const pinnedFirst = this.isPinnedFirst(pool);
    let snapshot = rankCandidates(this.rawCode, pool, pinnedFirst);
    // 截断到上限以后一个单字都没有时，按已经读通的第一个音节补一页有界候选，
    // 词语与单字筛选才不会是空的；只补这一页，不重跑整串查询
    if (snapshot.chars.length === 0) {
      const extra = this.supplementChars(pool);
      if (extra.length > 0) {
        pool = pool.concat(extra);
        snapshot = rankCandidates(this.rawCode, pool, pinnedFirst);
      }
    }
    this.baseCandidates = pool;
    this.baseSnapshot = snapshot;
    this.candidates = pool;
    this.rankedSnapshot = snapshot;
  }

  /**
   * 候选池被上限截断以后一个单字都没有时，按首选候选已经读通的第一个音节补一页单字。
   * 只在这个音节原样出现在输入开头、而且后面还有输入时补；补出来的候选正好读完这个音节，
   * 紧跟其后的显式分隔符一并消耗，剩余拼音不会从撇号开始。只收单字、同文本去重，条数有上限。
   * 调用前主查询的拼音切分已经存进 formattedCode，补查覆盖引擎缓存不会影响预编辑显示。
   */
  private supplementChars(pool: Candidate[]): Candidate[] {
    if (this.rawCode.length < 2 || pool.length === 0) {
      return [];
    }
    const syllables = pool[0].syllables;
    if (syllables.length === 0) {
      return [];
    }
    const syllable = syllables[0];
    if (syllable.length === 0 || syllable.length >= this.rawCode.length ||
      this.rawCode.substring(0, syllable.length) !== syllable) {
      return [];
    }
    const limit = charsSupplementLimit();
    const options: QueryOptions = {
      fuzzy: this.fuzzy,
      alternatives: this.alternatives.slice(0, syllable.length)
    };
    return this.collectSyllableSupplement(syllable, syllable.length, limit, options, pool, true);
  }

  private supplementSyllable(syllable: string, consumedLength: number, existing: Candidate[]): Candidate[] {
    const options: QueryOptions = { fuzzy: false, alternatives: [] };
    return this.collectSyllableSupplement(syllable, consumedLength, SYLLABLE_SUPPLEMENT_LIMIT, options, existing,
      false);
  }

  private collectSyllableSupplement(syllable: string, consumedLength: number, limit: number, options: QueryOptions,
    existing: Candidate[], singleCharOnly: boolean): Candidate[] {
    let consumed = consumedLength;
    while (consumed < this.rawCode.length && this.rawCode.charAt(consumed) === SEPARATOR_CHAR) {
      consumed++;
    }
    if (!validConsumed(consumed, this.rawCode.length)) {
      return [];
    }
    const queried = this.provider.query(syllable, this.contextText(), limit, options);
    const rules = this.rules;
    const arranged = rules !== undefined ? rules.arrange(syllable, queried) : queried;
    const extra: Candidate[] = [];
    for (const candidate of arranged) {
      if (candidate.source === CandidateSource.RAW || candidate.consumedCodeLength !== syllable.length) {
        continue;
      }
      if (singleCharOnly) {
        if (!isSingleCharacter(candidate.text)) {
          continue;
        }
      } else if (candidate.syllables.length !== 1 || candidate.syllables[0] !== syllable) {
        continue;
      }
      if (this.containsText(existing, candidate.text) || this.containsText(extra, candidate.text)) {
        continue;
      }
      extra.push(this.withConsumed(candidate, consumed));
      if (extra.length >= limit) {
        break;
      }
    }
    return extra;
  }

  // 补查得到的单字按主串的位置改写消耗长度，id 跟着消耗长度走，原来的读音与来源不变
  private withConsumed(candidate: Candidate, consumed: number): Candidate {
    const adjusted: Candidate = {
      id: `${consumed}_${candidate.text}`,
      text: candidate.text,
      consumedCodeLength: consumed,
      syllables: candidate.syllables,
      score: candidate.score,
      source: candidate.source
    };
    const meta = candidate.meta;
    if (meta !== undefined) {
      const next: CandidateMeta = {
        reading: meta.reading,
        complete: consumed === this.rawCode.length,
        safeEnd: true,
        exactConsumed: meta.exactConsumed
      };
      if (meta.origin !== undefined) {
        next.origin = meta.origin;
      }
      adjusted.meta = next;
    }
    return adjusted;
  }

  /**
   * 学到的组合续接插在候选池第二位：第一个仍是固定首位或引擎首选，续接只占非固定项的前几位。
   * 只按完整输入串查询，不改动引擎列出的候选与它们的分数；已经有同文本候选时不再重复补，
   * 补进来的候选必须正好读完整串，选中后剩余拼音为空。删除与固定仍由 arrange 过滤和复排。
   */
  private withContinuations(rules: CandidateRules, pool: Candidate[]): Candidate[] {
    if (this.rawCode.length === 0 || pool.length === 0) {
      return pool;
    }
    const suggested = rules.suggestContinuations(this.rawCode, pool);
    if (suggested.length === 0) {
      return pool;
    }
    const extra: Candidate[] = [];
    for (const candidate of suggested) {
      if (extra.length >= CONTINUATION_LIMIT) {
        break;
      }
      if (candidate.text.length === 0 || candidate.consumedCodeLength !== this.rawCode.length) {
        continue;
      }
      if (this.containsText(pool, candidate.text) || this.containsText(extra, candidate.text)) {
        continue;
      }
      extra.push(candidate);
    }
    if (extra.length === 0) {
      return pool;
    }
    const merged: Candidate[] = [pool[0]];
    for (const candidate of extra) {
      merged.push(candidate);
    }
    for (let i = 1; i < pool.length; i++) {
      merged.push(pool[i]);
    }
    return merged;
  }

  // 候选池第一个是不是用户固定在这串拼音首位的词
  private isPinnedFirst(pool: Candidate[]): boolean {
    const rules = this.rules;
    if (rules === undefined || pool.length === 0) {
      return false;
    }
    const consumed = pool[0].consumedCodeLength;
    if (!validConsumed(consumed, this.rawCode.length)) {
      return false;
    }
    return rules.isPinned(this.rawCode.substring(0, consumed), pool[0].text);
  }

  private containsText(list: Candidate[], text: string): boolean {
    for (const item of list) {
      if (item.text === text) {
        return true;
      }
    }
    return false;
  }

  private contextText(): string {
    if (this.segments.length > 0) {
      return this.segments[this.segments.length - 1].text;
    }
    return this.previousText;
  }

  private finish(raw: boolean): CommitResult {
    let text = '';
    // 只要这次结果里有一段原文，整次提交就都不参与学习，包括之前选定的汉字与按键落点
    let resultRaw = raw;
    for (const segment of this.segments) {
      text += segment.text;
      if (segment.source === CandidateSource.RAW) {
        resultRaw = true;
      }
    }
    const result: CommitResult = { text: text, segments: this.segments, raw: resultRaw };
    this.segments = [];
    this.rawCode = '';
    this.alternatives = [];
    this.taps = [];
    this.candidates = [];
    this.baseCandidates = [];
    this.baseSnapshot = emptyCandidateSnapshot();
    this.activeSyllable = '';
    this.revision++;
    return result;
  }
}