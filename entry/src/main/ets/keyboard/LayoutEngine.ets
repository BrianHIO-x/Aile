import { KeyboardLayout, KeyDef, KeyType, LayoutForm, PaneDef, PaneSide, RowDef } from './KeyDefinitions';
import { LayoutProfile } from './LayoutProfile';

export const CENTER_GAP_MIN_VP: number = 16;

export interface KeyRect {
  key: KeyDef;
  paneIndex: number;
  // 键帽可视矩形，组件局部坐标，单位 vp
  x: number;
  y: number;
  w: number;
  h: number;
  // 命中单元格，包含键间距
  cellX: number;
  cellY: number;
  cellW: number;
  cellH: number;
}

export interface PaneBounds {
  x: number;
  width: number;
}

// 跨行按键在下面某一行占住的横向区间
interface SpanReserve {
  start: number;
  end: number;
}

const SPAN_EPSILON_VP: number = 0.01;

function keySpan(key: KeyDef): number {
  return key.rowSpan !== undefined && key.rowSpan > 1 ? Math.floor(key.rowSpan) : 1;
}

// 空格宽度的设置只作用于最下排横放的空格，竖着跨行的空格沿用所在一列的宽度
function keyWeight(key: KeyDef, form: LayoutForm, profile: LayoutProfile): number {
  if (form === LayoutForm.SPLIT && key.type === KeyType.SPACE && keySpan(key) === 1) {
    return profile.spaceWeight;
  }
  return key.weight;
}

function mirrorsLeft(r: RowDef, form: LayoutForm): boolean {
  return form === LayoutForm.SPLIT && r.mirrorLeft === true;
}

// 每行的宽度算上从上面几行跨下来的按键。按左手区换算的行不参与计算，右手区的键宽只由上面几行决定
function paneWeight(pane: PaneDef, form: LayoutForm, profile: LayoutProfile): number {
  const carried: number[] = [];
  for (let i = 0; i < pane.rows.length; i++) {
    carried.push(0);
  }
  let maxWeight = 0;
  for (let rowIndex = 0; rowIndex < pane.rows.length; rowIndex++) {
    const r = pane.rows[rowIndex];
    if (mirrorsLeft(r, form)) {
      continue;
    }
    let total = r.lead + carried[rowIndex];
    for (const k of r.keys) {
      const weight = keyWeight(k, form, profile);
      total += weight;
      const last = Math.min(pane.rows.length, rowIndex + keySpan(k));
      for (let below = rowIndex + 1; below < last; below++) {
        carried[below] += weight;
      }
    }
    maxWeight = Math.max(maxWeight, total);
  }
  return maxWeight;
}

// 光标落在上面跨下来的按键区间里时，移到区间的右端
function skipReserved(reserved: SpanReserve[], cursor: number): number {
  let next = cursor;
  for (const span of reserved) {
    if (next >= span.start - SPAN_EPSILON_VP && next < span.end - SPAN_EPSILON_VP) {
      next = span.end;
    }
  }
  return next;
}

// 右手区中向左伸出的行，例如 H 左侧多出的 G，返回伸出的权重
function paneOverhang(pane: PaneDef): number {
  let overhang = 0;
  for (const r of pane.rows) {
    overhang = Math.max(overhang, -r.lead);
  }
  return overhang;
}

export function computePaneBounds(layout: KeyboardLayout, width: number, profile: LayoutProfile): PaneBounds[] {
  const bounds: PaneBounds[] = [];
  const marginLeft = Math.min(profile.outerMarginLeftVp, width / 4);
  const marginRight = Math.min(profile.outerMarginRightVp, width / 4);
  const available = Math.max(0, width - marginLeft - marginRight);
  if (layout.panes.length === 1 || layout.form === LayoutForm.NORMAL) {
    const full: PaneBounds = { x: marginLeft, width: available };
    bounds.push(full);
    return bounds;
  }
  let leftWidth = profile.leftPaneWidthVp;
  let rightWidth = profile.rightPaneWidthVp;
  // 右手区伸出的按键占用中央间隙，收缩时按伸出后的宽度计算，伸出的按键不会压到左手区
  let rightReach = 1;
  for (const p of layout.panes) {
    if (p.side === PaneSide.RIGHT) {
      const weight = paneWeight(p, layout.form, profile);
      rightReach = weight > 0 ? 1 + paneOverhang(p) / weight : 1;
    }
  }
  const maxPanes = Math.max(0, available - CENTER_GAP_MIN_VP);
  const needed = leftWidth + rightWidth * rightReach;
  if (needed > maxPanes && needed > 0) {
    const scale = maxPanes / needed;
    leftWidth = leftWidth * scale;
    rightWidth = rightWidth * scale;
  }
  for (const p of layout.panes) {
    if (p.side === PaneSide.RIGHT) {
      const right: PaneBounds = { x: width - marginRight - rightWidth, width: rightWidth };
      bounds.push(right);
    } else {
      const left: PaneBounds = { x: marginLeft, width: leftWidth };
      bounds.push(left);
    }
  }
  return bounds;
}

