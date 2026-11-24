import { CandidateRules, CommitLearner, CommitResult, CommitSegment } from '../ime/CompositionController';
import { Candidate, CandidateMeta, CandidateOrigin, CandidateReading, CandidateSource } from './EngineTypes';
import { countKeyPrefixes, entryIdentity, initialsKeyOf, Lexicon, LexiconEntry } from './Lexicon';
import { UserModel } from './PinyinEngine';
import { SEPARATOR } from './PinyinSegmenter';

export const HALF_LIFE_DAYS: number = 30;
export const WEIGHT_USER: number = 1.5;
export const WEIGHT_BIGRAM: number = 0.8;
// 短期近期使用加分（全拼与简拼共用）：刚打过的字词在最近几十次提交内保持较高记忆，随提交次数与天数平滑衰减
export const RECENCY_WEIGHT: number = 1.0;
export const RECENCY_HALF_COMMITS: number = 25;
export const RECENCY_HALF_DAYS: number = 3;
// 简拼/单字母召回额外加分（仅在非全拼路径生效，如 srf、pb、dn、m）
export const WEIGHT_USER_ABBR: number = 2.0;
export const RECENCY_ABBR_WEIGHT: number = 2.2;
// 学习词的先验按音节数计算，使确认过一次的新词可以排在同音整句之前
export const LEARNED_LOG_PROB_PER_SYLLABLE: number = -2.5;
export const MIN_PHRASE_SYLLABLES: number = 2;
export const MAX_PHRASE_SYLLABLES: number = 8;
// 2~4 字合成短语（如“反重力”“鸿蒙版”）确认一次即学入用户词库并建首字母索引；5~8 字长整句仍需确认两次
export const MAX_INSTANT_SENTENCE_SYLLABLES: number = 4;
export const MAX_WORD_RECORDS: number = 20000;
export const MAX_BIGRAM_RECORDS: number = 20000;
// 整句候选要确认这么多次（按衰减后的次数计）才学成新词，只确认过一次的整句先记在待定表里。
// 一个月之内确认两次即可，半衰期内的衰减不影响
export const SENTENCE_CONFIRMATIONS: number = 1.5;
// 基础词库里没有的组合（用户分两次拼出来的新词）至少确认这么多次才提示；
// 词库里本来就有这个组合词时确认一次就提示，见 learnContinuation 与 suggestContinuations
export const UNKNOWN_CONTINUATION_CONFIRMATIONS: number = 1.5;
export const MAX_PENDING_RECORDS: number = 3000;
// 每个词最多记住几种用户实际按过的简拼，多出来时忘掉最早的一种
export const MAX_TYPED_CODES: number = 3;
// 记下的简拼至少有这么多个字母，单个字母本来就能按简拼打出很多字
export const MIN_TYPED_LETTERS: number = 2;
// 长按候选固定首位与删除的条数上限，超出时忘掉最早的一条
export const MAX_PINNED: number = 300;
export const MAX_REMOVED: number = 2000;
// 每个词最多记住几条续接：它后面紧接确认过的词。多出来时忘掉最早的一条
export const MAX_CONTINUATIONS_PER_WORD: number = 2;
// 同一串拼音最多留几条续接，跨不同的前词合并计算，超出的先忘掉最早的
export const MAX_CONTINUATIONS_PER_CODE: number = 3;
// 续接记录总数上限，超出时按最后确认的日期淘汰
export const MAX_CONTINUATION_RECORDS: number = 2000;
// 一次最多补几条组合候选。组合候选补在固定项与引擎首选之后的前几位，见 CompositionController
export const MAX_CONTINUATION_SUGGESTIONS: number = 2;
// 组合候选的分数从前一个词的候选分数里减这么多，原来候选的分数与排列都不动
export const CONTINUATION_SCORE_PENALTY: number = 1.0;
// 续接码最长多少个字符，更长的输入串不记续接，避免把长句记成一整条
const MAX_CONTINUATION_CODE_LENGTH: number = 24;
const PRUNE_RATIO: number = 0.1;
const DAY_MS: number = 86400000;
const FILE_VERSION: number = 1;

// 续接：用户确认这个词以后紧接着又确认的那一段，见 learnContinuation
export interface ContinuationRow {
  // 打出前一个词用的整串拼音，只有当前输入串与它完全相等时才提示
  k: string;
  // 后一段的读音与文字
  s: string;
  w: string;
  c: number;
  d: number;
}

export interface UserWordRow {
  s: string;
  w: string;
  c: number;
  d: number;
  // 最近一次确认该词时的单调提交序号，用于短期近期记忆衰减。旧版本的文件没有这一项
  r?: number;
  // 用户打出这个词时实际按的字母，与完整拼音不同时才记。旧版本的文件没有这一项
  k?: string[];
  // 这个词后面紧接确认过的词，与 k 分开保存。旧版本的文件没有这一项
  x?: ContinuationRow[];
}

export interface BigramRow {
  p: string;
  w: string;
  c: number;
  d: number;
}

// 固定在首位的候选：k 为候选消耗的拼音，原样包括分隔符
export interface PinnedRow {
  k: string;
  s: string;
  w: string;
}

export interface RemovedRow {
  s: string;
  w: string;
}

export interface UserLexiconFile {
  version: number;
  seq?: number;
  words: UserWordRow[];
  bigrams: BigramRow[];
  // 只确认过一次的整句。旧版本的文件没有这一项，按空表读取
  pending?: UserWordRow[];
  // 长按候选固定首位与删除的记录，旧版本的文件没有这两项
  pinned?: PinnedRow[];
  removed?: RemovedRow[];
}

interface PinnedRecord {
  syllables: string[];
  word: string;
}

/**
 * 最近一次删除候选时拿掉的全部记录，撤销时原样放回。只保留一份。
 */
interface RemovedSnapshot {
  identity: string;
  syllables: string[];
  word: string;
  record: WordRecord | undefined;
  pending: PendingRecord | undefined;
  bigrams: BigramRecord[];
  pins: string[];
  // 删除一个组合候选时一并拿掉的续接，撤销时原样放回
  continuations: DroppedContinuation[];
}

// 被删除的组合候选对应的续接记录，以及它挂在哪个词记录上
interface DroppedContinuation {
  headIdentity: string;
  record: ContinuationRecord;
}

interface PendingRecord {
  syllables: string[];
  word: string;
  count: number;
  lastDay: number;
}

interface WordRecord {
  entry: LexiconEntry;
  learned: boolean;
  count: number;
  lastDay: number;
  lastSeq: number;
  // 用户打出这个词时按过的简拼，见 touchTyped
  typed: string[];
  // 用户确认这个词以后紧接着确认的词，见 learnContinuation。与简拼分开保存，不进入简拼索引
  continuations: ContinuationRecord[];
}

