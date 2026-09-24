import { CommitLearner, CommitResult, CommitSegment } from '../ime/CompositionController';
import { CandidateSource } from './EngineTypes';
import { countKeyPrefixes, entryIdentity, initialsKeyOf, Lexicon, LexiconEntry } from './Lexicon';
import { UserModel } from './PinyinEngine';

export const HALF_LIFE_DAYS: number = 30;
export const WEIGHT_USER: number = 1.2;
export const WEIGHT_BIGRAM: number = 0.8;
// 学习词的先验按音节数计算，使确认过一次的新词可以排在同音整句之前
export const LEARNED_LOG_PROB_PER_SYLLABLE: number = -2.5;
export const MIN_PHRASE_SYLLABLES: number = 2;
export const MAX_PHRASE_SYLLABLES: number = 8;
export const MAX_WORD_RECORDS: number = 20000;
export const MAX_BIGRAM_RECORDS: number = 20000;
// 整句候选要确认这么多次（按衰减后的次数计）才学成新词，只确认过一次的整句先记在待定表里。
// 一个月之内确认两次即可，半衰期内的衰减不影响
export const SENTENCE_CONFIRMATIONS: number = 1.5;
export const MAX_PENDING_RECORDS: number = 3000;
const PRUNE_RATIO: number = 0.1;
const DAY_MS: number = 86400000;
const FILE_VERSION: number = 1;

export interface UserWordRow {
  s: string;
  w: string;
  c: number;
  d: number;
}

export interface BigramRow {
  p: string;
  w: string;
  c: number;
  d: number;
}

export interface UserLexiconFile {
  version: number;
  words: UserWordRow[];
  bigrams: BigramRow[];
  // 只确认过一次的整句。旧版本的文件没有这一项，按空表读取
  pending?: UserWordRow[];
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
 * 用户词库：记录确认次数、学习新词、记录前后词关联，并按时间衰减计算排序加分。
 */
export class UserLexicon implements UserModel, CommitLearner {
  private base: Lexicon | undefined = undefined;
  private words: Map<string, WordRecord> = new Map<string, WordRecord>();
  private buckets: Map<string, LexiconEntry[]> = new Map<string, LexiconEntry[]>();
  // 索引键前缀的词条计数，供搜索音节组合时剪枝
  private keyPrefixCounts: Map<string, number> = new Map<string, number>();
  private learnedEntries: Set<LexiconEntry> = new Set<LexiconEntry>();
  private recordsByEntry: Map<LexiconEntry, WordRecord> = new Map<LexiconEntry, WordRecord>();
  private bigrams: Map<string, BigramRecord> = new Map<string, BigramRecord>();
  private pending: Map<string, PendingRecord> = new Map<string, PendingRecord>();
  private maxSyllableCount: number = 0;
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

  // 每条候选词弧都会调用一次，按词条对象查记录，不拼接字符串。记录里保存的正是基础词库或学习词的词条对象
  boost(entry: LexiconEntry, previousText: string): number {
    const record = this.recordsByEntry.get(entry);
    if (record === undefined && (previousText.length === 0 || this.bigrams.size === 0)) {
      return 0;
    }
    const today = this.day();
    let score = 0;
    if (record !== undefined) {
      score += WEIGHT_USER * Math.log(1 + decayedCount(record.count, record.lastDay, today));
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
    // 整句候选是引擎拼出来的，确认两次才学成新词；用户分段选出的词组是自己拼的，确认一次就学
    for (const segment of segments) {
      const sentence = segment.source === CandidateSource.SENTENCE;
      this.touchWord(segment.syllables, segment.text, today, sentence, sentence);
    }
    if (segments.length >= 2) {
      let phrase = '';
      let syllables: string[] = [];
      for (const segment of segments) {
        phrase += segment.text;
        syllables = syllables.concat(segment.syllables);
      }
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
    this.maxSyllableCount = 0;
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

  // ---------- 内部 ----------

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
    const record: WordRecord = { entry: entry, learned: baseEntry === undefined, count: count, lastDay: today };
    this.addRecord(identity, record);
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
  }

  private removeRecord(identity: string, record: WordRecord): void {
    this.words.delete(identity);
    this.recordsByEntry.delete(record.entry);
    this.learnedEntries.delete(record.entry);
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

  serialize(): string {
    const words: UserWordRow[] = [];
    this.words.forEach((record: WordRecord) => {
      const row: UserWordRow = {
        s: record.entry.syllables.join(' '),
        w: record.entry.word,
        c: Math.round(record.count * 1000) / 1000,
        d: record.lastDay
      };
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
    const file: UserLexiconFile = { version: FILE_VERSION, words: words, bigrams: bigrams, pending: pending };
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
    this.maxSyllableCount = 0;
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
      const record: WordRecord = { entry: entry, learned: baseEntry === undefined, count: row.c, lastDay: row.d };
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
    this.dirty = false;
    this.changes++;
  }
}
