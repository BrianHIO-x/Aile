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
 * 同一个桶里读音完全相同的词条，按概率从高到低排列，共用同一个音节数组。
 */
export interface SyllableGroup {
  // 音节以空格连接
  key: string;
  syllables: string[];
  entries: LexiconEntry[];
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
// 查过的索引键缓存起来，个数超过上限时丢掉其中不在索引里的键，已解析的桶保留
const SLOT_CACHE_LIMIT: number = 40000;

// 一个索引键在数据段里的范围。只是其他键的前缀时范围为空；词条与分组在第一次查询时才解析
interface BucketSlot {
  start: number;
  end: number;
  entries: LexiconEntry[] | undefined;
  // 按读音分组，组的顺序按组内最高的概率排列
  groups: SyllableGroup[] | undefined;
  byKey: Map<string, SyllableGroup> | undefined;
}

const EMPTY_GROUPS: SyllableGroup[] = [];

// 缓存里表示“索引里没有这个键”
const MISSING_SLOT: BucketSlot = { start: 0, end: 0, entries: undefined, groups: undefined, byKey: undefined };

/**
 * 基础词库，按每个音节首字母组成的键建立索引，桶内按对数概率从高到低排列。
 * 词库文件由构建脚本预先分好桶、排好序并算好对数概率。索引各行按键排序，加载时只保存文本，
 * 查询某个键时在索引上二分查找，每个桶在第一次查询时才解析，输入法启动时不必解析三万多行索引和十几万个词条。
 * 索引同时列出全部键的前缀，搜索音节组合时据此剪枝。
 */
export class Lexicon {
  private slots: Map<string, BucketSlot> = new Map<string, BucketSlot>();
  private text: string = '';
  private indexStart: number = 0;
  private indexEnd: number = 0;
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
    if (!Number.isFinite(total) || total <= 0) {
      return empty;
    }
    // 索引从第二行开始，到 “#data” 一行为止
    const markLine = text.indexOf('\n' + DATA_MARK, headerEnd);
    if (markLine < 0) {
      return empty;
    }
    this.text = text;
    this.indexStart = headerEnd + 1;
    this.indexEnd = markLine + 1;
    this.dataStart = this.indexEnd + DATA_MARK.length;
    this.logTotal = Math.log(total);
    this.entryCount = entries;
    this.maxSyllableCount = Number(header[5]);
    this.minLogProb = Number(header[6]);
    const result: LexiconLoadResult = { entries: entries, totalFreq: total };
    return result;
  }

  hasKeyPrefix(prefix: string): boolean {
    return this.slot(prefix) !== undefined;
  }

  lookup(initialsKey: string): LexiconEntry[] {
    const slot = this.parsedSlot(initialsKey);
    return slot !== undefined && slot.entries !== undefined ? slot.entries : EMPTY_BUCKET;
  }

  /**
   * 桶内按读音分组的词条。音节组合含有简拼或没打完的音节时，逐组核对读音，比逐个词条核对少得多。
   */
  groups(initialsKey: string): SyllableGroup[] {
    const slot = this.parsedSlot(initialsKey);
    return slot !== undefined && slot.groups !== undefined ? slot.groups : EMPTY_GROUPS;
  }

  /**
   * 读音完全一致的一组词条，syllableKey 为以空格连接的音节。全是完整音节时直接取出，不必遍历整个桶。
   */
  group(initialsKey: string, syllableKey: string): SyllableGroup | undefined {
    const slot = this.parsedSlot(initialsKey);
    return slot !== undefined && slot.byKey !== undefined ? slot.byKey.get(syllableKey) : undefined;
  }

  private parsedSlot(initialsKey: string): BucketSlot | undefined {
    const slot = this.slot(initialsKey);
    if (slot === undefined || slot.end <= slot.start) {
      return undefined;
    }
    if (slot.entries === undefined) {
      this.parseBucket(slot);
    }
    return slot;
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

  private slot(key: string): BucketSlot | undefined {
    const cached = this.slots.get(key);
    if (cached !== undefined) {
      return cached === MISSING_SLOT ? undefined : cached;
    }
    if (this.text.length === 0) {
      return undefined;
    }
    const found = this.findSlot(key);
    if (this.slots.size >= SLOT_CACHE_LIMIT) {
      const kept: Map<string, BucketSlot> = new Map<string, BucketSlot>();
      this.slots.forEach((slot: BucketSlot, name: string) => {
        if (slot !== MISSING_SLOT) {
          kept.set(name, slot);
        }
      });
      this.slots = kept;
    }
    this.slots.set(key, found !== undefined ? found : MISSING_SLOT);
    return found;
  }

  // 索引各行为“键<TAB>起点<TAB>长度”并按键排序，取区间中点所在的行比较，不必预先建立映射
  private findSlot(key: string): BucketSlot | undefined {
    const text = this.text;
    let low = this.indexStart;
    let high = this.indexEnd;
    while (low < high) {
      const middle = (low + high) >>> 1;
      const lineStart = text.lastIndexOf('\n', middle - 1) + 1;
      const firstTab = text.indexOf('\t', lineStart);
      const lineEnd = text.indexOf('\n', lineStart);
      if (firstTab < 0 || lineEnd < 0 || firstTab > lineEnd) {
        return undefined;
      }
      const name = text.substring(lineStart, firstTab);
      if (name === key) {
        const secondTab = text.indexOf('\t', firstTab + 1);
        const start = Number(text.substring(firstTab + 1, secondTab));
        const slot: BucketSlot = {
          start: start,
          end: start + Number(text.substring(secondTab + 1, lineEnd)),
          entries: undefined,
          groups: undefined,
          byKey: undefined
        };
        return slot;
      }
      if (name < key) {
        low = lineEnd + 1;
      } else {
        high = lineStart;
      }
    }
    return undefined;
  }

  // 桶内每行为“音节 音节<TAB>词<TAB>词频”，构建时已按词频从高到低排好，这里换算成对数概率，同时按读音分组
  private parseBucket(slot: BucketSlot): void {
    const entries: LexiconEntry[] = [];
    const groups: SyllableGroup[] = [];
    const byKey: Map<string, SyllableGroup> = new Map<string, SyllableGroup>();
    let position = this.dataStart + slot.start;
    const limit = this.dataStart + slot.end;
    while (position < limit) {
      let lineEnd = this.text.indexOf('\n', position);
      if (lineEnd < 0 || lineEnd > limit) {
        lineEnd = limit;
      }
      const firstTab = this.text.indexOf('\t', position);
      const secondTab = this.text.indexOf('\t', firstTab + 1);
      if (firstTab > position && secondTab > firstTab && secondTab < lineEnd) {
        const key = this.text.substring(position, firstTab);
        let group = byKey.get(key);
        if (group === undefined) {
          const created: SyllableGroup = { key: key, syllables: key.split(' '), entries: [] };
          group = created;
          byKey.set(key, created);
          groups.push(created);
        }
        const entry: LexiconEntry = {
          syllables: group.syllables,
          word: this.text.substring(firstTab + 1, secondTab),
          logProb: Math.log(Number(this.text.substring(secondTab + 1, lineEnd))) - this.logTotal
        };
        entries.push(entry);
        group.entries.push(entry);
      }
      position = lineEnd + 1;
    }
    slot.entries = entries;
    slot.groups = groups;
    slot.byKey = byKey;
  }
}