interface ContinuationRecord {
  // 前一个词，与所在的词记录是同一个词条
  head: LexiconEntry;
  // 打出前一个词的整串拼音，含分隔符，与输入串逐字比较
  code: string;
  // 后一段的文字与读音
  word: string;
  syllables: string[];
  count: number;
  lastDay: number;
}

// 去掉音节分隔符后的字母
function lettersOf(code: string): string {
  return code.split(SEPARATOR).join('');
}

// 各音节实际首字母（不做 n/r/f 归并），供用户词按原始简拼自动召回
function rawInitialsOf(syllables: string[]): string {
  let key = '';
  for (const syllable of syllables) {
    if (syllable.length > 0) {
      key += syllable.charAt(0);
    }
  }
  return key;
}

interface BigramRecord {
  previous: string;
  word: string;
  count: number;
  lastDay: number;
}

export type DayProvider = () => number;

export function currentDay(): number {
  return Math.floor(Date.now() / DAY_MS);
}

export function characterCount(text: string): number {
  let count = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    // 高位代理与后续低位代理计为一个字符
    if (code < 0xDC00 || code > 0xDFFF) {
      count++;
    }
  }
  return count;
}

/**
 * 上下文键：短词整体作为键，长串取末尾两个字，兼顾整句提交后的关联复用。
 */
export function contextKey(text: string): string {
  return text.length <= 4 ? text : text.substring(text.length - 2);
}

function learnedEntry(syllables: string[], word: string): LexiconEntry {
  const entry: LexiconEntry = {
    syllables: syllables.slice(),
    word: word,
    logProb: LEARNED_LOG_PROB_PER_SYLLABLE * syllables.length
  };
  return entry;
}

export function decayedCount(count: number, lastDay: number, today: number): number {
  const age = Math.max(0, today - lastDay);
  return count * Math.pow(0.5, age / HALF_LIFE_DAYS);
}

/**
 * 可以参与续接学习的片段：用户明确确认过的真实词。
 * 合成整句是引擎拼出来的，原文不参与学习，学到的组合续接本身已经是一次补全，都不能再拿来扩写。
 */
export function isContinuableSegment(segment: CommitSegment): boolean {
  if (segment.source === CandidateSource.RAW || segment.source === CandidateSource.SENTENCE) {
    return false;
  }
  if (segment.origin === CandidateOrigin.CONTINUATION) {
    return false;
  }
  return segment.syllables.length > 0 && segment.syllables.length === characterCount(segment.text);
}

// 正好读完整串的那个词：续接的前一个词必须自己也在候选里，才提示它后面的组合
function completeCandidate(candidates: Candidate[], text: string, consumed: number): Candidate | undefined {
  for (const candidate of candidates) {
    if (candidate.text === text && candidate.consumedCodeLength === consumed) {
      return candidate;
    }
  }
  return undefined;
}

function containsCandidateText(list: Candidate[], text: string): boolean {
  for (const candidate of list) {
    if (candidate.text === text) {
      return true;
    }
  }
  return false;
}

/**
 * 用户词库：记录确认次数、学习新词、记录前后词关联，并按时间衰减计算排序加分。
 */
export class UserLexicon implements UserModel, CommitLearner, CandidateRules {
  private base: Lexicon | undefined = undefined;
  private words: Map<string, WordRecord> = new Map<string, WordRecord>();
  private buckets: Map<string, LexiconEntry[]> = new Map<string, LexiconEntry[]>();
  // 索引键前缀的词条计数，供搜索音节组合时剪枝
  private keyPrefixCounts: Map<string, number> = new Map<string, number>();
  private learnedEntries: Set<LexiconEntry> = new Set<LexiconEntry>();
  private recordsByEntry: Map<LexiconEntry, WordRecord> = new Map<LexiconEntry, WordRecord>();
  private bigrams: Map<string, BigramRecord> = new Map<string, BigramRecord>();
  private pending: Map<string, PendingRecord> = new Map<string, PendingRecord>();
  // 用户按过的简拼 → 用这串字母打出过的词
  private typedIndex: Map<string, LexiconEntry[]> = new Map<string, LexiconEntry[]>();
  // 用户确认过的多音节词按真实音节首字母建的索引（例如“鸿蒙”→ hm，“我爱你”→ wan）
  private initialsIndex: Map<string, LexiconEntry[]> = new Map<string, LexiconEntry[]>();
  // 拼音 → 固定在首位的候选
  private pinned: Map<string, PinnedRecord> = new Map<string, PinnedRecord>();
  // 删除过的候选按词索引，值为各个读音的音节串。列候选时先按词查，查到了才拼读音比较
  private removed: Map<string, string[]> = new Map<string, string[]>();
  private removedCount: number = 0;
  private lastRemoved: RemovedSnapshot | undefined = undefined;
  // 整串拼音 → 它后面紧接确认过的词，只有输入串与码完全相等时才查询，见 suggestContinuations
  private continuations: Map<string, ContinuationRecord[]> = new Map<string, ContinuationRecord[]>();
  private continuationCount: number = 0;
  private maxTypedLength: number = 0;
  private maxInitialsLength: number = 0;
  private maxSyllableCount: number = 0;
  // 单调递增的确认序号，用来计算短期近期记忆衰减
  private sequence: number = 0;
  private dirty: boolean = false;
  // 学习记录的修改次数，引擎缓存词弧时据此判断记录有没有变
  private changes: number = 0;
  private maxWordRecords: number = MAX_WORD_RECORDS;
  private maxBigramRecords: number = MAX_BIGRAM_RECORDS;
  private day: DayProvider;
  private changeListener: () => void = () => {
  };
  private flushListener: () => void = () => {
  };

  constructor(day: DayProvider = currentDay) {
    this.day = day;
  }

  setLimits(maxWords: number, maxBigrams: number): void {
    this.maxWordRecords = Math.max(10, maxWords);
    this.maxBigramRecords = Math.max(10, maxBigrams);
  }

  attachBase(base: Lexicon): void {
    this.base = base;
  }

  setListeners(onChanged: () => void, onFlush: () => void): void {
    this.changeListener = onChanged;
    this.flushListener = onFlush;
  }

  isDirty(): boolean {
    return this.dirty;
  }

  markClean(): void {
    this.dirty = false;
  }

  wordCount(): number {
    return this.words.size;
  }

  bigramCount(): number {
    return this.bigrams.size;
  }

  pendingCount(): number {
    return this.pending.size;
  }

  // ---------- UserModel ----------

