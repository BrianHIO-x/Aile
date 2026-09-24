import { LetterAlternative } from '../engine/EngineTypes';
import { KeyType } from './KeyDefinitions';
import { KeyRect } from './LayoutEngine';
import { TouchOffset } from './TouchModel';

// 按键中心的偏移，以单元格宽高为单位；没有学习记录时为 0
export type OffsetProvider = (rect: KeyRect) => TouchOffset;

const NO_OFFSET: OffsetProvider = (rect: KeyRect): TouchOffset => {
  const zero: TouchOffset = { dx: 0, dy: 0 };
  return zero;
};

// 手指落点围绕目标按键中心呈正态分布，标准差以按键单元格的宽高为单位
const TOUCH_SIGMA: number = 0.42;
const TWO_SIGMA_SQUARED: number = 2 * TOUCH_SIGMA * TOUCH_SIGMA;
// 按到相邻按键的先验代价，落点正好在两个按键交界处时只剩这部分
const ALTERNATIVE_BASE_COST: number = 0.8;
// 超过这个代价的相邻按键不再记录，按在按键正中时仍会保留左右和上下相邻的按键，供拼音无法切分时补救
export const MAX_ALTERNATIVE_COST: number = 5.0;
const MAX_ALTERNATIVES: number = 4;

// 落点到按键中心的距离平方。中心按学习到的偏移移动，拇指固定偏向一侧时，落点仍然离自己的按键最近
function centerDistanceSquared(rect: KeyRect, offset: TouchOffset, x: number, y: number, unitW: number,
  unitH: number): number {
  const dx = (x - (rect.cellX + rect.cellW * (0.5 + offset.dx))) / unitW;
  const dy = (y - (rect.cellY + rect.cellH * (0.5 + offset.dy))) / unitH;
  return dx * dx + dy * dy;
}

/**
 * 计算一次字母按键的落点附近还有哪些字母。代价是两个按键产生该落点的对数似然之差加上先验代价，
 * 只比较同一键区内的字母键，分离布局下左右键区相隔很远，不会互相替换。
 */
export function letterAlternatives(rects: KeyRect[], hit: KeyRect, x: number, y: number,
  offsetOf: OffsetProvider = NO_OFFSET): LetterAlternative[] {
  if (hit.key.type !== KeyType.LETTER || hit.cellW <= 0 || hit.cellH <= 0) {
    return [];
  }
  const unitW = hit.cellW;
  const unitH = hit.cellH;
  const typed = hit.key.output;
  const hitDistance = centerDistanceSquared(hit, offsetOf(hit), x, y, unitW, unitH);
  const costs: Map<string, number> = new Map<string, number>();
  for (const rect of rects) {
    if (rect.key.type !== KeyType.LETTER || rect.paneIndex !== hit.paneIndex || rect.key.output === typed) {
      continue;
    }
    const extra = Math.max(0, centerDistanceSquared(rect, offsetOf(rect), x, y, unitW, unitH) - hitDistance);
    const cost = ALTERNATIVE_BASE_COST + extra / TWO_SIGMA_SQUARED;
    if (cost > MAX_ALTERNATIVE_COST) {
      continue;
    }
    const letter = rect.key.output;
    const previous = costs.get(letter);
    if (previous === undefined || cost < previous) {
      costs.set(letter, cost);
    }
  }
  const result: LetterAlternative[] = [];
  costs.forEach((cost: number, letter: string) => {
    const alternative: LetterAlternative = { letter: letter, cost: cost };
    result.push(alternative);
  });
  result.sort((a: LetterAlternative, b: LetterAlternative) => a.cost - b.cost);
  return result.slice(0, MAX_ALTERNATIVES);
}
