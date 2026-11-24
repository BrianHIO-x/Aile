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
 * 宽度为 0（或负数）的键区放不下任何候选，不参与分配；两侧都不可用时整栏为空，
 * 候选不会被塞进看不见的键区里。
 */
export function allocateBar(widths: number[], leftWidth: number, rightWidth: number, gap: number): BarAllocation {
  const left: CandidateSlot[] = [];
  const right: CandidateSlot[] = [];
  const usableLeft = leftWidth > 0;
  const usableRight = rightWidth > 0;
  if (!usableLeft && !usableRight) {
    const empty: BarAllocation = { left: left, right: right };
    return empty;
  }
  let group = usableLeft ? 0 : 1;
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
      if (!usableRight) {
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

export interface GridCell {
  // 候选在当前筛选列表中的序号
  index: number;
  // 起点与宽度，按所在键区的宽度归一到 0～1
  start: number;
  width: number;
}

export interface GridRow {
  // 每个键区这一行里的候选，下标与调用方给出的键区顺序一致
  panes: GridCell[][];
}

// 一个键区里排满的一行按比例拉宽到整行，最后一行没排满，保持原来的宽度
function closePaneRow(spans: number[], indices: number[], columns: number, stretch: boolean): GridCell[] {
  let used = 0;
  for (const index of indices) {
    used += spans[index];
  }
  const scale = stretch && used > 0 ? columns / used : 1;
  const cells: GridCell[] = [];
  let cursor = 0;
  for (const index of indices) {
    const width = spans[index] * scale / columns;
    const cell: GridCell = { index: index, start: cursor, width: width };
    cells.push(cell);
    cursor += width;
  }
  return cells;
}

/**
 * 自由选词网格：候选按宽度换算成列数，从左手区的一行排到右手区的同一行，再换到下一行，整张网格上下滚动。
 * 排满的行把多出的空位按比例分给这一行的候选，每行的右端因此对齐。paneColumns 为 0 的键区不放候选。
 */
export function flowGrid(spans: number[], paneColumns: number[]): GridRow[] {
  const rows: GridRow[] = [];
  const usable: number[] = [];
  for (let i = 0; i < paneColumns.length; i++) {
    if (paneColumns[i] > 0) {
      usable.push(i);
    }
  }
  if (usable.length === 0 || spans.length === 0) {
    return rows;
  }
  const units: number[] = [];
  const newPanes = (): GridCell[][] => paneColumns.map((): GridCell[] => []);
  let panes = newPanes();
  let pos = 0;
  let used = 0;
  let indices: number[] = [];
  for (let i = 0; i < spans.length; i++) {
    let columns = paneColumns[usable[pos]];
    units.push(Math.max(1, Math.min(Math.ceil(spans[i]), columns)));
    if (used + units[i] > columns && indices.length > 0) {
      panes[usable[pos]] = closePaneRow(units, indices, columns, true);
      indices = [];
      used = 0;
      pos++;
      if (pos >= usable.length) {
        const row: GridRow = { panes: panes };
        rows.push(row);
        panes = newPanes();
        pos = 0;
      }
      columns = paneColumns[usable[pos]];
      units[i] = Math.max(1, Math.min(Math.ceil(spans[i]), columns));
    }
    indices.push(i);
    used += units[i];
  }
  panes[usable[pos]] = closePaneRow(units, indices, paneColumns[usable[pos]], false);
  const last: GridRow = { panes: panes };
  rows.push(last);
  return rows;
}