  lookup(initialsKey: string): LexiconEntry[] {
    const bucket = this.buckets.get(initialsKey);
    return bucket !== undefined ? bucket : [];
  }

  hasKeyPrefix(prefix: string): boolean {
    return this.keyPrefixCounts.has(prefix);
  }

  typedLookup(letters: string): LexiconEntry[] {
    const entries = this.typedIndex.get(letters);
    return entries !== undefined ? entries : [];
  }

  maxTypedLetters(): number {
    return this.maxTypedLength;
  }

  initialsLookup(letters: string): LexiconEntry[] {
    const entries = this.initialsIndex.get(letters);
    return entries !== undefined ? entries : [];
  }

  maxInitialsLetters(): number {
    return this.maxInitialsLength;
  }

  hasRecord(entry: LexiconEntry): boolean {
    return this.recordsByEntry.has(entry);
  }

  private recencyFactor(lastSeq: number, lastDay: number, today: number): number {
    if (lastSeq <= 0 || this.sequence <= 0) {
      return 0;
    }
    const commitAge = Math.max(0, this.sequence - lastSeq);
    const dayAge = Math.max(0, today - lastDay);
    return (1 / (1 + commitAge / RECENCY_HALF_COMMITS)) * Math.pow(0.5, dayAge / RECENCY_HALF_DAYS);
  }

  // 每条候选词弧都会调用一次，按词条对象查记录，不拼接字符串。记录里保存的正是基础词库或学习词的词条对象
  boost(entry: LexiconEntry, previousText: string, abbreviated: boolean = false): number {
    const record = this.recordsByEntry.get(entry);
    if (record === undefined && (previousText.length === 0 || this.bigrams.size === 0)) {
      return 0;
    }
    const today = this.day();
    let score = 0;
    if (record !== undefined) {
      const effectiveCount = decayedCount(record.count, record.lastDay, today);
      const recency = this.recencyFactor(record.lastSeq, record.lastDay, today);
      score += WEIGHT_USER * Math.log(1 + effectiveCount) + RECENCY_WEIGHT * recency;
      if (abbreviated) {
        score += WEIGHT_USER_ABBR * Math.log(1 + effectiveCount) + RECENCY_ABBR_WEIGHT * recency;
      }
    }
    if (previousText.length > 0) {
      const bigram = this.bigrams.get(this.bigramKey(previousText, entry.word));
      if (bigram !== undefined) {
        score += WEIGHT_BIGRAM * Math.log(1 + decayedCount(bigram.count, bigram.lastDay, today));
      }
    }
    return score;
  }

  isUserEntry(entry: LexiconEntry): boolean {
    return this.learnedEntries.has(entry);
  }

  revision(): number {
    return this.changes;
  }

  maxSyllables(): number {
    return this.maxSyllableCount;
  }

  // ---------- CommitLearner ----------

  learn(result: CommitResult, previousText: string): void {
    if (result.raw) {
      return;
    }
    const segments: CommitSegment[] = [];
    for (const segment of result.segments) {
      if (segment.source !== CandidateSource.RAW && segment.syllables.length > 0 &&
        segment.syllables.length === characterCount(segment.text)) {
        segments.push(segment);
      }
    }
    if (segments.length === 0) {
      return;
    }
    const today = this.day();
    // 2~4 字短合成短语与用户分段拼出的词组确认一次就学；5~8 字长整句仍需确认两次才入库
    for (const segment of segments) {
      const sentence = segment.source === CandidateSource.SENTENCE;
      const needsConfirmation = sentence && segment.syllables.length > MAX_INSTANT_SENTENCE_SYLLABLES;
      this.touchWord(segment.syllables, segment.text, today, sentence, needsConfirmation);
      this.touchTyped(segment.syllables, segment.text, segment.code);
    }
    if (segments.length >= 2) {
      let phrase = '';
      let syllables: string[] = [];
      for (const segment of segments) {
        phrase += segment.text;
        syllables = syllables.concat(segment.syllables);
      }
      // 删除过的词又被用户一段段亲手拼了出来，说明还要用，候选栏重新列出
      this.unmarkRemoved(syllables, phrase);
      this.touchWord(syllables, phrase, today, true, false);
    }
    let previous = previousText;
    for (const segment of segments) {
      if (previous.length > 0) {
        this.touchBigram(previous, segment.text, today);
      }
      previous = segment.text;
    }
    this.prune(today);
    this.dirty = true;
    this.changes++;
    this.changeListener();
  }

  /**
   * 两次真正相邻的明确确认：把后一段记成前一段的续接。
   * 前一个词必须已经有了学习记录（第一次确认时建立），两次都必须是词库列出的真实词，
   * 合计音节数不超过一个整句的长度，避免把分次确认拼成长句。
   * 相邻与时间窗由 ContinuationTracker 判定，这里只负责记录与去重。
   */
  learnContinuation(previous: CommitSegment, next: CommitSegment): void {
    if (!isContinuableSegment(previous) || !isContinuableSegment(next)) {
      return;
    }
    const code = previous.code;
    if (code.length === 0 || code.length > MAX_CONTINUATION_CODE_LENGTH) {
      return;
    }
    if (previous.syllables.length + next.syllables.length > MAX_PHRASE_SYLLABLES) {
      return;
    }
    const record = this.words.get(entryIdentity(previous.syllables, previous.text));
    if (record === undefined) {
      return;
    }
    const today = this.day();
    const reading = next.syllables.join(' ');
    for (const item of record.continuations) {
      if (item.code === code && item.word === next.text && item.syllables.join(' ') === reading) {
        item.count = decayedCount(item.count, item.lastDay, today) + 1;
        item.lastDay = today;
        this.markChanged();
        return;
      }
    }
    const item: ContinuationRecord = {
      head: record.entry, code: code, word: next.text, syllables: next.syllables.slice(), count: 1, lastDay: today
    };
    this.addContinuation(record, item);
    this.prune(today);
    this.markChanged();
  }

