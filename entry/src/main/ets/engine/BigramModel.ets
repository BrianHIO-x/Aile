import { TransitionModel } from './PinyinEngine';

// 相邻两个词在训练语料里一起出现的次数换成加分：权重 × log(1 + 次数)，次数超过上限按上限计。
// 权重取自 engine-bench 调参半边的结果：2.0 到 3.0 之间整句准确率相差一句，再往上简拼开始下降，取偏保守的 2.0
export const BIGRAM_WEIGHT: number = 2.0;
export const BIGRAM_COUNT_CAP: number = 60;

export interface BigramLoadResult {
  pairs: number;
  words: number;
}

/**
 * 词间搭配模型。文本格式见 tools/build-bigram.mjs：每行为“前一个词<TAB>后一个词<TAB>次数”。
 * 只给语料里出现过的搭配加分，没出现过的搭配不扣分，整句得分因此与没有模型时可以直接比较。
 */
export class BigramModel implements TransitionModel {
  private links: Map<string, Map<string, number>> = new Map<string, Map<string, number>>();
  private pairCount: number = 0;
  private weight: number = BIGRAM_WEIGHT;

  setWeight(weight: number): void {
    this.weight = weight;
  }

  size(): number {
    return this.pairCount;
  }

  loadFromText(text: string): BigramLoadResult {
    this.links.clear();
    this.pairCount = 0;
    const lines = text.split('\n');
    for (const line of lines) {
      if (line.length === 0 || line.charAt(0) === '#') {
        continue;
      }
      const parts = line.split('\t');
      if (parts.length !== 3) {
        continue;
      }
      const count = Number(parts[2]);
      if (!Number.isFinite(count) || count <= 0) {
        continue;
      }
      let next = this.links.get(parts[0]);
      if (next === undefined) {
        next = new Map<string, number>();
        this.links.set(parts[0], next);
      }
      next.set(parts[1], Math.log(1 + Math.min(count, BIGRAM_COUNT_CAP)));
      this.pairCount++;
    }
    const result: BigramLoadResult = { pairs: this.pairCount, words: this.links.size };
    return result;
  }

  bonus(previous: string, next: string): number {
    const row = this.links.get(previous);
    if (row === undefined) {
      return 0;
    }
    const value = row.get(next);
    return value !== undefined ? this.weight * value : 0;
  }
}
