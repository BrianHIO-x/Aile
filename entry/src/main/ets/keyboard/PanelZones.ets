// 表情与剪贴板面板的内容区域。分离布局下内容分成左右两块，与两侧键区的键帽边缘对齐；
// 常规布局只有一块整宽区域。

export const PANEL_EDGE_VP: number = 12;

export interface PanelZone {
  x: number;
  width: number;
}

/**
 * 各块区域使用相同列数，按最窄的一块计算。每列不窄于 minCellWidth，列间距为 gap。
 */
export function zoneColumns(zones: PanelZone[], minCellWidth: number, gap: number, minColumns: number): number {
  let narrowest = Number.MAX_VALUE;
  for (const zone of zones) {
    narrowest = Math.min(narrowest, zone.width);
  }
  if (zones.length === 0) {
    return minColumns;
  }
  return Math.max(minColumns, Math.floor((narrowest + gap) / (minCellWidth + gap)));
}

/**
 * 按行切分序号，返回 行 → 区域 → 序号。每行先排满第一块区域，再排下一块。
 */
export function zoneRows(count: number, columns: number, zoneCount: number): number[][][] {
  const rows: number[][][] = [];
  if (columns <= 0 || zoneCount <= 0) {
    return rows;
  }
  const perRow = columns * zoneCount;
  for (let start = 0; start < count; start += perRow) {
    const row: number[][] = [];
    for (let zone = 0; zone < zoneCount; zone++) {
      const indices: number[] = [];
      const from = start + zone * columns;
      for (let i = from; i < Math.min(from + columns, count); i++) {
        indices.push(i);
      }
      row.push(indices);
    }
    rows.push(row);
  }
  return rows;
}