  /**
   * 学到的组合续接：只有输入串与记下的码完全相等、前一个词又正好读完整串列在候选里时才补。
   * 组合候选消耗整串拼音，读音是前一个词与后一个词拼接的音节，分数从前一个词的候选分数里扣一点，
   * 原来候选的分数与顺序都不动。删除过的组合不再提示，固定与删除仍由 arrange 复排。
   */
  suggestContinuations(code: string, candidates: Candidate[]): Candidate[] {
    const result: Candidate[] = [];
    if (code.length === 0 || candidates.length === 0 || this.continuations.size === 0) {
      return result;
    }
    const bucket = this.continuations.get(code);
    if (bucket === undefined || bucket.length === 0) {
      return result;
    }
    const today = this.day();
    const ordered = bucket.slice();
    // 先按确认次数，再按前一个词的词频，次数相同时保持记下的先后
    ordered.sort((a: ContinuationRecord, b: ContinuationRecord) => {
      const left = decayedCount(a.count, a.lastDay, today);
      const right = decayedCount(b.count, b.lastDay, today);
      if (left !== right) {
        return right > left ? 1 : -1;
      }
      if (a.head.logProb !== b.head.logProb) {
        return b.head.logProb > a.head.logProb ? 1 : -1;
      }
      return 0;
    });
    for (const item of ordered) {
      if (result.length >= MAX_CONTINUATION_SUGGESTIONS) {
        break;
      }
      // 前一个词没有读完整串列出来时不猜组合，组合只补在它自己已经成立的时候
      const head = completeCandidate(candidates, item.head.word, code.length);
      if (head === undefined) {
        continue;
      }
      const syllables = item.head.syllables.concat(item.syllables);
      const text = item.head.word + item.word;
      if (containsCandidateText(candidates, text) || containsCandidateText(result, text)) {
        continue;
      }
      if (this.isRemoved(syllables, text)) {
        continue;
      }
      // 词库里没有这个组合词时，先记下第一次确认，再确认一次才提示
      if (decayedCount(item.count, item.lastDay, today) < UNKNOWN_CONTINUATION_CONFIRMATIONS &&
        !this.isBasePhrase(syllables, text)) {
        continue;
      }
      result.push(this.continuationCandidate(item, syllables, text, code.length, head.score));
    }
    return result;
  }

  flush(): void {
    if (this.dirty) {
      this.flushListener();
    }
  }

  clear(): void {
    this.words.clear();
    this.buckets.clear();
    this.keyPrefixCounts.clear();
    this.learnedEntries.clear();
    this.recordsByEntry.clear();
    this.bigrams.clear();
    this.pending.clear();
    this.typedIndex.clear();
    this.initialsIndex.clear();
    this.pinned.clear();
    this.removed.clear();
    this.removedCount = 0;
    this.lastRemoved = undefined;
    this.continuations.clear();
    this.continuationCount = 0;
    this.maxTypedLength = 0;
    this.maxInitialsLength = 0;
    this.maxSyllableCount = 0;
    this.sequence = 0;
    this.dirty = true;
    this.changes++;
    this.flushListener();
  }

  /**
   * 删除一个用户词及其关联记录，基础词库中的词只清除使用次数。
   */
  forget(syllables: string[], word: string): boolean {
    const identity = entryIdentity(syllables, word);
    const hadPending = this.pending.delete(identity);
    const record = this.words.get(identity);
    if (record === undefined) {
      if (hadPending) {
        this.dirty = true;
        this.changes++;
        this.changeListener();
      }
      return hadPending;
    }
    this.removeRecord(identity, record);
    const removeKeys: string[] = [];
    this.bigrams.forEach((bigram: BigramRecord, key: string) => {
      if (bigram.word === word || bigram.previous === word) {
        removeKeys.push(key);
      }
    });
    for (const key of removeKeys) {
      this.bigrams.delete(key);
    }
    this.dirty = true;
    this.changes++;
    this.changeListener();
    return true;
  }

  // ---------- CandidateRules ----------

  /**
   * 列候选的最后一步：先去掉删除过的候选，再把这串拼音固定的候选挪到首位。两张表都为空时原样返回，不新建数组。
   */
  arrange(code: string, candidates: Candidate[]): Candidate[] {
    if (this.removed.size === 0 && this.pinned.size === 0) {
      return candidates;
    }
    const list = this.removed.size === 0 ? candidates :
      candidates.filter((candidate: Candidate) => !this.isRemoved(candidate.syllables, candidate.text));
    const pin = this.pinned.get(code);
    if (pin === undefined) {
      return list;
    }
    for (let i = 0; i < list.length; i++) {
      if (list[i].text === pin.word && list[i].consumedCodeLength === code.length) {
        if (i === 0) {
          return list;
        }
        const result: Candidate[] = [list[i]];
        for (let j = 0; j < list.length; j++) {
          if (j !== i) {
            result.push(list[j]);
          }
        }
        return result;
      }
    }
    // 引擎这次没有列出固定的词，按记下的读音补在首位
    const candidate: Candidate = {
      id: `pin_${code}`,
      text: pin.word,
      consumedCodeLength: code.length,
      syllables: pin.syllables.slice(),
      score: 0,
      source: CandidateSource.USER
    };
    return [candidate].concat(list);
  }

  isPinned(code: string, word: string): boolean {
    const pin = this.pinned.get(code);
    return pin !== undefined && pin.word === word;
  }

  // 同一串拼音只固定一个词，后固定的替换先固定的
  pin(code: string, syllables: string[], word: string): void {
    if (code.length === 0 || syllables.length === 0) {
      return;
    }
    this.pinned.delete(code);
    const record: PinnedRecord = { syllables: syllables.slice(), word: word };
    this.pinned.set(code, record);
    if (this.pinned.size > MAX_PINNED) {
      this.pinned.delete(this.pinned.keys().next().value as string);
    }
    this.markChanged();
  }

  unpin(code: string): void {
    if (this.pinned.delete(code)) {
      this.markChanged();
    }
  }

  /**
   * 删除候选：清掉这个词的学习记录与前后词关联，以后候选栏不再列出它。拿掉的记录留一份，撤销时放回。
   */
  remove(syllables: string[], word: string): void {
    if (syllables.length === 0) {
      return;
    }
    const identity = entryIdentity(syllables, word);
    const reading = syllables.join(' ');
    const record = this.words.get(identity);
    const bigrams: BigramRecord[] = [];
    // 与 forget 一致：只有学过的词才连带清掉前后词关联
    if (record !== undefined) {
      this.bigrams.forEach((bigram: BigramRecord) => {
        if (bigram.word === word || bigram.previous === word) {
          bigrams.push(bigram);
        }
      });
    }
    const pins: string[] = [];
    this.pinned.forEach((pin: PinnedRecord, code: string) => {
      if (pin.word === word && pin.syllables.join(' ') === reading) {
        pins.push(code);
      }
    });
    // 删除的正好是一条组合候选时，把产生它的续接也一起拿掉，以后不再提示
    const continuations = this.dropMatchingContinuations(syllables, word);
    const snapshot: RemovedSnapshot = {
      identity: identity,
      syllables: syllables.slice(),
      word: word,
      record: record,
      pending: this.pending.get(identity),
      bigrams: bigrams,
      pins: pins,
      continuations: continuations
    };
    this.forget(syllables, word);
    for (const code of pins) {
      this.pinned.delete(code);
    }
    this.markRemoved(reading, word);
    this.lastRemoved = snapshot;
    this.markChanged();
  }

