import { KeyboardLayout, KeyDef, KeyType, LayoutForm, PaneDef, PaneSide } from './KeyDefinitions';
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

// 每行的宽度算上从上面几行跨下来的按键
function paneWeight(pane: PaneDef, form: LayoutForm, profile: LayoutProfile): number {
  const carried: number[] = [];
  for (let i = 0; i < pane.rows.length; i++) {
    carried.push(0);
  }
  let maxWeight = 0;
  for (let rowIndex = 0; rowIndex < pane.rows.length; rowIndex++) {
    const r = pane.rows[rowIndex];
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
  for (let paneIndex = 0; paneIndex < layout.panes.length; paneIndex++) {
    const pane = layout.panes[paneIndex];
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
      let cursor = paneBounds.x + r.lead * unit;
      const cellY = rowIndex * rowPitch;
      for (const k of r.keys) {
        cursor = skipReserved(reserved[rowIndex], cursor);
        const cellW = keyWeight(k, layout.form, profile) * unit;
        const span = Math.min(keySpan(k), pane.rows.length - rowIndex);
        const cellH = rowPitch * span;
        const rect: KeyRect = {
          key: k,
          paneIndex: paneIndex,
          x: cursor + gap / 2,
          y: cellY + gap / 2,
          w: Math.max(0, cellW - gap),
          h: Math.max(0, cellH - gap),
          cellX: cursor,
          cellY: cellY,
          cellW: cellW,
          cellH: cellH
        };
        for (let below = rowIndex + 1; below < rowIndex + span; below++) {
          const taken: SpanReserve = { start: cursor, end: cursor + cellW };
          reserved[below].push(taken);
        }
        rects.push(rect);
        cursor += cellW;
      }
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