// 按左手区换算的一行，等左手区排完后再排
interface DeferredRow {
  row: RowDef;
  paneIndex: number;
  bounds: PaneBounds;
  unit: number;
  cellY: number;
  cellH: number;
}

// 中英切换键至少保留的宽度，按右手区键宽计
const MIRROR_FLEX_MIN_UNITS: number = 0.8;

function makeRect(key: KeyDef, paneIndex: number, cellX: number, cellY: number, cellW: number, cellH: number,
  gap: number): KeyRect {
  const rect: KeyRect = {
    key: key,
    paneIndex: paneIndex,
    x: cellX + gap / 2,
    y: cellY + gap / 2,
    w: Math.max(0, cellW - gap),
    h: Math.max(0, cellH - gap),
    cellX: cellX,
    cellY: cellY,
    cellW: cellW,
    cellH: cellH
  };
  return rect;
}

function findRect(rects: KeyRect[], paneIndex: number, id: string): KeyRect | undefined {
  for (const rect of rects) {
    if (rect.paneIndex === paneIndex && rect.key.id === id) {
      return rect;
    }
  }
  return undefined;
}

/**
 * 右手区最下排：空格取左空格的宽度，回车取“符号”左边界到“123”右边界的宽度，其余按键分掉剩下的宽度。
 * 剩余宽度不够时整行再向中间伸出，最多伸到左手区右边界外留出最小中央间隙；仍然不够时缩短空格。
 * 左手区缺少对应按键时返回 false，由调用方按权重排布。
 */
function placeMirroredRow(deferred: DeferredRow, rects: KeyRect[], leftIndex: number, leftBounds: PaneBounds,
  gap: number): boolean {
  const symbol = findRect(rects, leftIndex, 'symbol_page');
  const number = findRect(rects, leftIndex, 'number_page');
  const leftSpace = findRect(rects, leftIndex, 'space_left');
  if (symbol === undefined || number === undefined || leftSpace === undefined) {
    return false;
  }
  const keys = deferred.row.keys;
  let spaceCount = 0;
  let enterCount = 0;
  let flexWeight = 0;
  for (const k of keys) {
    if (k.type === KeyType.SPACE) {
      spaceCount++;
    } else if (k.type === KeyType.ENTER) {
      enterCount++;
    } else {
      flexWeight += k.weight;
    }
  }
  if (spaceCount !== 1 || enterCount !== 1 || flexWeight <= 0) {
    return false;
  }
  const enterW = number.cellX + number.cellW - symbol.cellX;
  let spaceW = leftSpace.cellW;
  const rowEnd = deferred.bounds.x + deferred.bounds.width;
  const flexMin = flexWeight * deferred.unit * MIRROR_FLEX_MIN_UNITS;
  let rowStart = deferred.bounds.x + deferred.row.lead * deferred.unit;
  let flexW = rowEnd - rowStart - spaceW - enterW;
  if (flexW < flexMin) {
    const limit = leftBounds.x + leftBounds.width + CENTER_GAP_MIN_VP;
    rowStart = Math.min(rowStart, Math.max(limit, rowEnd - spaceW - enterW - flexMin));
    flexW = Math.max(flexMin, rowEnd - rowStart - spaceW - enterW);
    spaceW = Math.max(0, rowEnd - rowStart - enterW - flexW);
  }
  let cursor = rowStart;
  for (const k of keys) {
    let cellW = flexW * k.weight / flexWeight;
    if (k.type === KeyType.SPACE) {
      cellW = spaceW;
    } else if (k.type === KeyType.ENTER) {
      cellW = enterW;
    }
    rects.push(makeRect(k, deferred.paneIndex, cursor, deferred.cellY, cellW, deferred.cellH, gap));
    cursor += cellW;
  }
  return true;
}