  // 撤销最近一次删除，学习记录、前后词关联与固定都原样放回
  restoreRemoved(): boolean {
    const snapshot = this.lastRemoved;
    this.lastRemoved = undefined;
    if (snapshot === undefined) {
      return false;
    }
    this.unmarkRemoved(snapshot.syllables, snapshot.word);
    if (snapshot.record !== undefined && !this.words.has(snapshot.identity)) {
      this.addRecord(snapshot.identity, snapshot.record);
    }
    if (snapshot.pending !== undefined && !this.pending.has(snapshot.identity)) {
      this.pending.set(snapshot.identity, snapshot.pending);
    }
    for (const bigram of snapshot.bigrams) {
      const key = this.bigramKey(bigram.previous, bigram.word);
      if (!this.bigrams.has(key)) {
        this.bigrams.set(key, bigram);
      }
    }
    for (const code of snapshot.pins) {
      if (!this.pinned.has(code)) {
        const pin: PinnedRecord = { syllables: snapshot.syllables.slice(), word: snapshot.word };
        this.pinned.set(code, pin);
      }
    }
    for (const dropped of snapshot.continuations) {
      const head = this.words.get(dropped.headIdentity);
      if (head !== undefined && head.continuations.indexOf(dropped.record) < 0) {
        head.continuations.push(dropped.record);
        this.indexContinuation(dropped.record);
      }
    }
    this.markChanged();
    return true;
  }

  // ---------- 内部 ----------

  private markChanged(): void {
    this.dirty = true;
    this.changes++;
    this.changeListener();
  }

  // 组合候选：读完整个输入串，读音是前一个词与后一个词拼接的音节，来源标成续接
  private continuationCandidate(item: ContinuationRecord, syllables: string[], text: string, consumed: number,
    headScore: number): Candidate {
    const meta: CandidateMeta = {
      reading: CandidateReading.FULL,
      complete: true,
      safeEnd: true,
      exactConsumed: consumed,
      origin: CandidateOrigin.CONTINUATION
    };
    const candidate: Candidate = {
      id: `cont_${consumed}_${text}`,
      text: text,
      consumedCodeLength: consumed,
      syllables: syllables,
      score: headScore - CONTINUATION_SCORE_PENALTY,
      source: CandidateSource.USER,
      meta: meta
    };
    return candidate;
  }

  /**
   * 续接同时挂在词记录与整串拼音索引上，两处都按上限淘汰最早的一条。
   * 索引按码分开，只有输入串与码完全相等时才查得到，见 suggestContinuations。
   */
  private addContinuation(record: WordRecord, item: ContinuationRecord): void {
    record.continuations.push(item);
    while (record.continuations.length > MAX_CONTINUATIONS_PER_WORD) {
      const oldest = record.continuations.shift() as ContinuationRecord;
      this.removeFromContinuationIndex(oldest);
    }
    let bucket = this.continuations.get(item.code);
    if (bucket === undefined) {
      bucket = [];
      this.continuations.set(item.code, bucket);
    }
    bucket.push(item);
    this.continuationCount++;
    while (bucket.length > MAX_CONTINUATIONS_PER_CODE) {
      const dropped = bucket.shift() as ContinuationRecord;
      this.continuationCount--;
      this.unlinkContinuation(dropped);
    }
    if (bucket.length === 0) {
      this.continuations.delete(item.code);
    }
  }

  // 记下一条已经存在的续接：恢复删除时用，不再走上限淘汰
  private indexContinuation(item: ContinuationRecord): void {
    let bucket = this.continuations.get(item.code);
    if (bucket === undefined) {
      bucket = [];
      this.continuations.set(item.code, bucket);
    }
    if (bucket.indexOf(item) < 0) {
      bucket.push(item);
      this.continuationCount++;
    }
  }

  private removeFromContinuationIndex(item: ContinuationRecord): void {
    const bucket = this.continuations.get(item.code);
    if (bucket === undefined) {
      return;
    }
    const index = bucket.indexOf(item);
    if (index >= 0) {
      bucket.splice(index, 1);
      this.continuationCount--;
    }
    if (bucket.length === 0) {
      this.continuations.delete(item.code);
    }
  }

  // 只从它所在的词记录里摘掉，索引那边由调用方处理
  private unlinkContinuation(item: ContinuationRecord): void {
    const head = this.words.get(entryIdentity(item.head.syllables, item.head.word));
    if (head === undefined) {
      return;
    }
    const index = head.continuations.indexOf(item);
    if (index >= 0) {
      head.continuations.splice(index, 1);
    }
  }

  private dropContinuation(item: ContinuationRecord): void {
    this.removeFromContinuationIndex(item);
    this.unlinkContinuation(item);
  }

  // 删除组合候选时，把文字与读音都对得上的续接一并拿掉，返回它们供撤销放回
  private dropMatchingContinuations(syllables: string[], word: string): DroppedContinuation[] {
    const dropped: DroppedContinuation[] = [];
    if (this.continuations.size === 0) {
      return dropped;
    }
    const reading = syllables.join(' ');
    const codes: string[] = [];
    this.continuations.forEach((bucket: ContinuationRecord[], code: string) => {
      codes.push(code);
    });
    for (const code of codes) {
      const bucket = this.continuations.get(code);
      if (bucket === undefined) {
        continue;
      }
      const keep: ContinuationRecord[] = [];
      for (const item of bucket) {
        if (item.head.word + item.word === word && item.head.syllables.concat(item.syllables).join(' ') === reading) {
          dropped.push({ headIdentity: entryIdentity(item.head.syllables, item.head.word), record: item });
          this.continuationCount--;
        } else {
          keep.push(item);
        }
      }
      if (keep.length === 0) {
        this.continuations.delete(code);
      } else if (keep.length !== bucket.length) {
        this.continuations.set(code, keep);
      }
    }
    for (const item of dropped) {
      this.unlinkContinuation(item.record);
    }
    return dropped;
  }

  // 组合词本身是不是基础词库里就有的词：有的话确认一次就能提示
  private isBasePhrase(syllables: string[], word: string): boolean {
    return this.base !== undefined && this.base.find(syllables, word) !== undefined;
  }

  private isRemoved(syllables: string[], word: string): boolean {
    const readings = this.removed.get(word);
    return readings !== undefined && syllables.length > 0 && readings.indexOf(syllables.join(' ')) >= 0;
  }

