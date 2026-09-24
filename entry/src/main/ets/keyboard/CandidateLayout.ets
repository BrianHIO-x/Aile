export interface CandidateSlot {
  index: number;
  // 相对所在分组起点的横坐标，单位 vp
  x: number;
  width: number;
}

export interface BarAllocation {
  left: CandidateSlot[];
  right: CandidateSlot[];
}

/**
 * 候选栏按拇指分区排布：先填左手区，放不下的下一个候选起转入右手区，保持候选顺序。
 * rightWidth 为 0 时表示常规布局，只使用一个分组。
 */
export function allocateBar(widths: number[], leftWidth: number, rightWidth: number, gap: number): BarAllocation {
  const left: CandidateSlot[] = [];
  const right: CandidateSlot[] = [];
  let group = 0;
  let cursor = 0;
  for (let i = 0; i < widths.length; i++) {
    const width = widths[i];
    if (group === 0) {
      if (cursor + width <= leftWidth || left.length === 0) {
        const slot: CandidateSlot = { index: i, x: cursor, width: Math.min(width, leftWidth) };
        left.push(slot);
        cursor += slot.width + gap;
        continue;
      }
      if (rightWidth <= 0) {
        break;
      }
      group = 1;
      cursor = 0;
    }
    if (cursor + width <= rightWidth || right.length === 0) {
      const slot: CandidateSlot = { index: i, x: cursor, width: Math.min(width, rightWidth) };
      right.push(slot);
      cursor += slot.width + gap;
      continue;
    }
    break;
  }
  const allocation: BarAllocation = { left: left, right: right };
  return allocation;
}

export interface UnitCell {
  // 候选在当前筛选列表中的序号
  index: number;
  // 行槽序号，对应调用方给出的行顺序
  slot: number;
  // 起始列与占用列数，列宽等于该行所在键区的字母键宽
  col: number;
  span: number;
}

/**
 * 自由选词分页：候选按键位网格排布，单字占一个字母键位，词语按宽度占多个键位。
 * 按行槽顺序填充，放不下换到下一行槽，所有行槽用完后开新页。
 */
export function paginateUnits(spans: number[], rowColumns: number[]): UnitCell[][] {
  const pages: UnitCell[][] = [];
  const usable: number[] = [];
  for (let i = 0; i < rowColumns.length; i++) {
    if (rowColumns[i] > 0) {
      usable.push(i);
    }
  }
  if (usable.length === 0) {
    return pages;
  }
  let page: UnitCell[] = [];
  let slotPos = 0;
  let col = 0;
  for (let i = 0; i < spans.length; i++) {
    let columns = rowColumns[usable[slotPos]];
    let span = Math.max(1, Math.min(Math.ceil(spans[i]), columns));
    if (col + span > columns) {
      slotPos++;
      col = 0;
      if (slotPos >= usable.length) {
        pages.push(page);
        page = [];
        slotPos = 0;
      }
      columns = rowColumns[usable[slotPos]];
      span = Math.max(1, Math.min(Math.ceil(spans[i]), columns));
    }
    const cell: UnitCell = { index: i, slot: usable[slotPos], col: col, span: span };
    page.push(cell);
    col += span;
  }
  if (page.length > 0) {
    pages.push(page);
  }
  return pages;
}
