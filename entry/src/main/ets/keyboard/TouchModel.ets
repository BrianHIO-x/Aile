import { KeyRect } from './LayoutEngine';

/**
 * 一次字母按键的落点，相对按键单元格中心，以单元格宽高为单位。keyId 为空表示没有落点记录。
 */
export interface TapSample {
  keyId: string;
  dx: number;
  dy: number;
}

export const NO_TAP: TapSample = { keyId: '', dx: 0, dy: 0 };

export interface TouchOffset {
  dx: number;
  dy: number;
}

const ZERO_OFFSET: TouchOffset = { dx: 0, dy: 0 };

// 每个按键至少确认这么多次落点以后，偏移量才参与纠错
export const MIN_TOUCH_SAMPLES: number = 20;
// 偏移量上限，以单元格宽高为单位。拇指斜着够键时的固定偏移一般在这个范围之内
export const MAX_TOUCH_OFFSET: number = 0.3;
// 新样本的最小权重。样本少时按算术平均，样本多了以后按这个权重滑动更新，习惯变化时可以慢慢跟上
const MIN_UPDATE_WEIGHT: number = 0.03;
const FILE_VERSION: number = 1;

interface OffsetRecord {
  dx: number;
  dy: number;
  n: number;
}

interface OffsetRow {
  k: string;
  x: number;
  y: number;
  n: number;
}

interface TouchModelFile {
  version: number;
  keys: OffsetRow[];
}

/**
 * 确认过的一段拼音：打出的字母、每个字母的落点，以及最终提交的音节。
 */
export interface ConfirmedTyping {
  code: string;
  syllables: string[];
  taps: TapSample[];
}

function clamp(value: number): number {
  return Math.max(-MAX_TOUCH_OFFSET, Math.min(MAX_TOUCH_OFFSET, value));
}

/**
 * 按键落点模型：记录每个字母键上确认过的落点相对中心的平均偏移。
 * 纠错计算邻键代价时，把按键中心换成“中心 + 偏移”，拇指固定偏向某一侧的落点不再被当成误触。
 * 分离布局与常规布局分开记录，键的编号带布局前缀。
 */
export class TouchModel {
  private static instance: TouchModel | undefined = undefined;
  private records: Map<string, OffsetRecord> = new Map<string, OffsetRecord>();
  private dirty: boolean = false;
  private changeListener: () => void = () => {
  };

  static get(): TouchModel {
    if (TouchModel.instance === undefined) {
      TouchModel.instance = new TouchModel();
    }
    return TouchModel.instance;
  }

  setChangeListener(listener: () => void): void {
    this.changeListener = listener;
  }

  isDirty(): boolean {
    return this.dirty;
  }

  markClean(): void {
    this.dirty = false;
  }

  keyCount(): number {
    return this.records.size;
  }

  static sampleOf(prefix: string, rect: KeyRect, x: number, y: number): TapSample {
    if (rect.cellW <= 0 || rect.cellH <= 0) {
      return NO_TAP;
    }
    const sample: TapSample = {
      keyId: `${prefix}:${rect.key.id}`,
      dx: (x - (rect.cellX + rect.cellW / 2)) / rect.cellW,
      dy: (y - (rect.cellY + rect.cellH / 2)) / rect.cellH
    };
    return sample;
  }

  offsetOf(prefix: string, rect: KeyRect): TouchOffset {
    const record = this.records.get(`${prefix}:${rect.key.id}`);
    if (record === undefined || record.n < MIN_TOUCH_SAMPLES) {
      return ZERO_OFFSET;
    }
    const offset: TouchOffset = { dx: clamp(record.dx), dy: clamp(record.dy) };
    return offset;
  }

  /**
   * 只学习确认无误的字母：提交的音节拼起来与打出的字母逐个对得上的位置。
   * 简拼、纠错与模糊音让两者长度或字母不同，这些位置不参与学习。
   */
  learn(typings: ConfirmedTyping[]): void {
    let changed = false;
    for (const typing of typings) {
      const expected = typing.syllables.join('');
      let letters = '';
      const taps: TapSample[] = [];
      for (let i = 0; i < typing.code.length; i++) {
        const ch = typing.code.charAt(i);
        if (ch >= 'a' && ch <= 'z') {
          letters += ch;
          taps.push(i < typing.taps.length ? typing.taps[i] : NO_TAP);
        }
      }
      if (letters.length !== expected.length) {
        continue;
      }
      for (let i = 0; i < letters.length; i++) {
        if (letters.charAt(i) === expected.charAt(i) && taps[i].keyId.length > 0) {
          this.record(taps[i]);
          changed = true;
        }
      }
    }
    if (changed) {
      this.dirty = true;
      this.changeListener();
    }
  }

  clear(): void {
    this.records.clear();
    this.dirty = true;
    this.changeListener();
  }

  private record(sample: TapSample): void {
    // 落在单元格之外很远的样本多半是按错了别的键，不参与统计
    if (Math.abs(sample.dx) > 0.75 || Math.abs(sample.dy) > 0.75) {
      return;
    }
    const record = this.records.get(sample.keyId);
    if (record === undefined) {
      const created: OffsetRecord = { dx: sample.dx, dy: sample.dy, n: 1 };
      this.records.set(sample.keyId, created);
      return;
    }
    record.n++;
    const weight = Math.max(1 / record.n, MIN_UPDATE_WEIGHT);
    record.dx += (sample.dx - record.dx) * weight;
    record.dy += (sample.dy - record.dy) * weight;
  }

  serialize(): string {
    const keys: OffsetRow[] = [];
    this.records.forEach((record: OffsetRecord, key: string) => {
      const row: OffsetRow = {
        k: key,
        x: Math.round(record.dx * 10000) / 10000,
        y: Math.round(record.dy * 10000) / 10000,
        n: record.n
      };
      keys.push(row);
    });
    const file: TouchModelFile = { version: FILE_VERSION, keys: keys };
    return JSON.stringify(file);
  }

  /**
   * 解析失败时抛出异常，由调用方备份损坏文件并从空记录开始。
   */
  deserialize(text: string): void {
    const file = JSON.parse(text) as TouchModelFile;
    if (file === null || file.version !== FILE_VERSION || !Array.isArray(file.keys)) {
      throw new Error('invalid touch model file');
    }
    this.records.clear();
    for (const row of file.keys) {
      if (typeof row.k !== 'string' || typeof row.x !== 'number' || typeof row.y !== 'number' ||
        typeof row.n !== 'number' || !Number.isFinite(row.x) || !Number.isFinite(row.y) || row.n <= 0) {
        continue;
      }
      const record: OffsetRecord = { dx: row.x, dy: row.y, n: Math.floor(row.n) };
      this.records.set(row.k, record);
    }
    this.dirty = false;
  }
}