  private markRemoved(reading: string, word: string): void {
    let readings = this.removed.get(word);
    if (readings === undefined) {
      readings = [];
      this.removed.set(word, readings);
    }
    if (readings.indexOf(reading) >= 0) {
      return;
    }
    readings.push(reading);
    this.removedCount++;
    // 超出上限时忘掉最早删除的词
    while (this.removedCount > MAX_REMOVED && this.removed.size > 1) {
      const oldest = this.removed.keys().next().value as string;
      this.removedCount -= (this.removed.get(oldest) as string[]).length;
      this.removed.delete(oldest);
    }
  }

  private unmarkRemoved(syllables: string[], word: string): void {
    const readings = this.removed.get(word);
    if (readings === undefined) {
      return;
    }
    const index = readings.indexOf(syllables.join(' '));
    if (index < 0) {
      return;
    }
    readings.splice(index, 1);
    this.removedCount--;
    if (readings.length === 0) {
      this.removed.delete(word);
    }
    this.dirty = true;
  }

  private touchWord(syllables: string[], word: string, today: number, allowLearn: boolean,
    needsConfirmation: boolean): void {
    if (syllables.length === 0 || syllables.length > MAX_PHRASE_SYLLABLES) {
      return;
    }
    const identity = entryIdentity(syllables, word);
    const existing = this.words.get(identity);
    if (existing !== undefined) {
      existing.count = decayedCount(existing.count, existing.lastDay, today) + 1;
      existing.lastDay = today;
      existing.lastSeq = ++this.sequence;
      return;
    }
    const baseEntry = this.base !== undefined ? this.base.find(syllables, word) : undefined;
    if (baseEntry === undefined && (!allowLearn || syllables.length < MIN_PHRASE_SYLLABLES)) {
      return;
    }
    let count = 1;
    if (baseEntry === undefined && needsConfirmation) {
      const waiting = this.pending.get(identity);
      count = waiting !== undefined ? decayedCount(waiting.count, waiting.lastDay, today) + 1 : 1;
      if (count < SENTENCE_CONFIRMATIONS) {
        const record: PendingRecord = { syllables: syllables.slice(), word: word, count: count, lastDay: today };
        this.pending.set(identity, record);
        return;
      }
      this.pending.delete(identity);
    }
    const entry = baseEntry !== undefined ? baseEntry : learnedEntry(syllables, word);
    const record: WordRecord = {
      entry: entry, learned: baseEntry === undefined, count: count, lastDay: today, lastSeq: ++this.sequence,
      typed: [], continuations: []
    };
    this.addRecord(identity, record);
  }

  /**
   * 用户用简拼或分隔符打出一个多字词时，记下实际按的字母。例如用 w'a'n 打出“我爱你”以后，
   * 直接按 wan 也能找到它。wan 本身是完整音节，按简拼读要切进音节内部，扣分太多，不记的话永远排不上来。
   * 只给已有学习记录的词记；按的字母与完整拼音相同时不记。
   */
  private touchTyped(syllables: string[], word: string, code: string): void {
    const letters = lettersOf(code);
    if (syllables.length < MIN_PHRASE_SYLLABLES || letters.length < MIN_TYPED_LETTERS ||
      letters === syllables.join('')) {
      return;
    }
    const record = this.words.get(entryIdentity(syllables, word));
    if (record === undefined || record.typed.indexOf(letters) >= 0) {
      return;
    }
    if (record.typed.length >= MAX_TYPED_CODES) {
      this.unindexTyped(record.typed[0], record.entry);
      record.typed.shift();
    }
    record.typed.push(letters);
    this.indexTyped(letters, record.entry);
  }

  private addEntryIndex(index: Map<string, LexiconEntry[]>, key: string, entry: LexiconEntry): void {
    let entries = index.get(key);
    if (entries === undefined) {
      entries = [];
      index.set(key, entries);
    }
    if (entries.indexOf(entry) < 0) {
      entries.push(entry);
    }
  }

  private removeEntryIndex(index: Map<string, LexiconEntry[]>, key: string, entry: LexiconEntry): void {
    const entries = index.get(key);
    if (entries === undefined) {
      return;
    }
    const pos = entries.indexOf(entry);
    if (pos >= 0) {
      entries.splice(pos, 1);
    }
    if (entries.length === 0) {
      index.delete(key);
    }
  }

  private indexTyped(letters: string, entry: LexiconEntry): void {
    this.addEntryIndex(this.typedIndex, letters, entry);
    this.maxTypedLength = Math.max(this.maxTypedLength, letters.length);
  }

  private unindexTyped(letters: string, entry: LexiconEntry): void {
    this.removeEntryIndex(this.typedIndex, letters, entry);
  }

  private indexInitials(initials: string, entry: LexiconEntry): void {
    this.addEntryIndex(this.initialsIndex, initials, entry);
    this.maxInitialsLength = Math.max(this.maxInitialsLength, initials.length);
  }

  private unindexInitials(initials: string, entry: LexiconEntry): void {
    this.removeEntryIndex(this.initialsIndex, initials, entry);
  }

  private addRecord(identity: string, record: WordRecord): void {
    this.words.set(identity, record);
    this.recordsByEntry.set(record.entry, record);
    if (record.learned) {
      this.learnedEntries.add(record.entry);
    }
    const key = initialsKeyOf(record.entry.syllables);
    let bucket = this.buckets.get(key);
    if (bucket === undefined) {
      bucket = [];
      this.buckets.set(key, bucket);
    }
    bucket.push(record.entry);
    countKeyPrefixes(this.keyPrefixCounts, key, 1);
    this.maxSyllableCount = Math.max(this.maxSyllableCount, record.entry.syllables.length);
    for (const letters of record.typed) {
      this.indexTyped(letters, record.entry);
    }
    if (record.entry.syllables.length >= MIN_PHRASE_SYLLABLES) {
      const initials = rawInitialsOf(record.entry.syllables);
      if (initials.length >= MIN_TYPED_LETTERS) {
        this.indexInitials(initials, record.entry);
      }
    }
    for (const item of record.continuations) {
      this.indexContinuation(item);
    }
  }

  private removeRecord(identity: string, record: WordRecord): void {
    this.words.delete(identity);
    this.recordsByEntry.delete(record.entry);
    this.learnedEntries.delete(record.entry);
    for (const letters of record.typed) {
      this.unindexTyped(letters, record.entry);
    }
    if (record.entry.syllables.length >= MIN_PHRASE_SYLLABLES) {
      const initials = rawInitialsOf(record.entry.syllables);
      if (initials.length >= MIN_TYPED_LETTERS) {
        this.unindexInitials(initials, record.entry);
      }
    }
    // 这个词连同它的续接一起失效；撤销删除时记录原样放回，续接跟着重新入索引
    const continuations = record.continuations;
    record.continuations = [];
    for (const item of continuations) {
      this.removeFromContinuationIndex(item);
    }
    const key = initialsKeyOf(record.entry.syllables);
    const bucket = this.buckets.get(key);
    if (bucket !== undefined) {
      const index = bucket.indexOf(record.entry);
      if (index >= 0) {
        bucket.splice(index, 1);
        countKeyPrefixes(this.keyPrefixCounts, key, -1);
      }
      if (bucket.length === 0) {
        this.buckets.delete(key);
      }
    }
  }