// 按权重排布一行，deferred 行换算失败时也走这里
function placeWeightedRow(r: RowDef, paneIndex: number, startX: number, unit: number, cellY: number,
  rowPitch: number, rowsLeft: number, reserved: SpanReserve[][], rowIndex: number, form: LayoutForm,
  profile: LayoutProfile, rects: KeyRect[]): void {
  let cursor = startX;
  for (const k of r.keys) {
    cursor = skipReserved(reserved[rowIndex], cursor);
    const cellW = keyWeight(k, form, profile) * unit;
    const span = Math.min(keySpan(k), rowsLeft);
    rects.push(makeRect(k, paneIndex, cursor, cellY, cellW, rowPitch * span, profile.keyGapVp));
    for (let below = rowIndex + 1; below < rowIndex + span; below++) {
      const taken: SpanReserve = { start: cursor, end: cursor + cellW };
      reserved[below].push(taken);
    }
    cursor += cellW;
  }
}

/**
 * 计算全部按键矩形。width 与 height 为按键区域尺寸，底部抬升从按键区域底部扣除。
 */
export function computeKeyRects(layout: KeyboardLayout, width: number, height: number,
  profile: LayoutProfile): KeyRect[] {
  const rects: KeyRect[] = [];
  if (width <= 0 || height <= 0) {
    return rects;
  }
  const usableHeight = Math.max(0, height - Math.min(profile.bottomLiftVp, height / 2));
  const gap = profile.keyGapVp;
  const bounds = computePaneBounds(layout, width, profile);
  const deferredRows: DeferredRow[] = [];
  let leftIndex = -1;
  for (let paneIndex = 0; paneIndex < layout.panes.length; paneIndex++) {
    const pane = layout.panes[paneIndex];
    if (pane.side === PaneSide.LEFT) {
      leftIndex = paneIndex;
    }
    const paneBounds = bounds[paneIndex];
    const totalWeight = paneWeight(pane, layout.form, profile);
    if (totalWeight <= 0 || pane.rows.length === 0) {
      continue;
    }
    const unit = paneBounds.width / totalWeight;
    const rowPitch = usableHeight / pane.rows.length;
    const reserved: SpanReserve[][] = [];
    for (let i = 0; i < pane.rows.length; i++) {
      reserved.push([]);
    }
    for (let rowIndex = 0; rowIndex < pane.rows.length; rowIndex++) {
      const r = pane.rows[rowIndex];
      const cellY = rowIndex * rowPitch;
      if (mirrorsLeft(r, layout.form)) {
        const deferred: DeferredRow = {
          row: r, paneIndex: paneIndex, bounds: paneBounds, unit: unit, cellY: cellY, cellH: rowPitch
        };
        deferredRows.push(deferred);
        continue;
      }
      placeWeightedRow(r, paneIndex, paneBounds.x + r.lead * unit, unit, cellY, rowPitch,
        pane.rows.length - rowIndex, reserved, rowIndex, layout.form, profile, rects);
    }
  }
  for (const deferred of deferredRows) {
    const placed = leftIndex >= 0 && placeMirroredRow(deferred, rects, leftIndex, bounds[leftIndex], gap);
    if (!placed) {
      const noReserve: SpanReserve[][] = [[]];
      placeWeightedRow(deferred.row, deferred.paneIndex, deferred.bounds.x + deferred.row.lead * deferred.unit,
        deferred.unit, deferred.cellY, deferred.cellH, 1, noReserve, 0, layout.form, profile, rects);
    }
  }
  return rects;
}

export function distanceToCell(rect: KeyRect, x: number, y: number): number {
  const dx = Math.max(rect.cellX - x, 0, x - (rect.cellX + rect.cellW));
  const dy = Math.max(rect.cellY - y, 0, y - (rect.cellY + rect.cellH));
  return Math.sqrt(dx * dx + dy * dy);
}

/**
 * 先按单元格精确命中，未命中时在 slop 距离内选取最近的按键，中央间隙超出 slop 的触点返回 undefined。
 */
export function hitTest(rects: KeyRect[], x: number, y: number, slop: number): KeyRect | undefined {
  let nearest: KeyRect | undefined = undefined;
  let nearestDistance = Number.MAX_VALUE;
  for (const rect of rects) {
    const distance = distanceToCell(rect, x, y);
    if (distance === 0) {
      return rect;
    }
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearest = rect;
    }
  }
  if (nearest !== undefined && nearestDistance <= slop) {
    return nearest;
  }
  return undefined;
}
