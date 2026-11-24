import { TransitionModel } from './PinyinEngine';

// 二元模型给出的修正量乘以这个权重再计入整句得分，1 表示按模型原样计算
export const BIGRAM_WEIGHT: number = 1.0;
// 一段话的开头，上文为空时用它作为前一个词
export const SENTENCE_START: string = '<s>';
// 上文里最多取末尾几个字查找前一个词
const MAX_CONTEXT_CHARS: number = 4;
// 解析过的前词分两类缓存。<s>、我、的这类大行解析一次要几毫秒，解析后一直保留；
// 其余的行按组合数计量，超过预算时整体清空
const LARGE_ROW_PAIRS: number = 400;
const SMALL_ROW_BUDGET: number = 60000;
// 查过但没有记录的前词也缓存起来，个数超过上限时清空
const MISS_LIMIT: number = 4096;
const FORMAT_MARK: string = '#aile-bigram';
const FORMAT_VERSION: string = '2';
const NEUTRAL_MARK: string = '#neutral\t';

export interface BigramLoadResult {
  pairs: number;
  words: number;
}

// 一个前词的回退权重与有记录的后词，数值已换算回自然对数
interface BigramRow {
  alpha: number;
  next: Map<string, number>;
}

/**
 * 带回退的二元语言模型，文本格式见 tools/build-bigram.mjs。
 * 每行是一个前词，各行按前词排序，加载时只保存文本，查询时二分查找到这一行再解析，常用的行缓存起来。
 * 查询结果是在后词自身概率之外需要加上的部分：有记录时为 ln P(后|前) - ln P(后)，没有记录时为 ln α(前)，
 * 前词没有记录时为 0。
 */
export class BigramModel implements TransitionModel {
  private text: string = '';
  private bodyStart: number = 0;
  private quant: number = 10;
  private rowCount: number = 0;
  private pairCount: number = 0;
  private weight: number = BIGRAM_WEIGHT;
  private largeRows: Map<string, BigramRow> = new Map<string, BigramRow>();
  private smallRows: Map<string, BigramRow> = new Map<string, BigramRow>();
  private misses: Set<string> = new Set<string>();
  // LCCC 语料过滤掉的词，作为后词时没有记录也不套用回退扣分
  private neutral: Set<string> = new Set<string>();
  private smallPairs: number = 0;

  setWeight(weight: number): void {
    this.weight = weight;
  }

  size(): number {
    return this.pairCount;
  }

  loadFromText(text: string): BigramLoadResult {
    this.text = '';
    this.largeRows.clear();
    this.smallRows.clear();
    this.misses.clear();
    this.neutral.clear();
    this.smallPairs = 0;
    this.rowCount = 0;
    this.pairCount = 0;
    const headerEnd = text.indexOf('\n');
    const header = headerEnd > 0 ? text.substring(0, headerEnd).split('\t') : [];
    if (header.length < 5 || header[0] !== FORMAT_MARK || header[1] !== FORMAT_VERSION) {
      const empty: BigramLoadResult = { pairs: 0, words: 0 };
      return empty;
    }
    let bodyStart = headerEnd + 1;
    if (text.startsWith(NEUTRAL_MARK, bodyStart)) {
      const lineEnd = text.indexOf('\n', bodyStart);
      for (const word of text.substring(bodyStart + NEUTRAL_MARK.length, lineEnd).split(' ')) {
        if (word.length > 0) {
          this.neutral.add(word);
        }
      }
      bodyStart = lineEnd + 1;
    }
    this.text = text;
    this.bodyStart = bodyStart;
    this.rowCount = Number(header[2]);
    this.pairCount = Number(header[3]);
    this.quant = Number(header[4]);
    const result: BigramLoadResult = { pairs: this.pairCount, words: this.rowCount };
    return result;
  }

  bonus(previous: string, next: string): number {
    const row = this.row(previous);
    if (row === undefined) {
      return 0;
    }
    const value = row.next.get(next);
    if (value !== undefined) {
      return this.weight * value;
    }
    return this.neutral.has(next) ? 0 : this.weight * row.alpha;
  }

  /**
   * 上文末尾作为前一个词：从最长的末尾片段往短里找有记录的词，上文为空时为一段话的开头，都没有时为空串。
   */
  contextOf(previousText: string): string {
    if (previousText.length === 0) {
      return SENTENCE_START;
    }
    const longest = Math.min(MAX_CONTEXT_CHARS, previousText.length);
    for (let length = longest; length >= 1; length--) {
      const tail = previousText.substring(previousText.length - length);
      if (this.row(tail) !== undefined) {
        return tail;
      }
    }
    return '';
  }

  private row(word: string): BigramRow | undefined {
    if (word.length === 0 || this.text.length === 0) {
      return undefined;
    }
    const cached = this.smallRows.get(word) ?? this.largeRows.get(word);
    if (cached !== undefined) {
      return cached;
    }
    if (this.misses.has(word)) {
      return undefined;
    }
    const found = this.findRow(word);
    if (found === undefined) {
      if (this.misses.size >= MISS_LIMIT) {
        this.misses.clear();
      }
      this.misses.add(word);
      return undefined;
    }
    if (found.next.size >= LARGE_ROW_PAIRS) {
      this.largeRows.set(word, found);
      return found;
    }
    if (this.smallPairs + found.next.size > SMALL_ROW_BUDGET) {
      this.smallRows.clear();
      this.smallPairs = 0;
    }
    this.smallRows.set(word, found);
    this.smallPairs += found.next.size;
    return found;
  }

  // 各行按前词排序，在文本上直接二分：取区间中点所在的行比较前词，不必预先建立索引
  private findRow(word: string): BigramRow | undefined {
    const text = this.text;
    let low = this.bodyStart;
    let high = text.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      const lineStart = text.lastIndexOf('\n', middle - 1) + 1;
      const keyEnd = text.indexOf('\t', lineStart);
      let lineEnd = text.indexOf('\n', lineStart);
      if (lineEnd < 0) {
        lineEnd = text.length;
      }
      if (keyEnd < 0 || keyEnd > lineEnd) {
        return undefined;
      }
      const key = text.substring(lineStart, keyEnd);
      if (key === word) {
        return this.parseRow(keyEnd + 1, lineEnd);
      }
      if (key < word) {
        low = lineEnd + 1;
      } else {
        high = lineStart;
      }
    }
    return undefined;
  }

  private parseRow(start: number, end: number): BigramRow {
    const alphaEnd = this.text.indexOf('\t', start);
    const next: Map<string, number> = new Map<string, number>();
    const items = this.text.substring(alphaEnd + 1, end).split(' ');
    for (let i = 0; i + 1 < items.length; i += 2) {
      next.set(items[i], Number(items[i + 1]) / this.quant);
    }
    const row: BigramRow = { alpha: Number(this.text.substring(start, alphaEnd)) / this.quant, next: next };
    return row;
  }
}
