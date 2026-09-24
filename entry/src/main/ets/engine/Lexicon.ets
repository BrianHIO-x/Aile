export interface LexiconEntry {
  syllables: string[];
  word: string;
  logProb: number;
}

export interface LexiconLoadResult {
  entries: number;
  totalFreq: number;
}

/**
 * 索引键中的一个字母：取音节首字母，n 与 r 归入 l，f 归入 h。
 * 模糊音两种读音的词因此落在同一个桶里，查询时再逐个核对读音，关闭模糊音时只多核对几个词条。
 */
export function keyLetter(text: string): string {
  const c = text.charAt(0);
  if (c === 'n' || c === 'r') {
    return 'l';
  }
  if (c === 'f') {
    return 'h';
  }
  return c;
}

export function initialsKeyOf(syllables: string[]): string {
  let key = '';
  for (const syllable of syllables) {
    key += keyLetter(syllable);
  }
  return key;
}

/**
 * 把索引键的全部前缀计入表中，删除时计数减一，计数为零即移除。
 */
export function countKeyPrefixes(counts: Map<string, number>, key: string, delta: number): void {
  for (let i = 1; i <= key.length; i++) {
    const prefix = key.substring(0, i);
    const next = (counts.get(prefix) ?? 0) + delta;
    if (next > 0) {
      counts.set(prefix, next);
    } else {
      counts.delete(prefix);
    }
  }
}

export function entryIdentity(syllables: string[], word: string): string {
  return `${syllables.join(' ')}\t${word}`;
}

// 词库文件的格式标记，见 tools/build-lexicon.mjs
const FORMAT_MARK: string = '#aile-lexicon';
const FORMAT_VERSION: string = '2';
const DATA_MARK: string = '#data\n';
const EMPTY_BUCKET: LexiconEntry[] = [];

// 一个索引键在数据段里的范围。只是其他键的前缀时范围为空；entries 在第一次查询时才解析
interface BucketSlot {
  start: number;
  end: number;
  entries: LexiconEntry[] | undefined;
}

/**
 * 基础词库，按每个音节首字母组成的键建立索引，桶内按对数概率从高到低排列。
 * 词库文件由构建脚本预先分好桶、排好序并算好对数概率，加载时只读索引，每个桶在第一次查询时才解析，
 * 输入法启动时不必一次解析六万多个词条。索引同时列出全部键的前缀，搜索音节组合时据此剪枝。
 */
export class Lexicon {
  private slots: Map<string, BucketSlot> = new Map<string, BucketSlot>();
  private text: string = '';
  private dataStart: number = 0;
  private logTotal: number = 0;
  private entryCount: number = 0;
  private minLogProb: number = -20;
  private maxSyllableCount: number = 0;

  size(): number {
    return this.entryCount;
  }

  floorLogProb(): number {
    return this.minLogProb;
  }

  maxSyllables(): number {
    return this.maxSyllableCount;
  }

  /**
   * 文本格式见 tools/build-lexicon.mjs。首行为格式标记与统计，其后每行一个索引键及其数据范围，
   * “#data” 之后为按桶排列的词条。格式不符时词库为空，由调用方按加载失败处理。
   */
  loadFromText(text: string): LexiconLoadResult {
    this.slots.clear();
    this.text = '';
    this.entryCount = 0;
    this.maxSyllableCount = 0;
    const empty: LexiconLoadResult = { entries: 0, totalFreq: 0 };
    const headerEnd = text.indexOf('\n');
    if (headerEnd < 0) {
      return empty;
    }
    const header = text.substring(0, headerEnd).split('\t');
    if (header.length < 7 || header[0] !== FORMAT_MARK || header[1] !== FORMAT_VERSION) {
      return empty;
    }
    const total = Number(header[2]);
    const entries = Number(header[3]);
    const slotCount = Number(header[4]);
    if (!Number.isFinite(total) || total <= 0) {
      return empty;
    }
    let position = headerEnd + 1;
    for (let i = 0; i < slotCount; i++) {
      const lineEnd = text.indexOf('\n', position);
      if (lineEnd < 0) {
        this.slots.clear();
        return empty;
      }
      const firstTab = text.indexOf('\t', position);
      const secondTab = text.indexOf('\t', firstTab + 1);
      const start = Number(text.substring(firstTab + 1, secondTab));
      const slot: BucketSlot = {
        start: start,
        end: start + Number(text.substring(secondTab + 1, lineEnd)),
        entries: undefined
      };
      this.slots.set(text.substring(position, firstTab), slot);
      position = lineEnd + 1;
    }
    if (!text.startsWith(DATA_MARK, position)) {
      this.slots.clear();
      return empty;
    }
    this.text = text;
    this.dataStart = position + DATA_MARK.length;
    this.logTotal = Math.log(total);
    this.entryCount = entries;
    this.maxSyllableCount = Number(header[5]);
    this.minLogProb = Number(header[6]);
    const result: LexiconLoadResult = { entries: entries, totalFreq: total };
    return result;
  }

  hasKeyPrefix(prefix: string): boolean {
    return this.slots.has(prefix);
  }

  lookup(initialsKey: string): LexiconEntry[] {
    const slot = this.slots.get(initialsKey);
    if (slot === undefined || slot.end <= slot.start) {
      return EMPTY_BUCKET;
    }
    if (slot.entries === undefined) {
      slot.entries = this.parseBucket(slot.start, slot.end);
    }
    return slot.entries;
  }

  find(syllables: string[], word: string): LexiconEntry | undefined {
    for (const entry of this.lookup(initialsKeyOf(syllables))) {
      if (entry.word === word && entry.syllables.length === syllables.length &&
        entry.syllables.join(' ') === syllables.join(' ')) {
        return entry;
      }
    }
    return undefined;
  }

  // 桶内每行为“音节 音节<TAB>词<TAB>词频”，构建时已按词频从高到低排好，这里换算成对数概率
  private parseBucket(start: number, end: number): LexiconEntry[] {
    const entries: LexiconEntry[] = [];
    let position = this.dataStart + start;
    const limit = this.dataStart + end;
    while (position < limit) {
      let lineEnd = this.text.indexOf('\n', position);
      if (lineEnd < 0 || lineEnd > limit) {
        lineEnd = limit;
      }
      const firstTab = this.text.indexOf('\t', position);
      const secondTab = this.text.indexOf('\t', firstTab + 1);
      if (firstTab > position && secondTab > firstTab && secondTab < lineEnd) {
        const entry: LexiconEntry = {
          syllables: this.text.substring(position, firstTab).split(' '),
          word: this.text.substring(firstTab + 1, secondTab),
          logProb: Math.log(Number(this.text.substring(secondTab + 1, lineEnd))) - this.logTotal
        };
        entries.push(entry);
      }
      position = lineEnd + 1;
    }
    return entries;
  }
}