  private bigramKey(previous: string, word: string): string {
    return `${contextKey(previous)}${word}`;
  }

  private touchBigram(previous: string, word: string, today: number): void {
    const key = this.bigramKey(previous, word);
    const existing = this.bigrams.get(key);
    if (existing !== undefined) {
      existing.count = decayedCount(existing.count, existing.lastDay, today) + 1;
      existing.lastDay = today;
      return;
    }
    const record: BigramRecord = { previous: contextKey(previous), word: word, count: 1, lastDay: today };
    this.bigrams.set(key, record);
  }

  private prune(today: number): void {
    if (this.words.size > this.maxWordRecords) {
      const scored: string[] = [];
      this.words.forEach((record: WordRecord, identity: string) => {
        scored.push(identity);
      });
      scored.sort((a: string, b: string) => {
        const ra = this.words.get(a) as WordRecord;
        const rb = this.words.get(b) as WordRecord;
        return decayedCount(ra.count, ra.lastDay, today) - decayedCount(rb.count, rb.lastDay, today);
      });
      const removeCount = this.words.size - Math.floor(this.maxWordRecords * (1 - PRUNE_RATIO));
      for (let i = 0; i < removeCount; i++) {
        const record = this.words.get(scored[i]);
        if (record !== undefined) {
          this.removeRecord(scored[i], record);
        }
      }
    }
    if (this.bigrams.size > this.maxBigramRecords) {
      const keys: string[] = [];
      this.bigrams.forEach((record: BigramRecord, key: string) => {
        keys.push(key);
      });
      keys.sort((a: string, b: string) => {
        const ra = this.bigrams.get(a) as BigramRecord;
        const rb = this.bigrams.get(b) as BigramRecord;
        return decayedCount(ra.count, ra.lastDay, today) - decayedCount(rb.count, rb.lastDay, today);
      });
      const removeCount = this.bigrams.size - Math.floor(this.maxBigramRecords * (1 - PRUNE_RATIO));
      for (let i = 0; i < removeCount; i++) {
        this.bigrams.delete(keys[i]);
      }
    }
    // 待定整句按最后确认的日期淘汰，最久没再确认的先删
    if (this.pending.size > MAX_PENDING_RECORDS) {
      const keys: string[] = [];
      this.pending.forEach((record: PendingRecord, key: string) => {
        keys.push(key);
      });
      keys.sort((a: string, b: string) => {
        const ra = this.pending.get(a) as PendingRecord;
        const rb = this.pending.get(b) as PendingRecord;
        return ra.lastDay - rb.lastDay;
      });
      const removeCount = this.pending.size - Math.floor(MAX_PENDING_RECORDS * (1 - PRUNE_RATIO));
      for (let i = 0; i < removeCount; i++) {
        this.pending.delete(keys[i]);
      }
    }
  }

  // ---------- 序列化 ----------

  /**
   * 读回一个词后面的续接。前一个词记录已经建好，这里只校验后段本身：
   * 续接按整串拼音逐字匹配，任何一条读错都会让学到的组合在重载以后消失，所以写入与读取的校验必须一致。
   */
  private readContinuations(rows: ContinuationRow[] | undefined, head: LexiconEntry,
    headSyllables: string[]): ContinuationRecord[] {
    const continuations: ContinuationRecord[] = [];
    if (rows === undefined || !Array.isArray(rows)) {
      return continuations;
    }
    for (const item of rows) {
      if (continuations.length >= MAX_CONTINUATIONS_PER_WORD || this.continuationCount >= MAX_CONTINUATION_RECORDS) {
        break;
      }
      if (typeof item.k !== 'string' || item.k.length === 0 || item.k.length > MAX_CONTINUATION_CODE_LENGTH ||
        typeof item.w !== 'string' || item.w.length === 0 || typeof item.s !== 'string' || item.s.length === 0 ||
        typeof item.c !== 'number' || !Number.isFinite(item.c) || item.c <= 0 ||
        typeof item.d !== 'number' || !Number.isFinite(item.d)) {
        continue;
      }
      // 音节用单个空格分开，首尾或连续空格说明文件被改过
      if (item.s.startsWith(' ') || item.s.endsWith(' ') || item.s.indexOf('  ') >= 0) {
        continue;
      }
      const nextSyllables = item.s.split(' ');
      // 后一段必须是真实词：字数与音节数对得上，合计不超过一个整句
      if (nextSyllables.length !== characterCount(item.w) ||
        headSyllables.length + nextSyllables.length > MAX_PHRASE_SYLLABLES) {
        continue;
      }
      if (this.hasContinuation(continuations, item.k, nextSyllables, item.w)) {
        continue;
      }
      // 同一串拼音最多留几条，正常写入时已经淘汰过，这里只防御手改过的文件
      const bucket = this.continuations.get(item.k);
      if (bucket !== undefined && bucket.length >= MAX_CONTINUATIONS_PER_CODE) {
        continue;
      }
      const continuation: ContinuationRecord = {
        head: head, code: item.k, word: item.w, syllables: nextSyllables, count: item.c, lastDay: item.d
      };
      continuations.push(continuation);
    }
    return continuations;
  }

  private hasContinuation(list: ContinuationRecord[], code: string, syllables: string[], word: string): boolean {
    const reading = syllables.join(' ');
    for (const item of list) {
      if (item.code === code && item.word === word && item.syllables.join(' ') === reading) {
        return true;
      }
    }
    return false;
  }

  serialize(): string {
    const words: UserWordRow[] = [];
    this.words.forEach((record: WordRecord) => {
      const row: UserWordRow = {
        s: record.entry.syllables.join(' '),
        w: record.entry.word,
        c: Math.round(record.count * 1000) / 1000,
        d: record.lastDay
      };
      if (record.lastSeq > 0) {
        row.r = record.lastSeq;
      }
      if (record.typed.length > 0) {
        row.k = record.typed.slice();
      }
      // 续接跟着前一个词一起保存：旧版本的文件没有这一项，读取时按空表处理
      if (record.continuations.length > 0) {
        const continuations: ContinuationRow[] = [];
        for (const item of record.continuations) {
          const continuation: ContinuationRow = {
            k: item.code,
            s: item.syllables.join(' '),
            w: item.word,
            c: Math.round(item.count * 1000) / 1000,
            d: item.lastDay
          };
          continuations.push(continuation);
        }
        row.x = continuations;
      }
      words.push(row);
    });
    const bigrams: BigramRow[] = [];
    this.bigrams.forEach((record: BigramRecord) => {
      const row: BigramRow = {
        p: record.previous,
        w: record.word,
        c: Math.round(record.count * 1000) / 1000,
        d: record.lastDay
      };
      bigrams.push(row);
    });
    const pending: UserWordRow[] = [];
    this.pending.forEach((record: PendingRecord) => {
      const row: UserWordRow = {
        s: record.syllables.join(' '),
        w: record.word,
        c: Math.round(record.count * 1000) / 1000,
        d: record.lastDay
      };
      pending.push(row);
    });
    const pinned: PinnedRow[] = [];
    this.pinned.forEach((record: PinnedRecord, code: string) => {
      const row: PinnedRow = { k: code, s: record.syllables.join(' '), w: record.word };
      pinned.push(row);
    });
    const removed: RemovedRow[] = [];
    this.removed.forEach((readings: string[], word: string) => {
      for (const reading of readings) {
        const row: RemovedRow = { s: reading, w: word };
        removed.push(row);
      }
    });
    const file: UserLexiconFile = {
      version: FILE_VERSION, words: words, bigrams: bigrams, pending: pending, pinned: pinned, removed: removed
    };
    if (this.sequence > 0) {
      file.seq = this.sequence;
    }
    return JSON.stringify(file);
  }

  /**
   * 解析失败时抛出异常，由调用方备份损坏文件并从空库开始。
   */
  deserialize(text: string): void {
    const file = JSON.parse(text) as UserLexiconFile;
    if (file === null || file.version !== FILE_VERSION || !Array.isArray(file.words) || !Array.isArray(file.bigrams)) {
      throw new Error('invalid user lexicon file');
    }
    this.words.clear();
    this.buckets.clear();
    this.keyPrefixCounts.clear();
    this.learnedEntries.clear();
    this.recordsByEntry.clear();
    this.bigrams.clear();
    this.pending.clear();
    this.typedIndex.clear();
    this.initialsIndex.clear();
    this.pinned.clear();
    this.removed.clear();
    this.removedCount = 0;
    this.lastRemoved = undefined;
    // 续接索引与计数跟着重新建立：读回的词记录会在 addRecord 里重新挂进索引
    this.continuations.clear();
    this.continuationCount = 0;
    this.maxTypedLength = 0;
    this.maxInitialsLength = 0;
    this.maxSyllableCount = 0;
    this.sequence = typeof file.seq === 'number' && Number.isFinite(file.seq) && file.seq >= 0 ?
      Math.floor(file.seq) : 0;
    for (const row of file.words) {
      if (typeof row.s !== 'string' || typeof row.w !== 'string' || typeof row.c !== 'number' ||
        typeof row.d !== 'number' || !Number.isFinite(row.c) || row.c <= 0) {
        continue;
      }
      const syllables = row.s.split(' ');
      if (syllables.length === 0 || syllables.length > MAX_PHRASE_SYLLABLES) {
        continue;
      }
      const identity = entryIdentity(syllables, row.w);
      if (this.words.has(identity)) {
        continue;
      }
      const baseEntry = this.base !== undefined ? this.base.find(syllables, row.w) : undefined;
      const entry = baseEntry !== undefined ? baseEntry : learnedEntry(syllables, row.w);
      const typed: string[] = [];
      if (Array.isArray(row.k)) {
        for (const letters of row.k as string[]) {
          if (typeof letters === 'string' && letters.length >= MIN_TYPED_LETTERS && typed.length < MAX_TYPED_CODES &&
            typed.indexOf(letters) < 0) {
            typed.push(letters);
          }
        }
      }
      const lastSeq = typeof row.r === 'number' && Number.isFinite(row.r) && row.r > 0 ? Math.floor(row.r) : 0;
      if (lastSeq > this.sequence) {
        this.sequence = lastSeq;
      }
      // 续接与前一个词一起读回：旧版本的文件没有 x，按空表处理；结构对不上的一条直接跳过。
      // 记录先挂好续接再交给 addRecord，续接索引与计数才会一起重建
      const continuations = this.readContinuations(row.x, entry, syllables);
      const record: WordRecord = {
        entry: entry, learned: baseEntry === undefined, count: row.c, lastDay: row.d, lastSeq: lastSeq,
        typed: typed, continuations: continuations
      };
      this.addRecord(identity, record);
    }
    for (const row of file.bigrams) {
      if (typeof row.p !== 'string' || typeof row.w !== 'string' || typeof row.c !== 'number' ||
        typeof row.d !== 'number' || !Number.isFinite(row.c) || row.c <= 0) {
        continue;
      }
      const record: BigramRecord = { previous: row.p, word: row.w, count: row.c, lastDay: row.d };
      this.bigrams.set(this.bigramKey(row.p, row.w), record);
    }
    const pendingRows = Array.isArray(file.pending) ? file.pending as UserWordRow[] : [];
    for (const row of pendingRows) {
      if (typeof row.s !== 'string' || typeof row.w !== 'string' || typeof row.c !== 'number' ||
        typeof row.d !== 'number' || !Number.isFinite(row.c) || row.c <= 0) {
        continue;
      }
      const syllables = row.s.split(' ');
      const identity = entryIdentity(syllables, row.w);
      if (this.words.has(identity)) {
        continue;
      }
      const record: PendingRecord = { syllables: syllables, word: row.w, count: row.c, lastDay: row.d };
      this.pending.set(identity, record);
    }
    const pinnedRows = Array.isArray(file.pinned) ? file.pinned as PinnedRow[] : [];
    for (const row of pinnedRows) {
      if (typeof row.k !== 'string' || typeof row.s !== 'string' || typeof row.w !== 'string' || row.k.length === 0 ||
        row.s.length === 0 || this.pinned.size >= MAX_PINNED) {
        continue;
      }
      const record: PinnedRecord = { syllables: row.s.split(' '), word: row.w };
      this.pinned.set(row.k, record);
    }
    const removedRows = Array.isArray(file.removed) ? file.removed as RemovedRow[] : [];
    for (const row of removedRows) {
      if (typeof row.s === 'string' && typeof row.w === 'string' && row.s.length > 0) {
        this.markRemoved(row.s, row.w);
      }
    }
    this.dirty = false;
    this.changes++;
  }
}
