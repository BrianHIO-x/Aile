import { ImeController } from '../../ime/ImeController';
import { ImeState } from '../../ime/ImeState';
import { PanelZone } from '../PanelZones';
import { isWhitespaceToken, isWideToken, pickTokenLabel } from '../PickText';

// 滑动选字只需要看清并划过，格子比按键小得多，一屏能放下更多文字
const PICK_CELL_VP: number = 28;
const PICK_GAP_VP: number = 4;
const PICK_TOP_VP: number = 10;
const PICK_FONT_SIZE: number = 14;
const PICK_RADIUS_VP: number = 6;
const WORD_PADDING_VP: number = 6;
// 选择时手指进入上下边缘区域后自动滚动
const EDGE_SCROLL_VP: number = 28;
const EDGE_SCROLL_STEP_VP: number = 8;
const EDGE_SCROLL_MS: number = 16;

interface PickCell {
  index: number;
  x: number;
  w: number;
}

interface PickRow {
  key: string;
  top: number;
  cells: PickCell[];
}

enum DragMode {
  NONE = 0,
  SELECT = 1,
  SCROLL = 2
}

/**
 * 滑动选字：原文切分后逐格排列，分离布局下每行先排左手区再排右手区。
 * 手指从格子上开始滑动时，起点到当前位置之间的格子统一设为起点格子相反的状态；从空白处开始滑动时上下滚动。
 * 行高固定，只构建可见范围内的行。
 */
@ComponentV2
export struct PickPanel {
  @Local state: ImeState = ImeState.get();
  @Param areaWidth: number = 0;
  @Param areaHeight: number = 0;
  @Param bottomInset: number = 0;
  @Param zones: PanelZone[] = [];
  @Local scrollY: number = 0;
  private controller: ImeController = ImeController.get();
  private dragId: number = -1;
  private dragMode: DragMode = DragMode.NONE;
  private anchor: number = -1;
  private target: boolean = true;
  private base: boolean[] = [];
  private rangeLow: number = -1;
  private rangeHigh: number = -1;
  private lastX: number = 0;
  private lastY: number = 0;
  private edgeTimer: number = -1;

  aboutToDisappear(): void {
    this.stopEdgeScroll();
  }

  private tokenText(index: number): string {
    return index >= 0 && index < this.state.pickTokens.length ? this.state.pickTokens[index] : '';
  }

  private isSelected(index: number): boolean {
    return index >= 0 && index < this.state.pickSelected.length && this.state.pickSelected[index];
  }

  private tokenWidth(token: string): number {
    if (!isWideToken(token)) {
      return PICK_CELL_VP;
    }
    const ui = this.getUIContext();
    const textWidth = ui.px2vp(ui.getMeasureUtils().measureText({
      textContent: pickTokenLabel(token),
      fontSize: PICK_FONT_SIZE
    }));
    return Math.max(PICK_CELL_VP, textWidth + WORD_PADDING_VP * 2);
  }

  @Computed
  get rows(): PickRow[] {
    const tokens = this.state.pickTokens;
    const rows: PickRow[] = [];
    if (this.zones.length === 0) {
      return rows;
    }
    const geometry = this.zones.map((zone: PanelZone) => `${zone.x.toFixed(1)}_${zone.width.toFixed(1)}`).join('_');
    let next = 0;
    let top = PICK_TOP_VP;
    while (next < tokens.length) {
      const cells: PickCell[] = [];
      for (const zone of this.zones) {
        let x = zone.x;
        while (next < tokens.length) {
          const w = Math.min(zone.width, this.tokenWidth(tokens[next]));
          // 每块区域至少放下一格，超宽的片段截断为区域宽度
          if (x > zone.x && x + w > zone.x + zone.width + 0.5) {
            break;
          }
          cells.push({ index: next, x: x, w: w });
          x += w + PICK_GAP_VP;
          next++;
        }
      }
      rows.push({ key: `${geometry}_${top}_${cells[0].index}_${cells.length}`, top: top, cells: cells });
      top += PICK_CELL_VP + PICK_GAP_VP;
    }
    return rows;
  }

  private contentHeight(): number {
    const rows = this.rows;
    return rows.length === 0 ? 0 : rows[rows.length - 1].top + PICK_CELL_VP;
  }

  private maxScroll(): number {
    return Math.max(0, this.contentHeight() + PICK_TOP_VP + this.bottomInset - this.areaHeight);
  }

  private visibleRows(): PickRow[] {
    const low = this.scrollY - PICK_CELL_VP;
    const high = this.scrollY + this.areaHeight;
    return this.rows.filter((row: PickRow) => row.top >= low && row.top <= high);
  }

  // ---------- 命中 ----------

  private rowAt(contentY: number): number {
    return Math.floor((contentY - PICK_TOP_VP + PICK_GAP_VP / 2) / (PICK_CELL_VP + PICK_GAP_VP));
  }

  // 按下位置必须落在格子上，才开始选择
  private exactTokenAt(x: number, contentY: number): number {
    const rows = this.rows;
    const r = this.rowAt(contentY);
    if (r < 0 || r >= rows.length) {
      return -1;
    }
    for (const cell of rows[r].cells) {
      if (x >= cell.x - PICK_GAP_VP / 2 && x <= cell.x + cell.w + PICK_GAP_VP / 2) {
        return cell.index;
      }
    }
    return -1;
  }

  // 滑动中取最近的格子：行号限制在内容范围内，落在空白处时取阅读顺序上前一个格子
  private nearestTokenAt(x: number, contentY: number): number {
    const rows = this.rows;
    if (rows.length === 0) {
      return -1;
    }
    const r = Math.max(0, Math.min(rows.length - 1, this.rowAt(contentY)));
    const cells = rows[r].cells;
    let found = cells[0].index;
    for (const cell of cells) {
      if (cell.x - PICK_GAP_VP / 2 <= x) {
        found = cell.index;
      }
    }
    return found;
  }

  // ---------- 选择 ----------

  private applyRange(index: number): void {
    if (index < 0 || this.anchor < 0) {
      return;
    }
    const low = Math.min(this.anchor, index);
    const high = Math.max(this.anchor, index);
    if (low === this.rangeLow && high === this.rangeHigh) {
      return;
    }
    this.rangeLow = low;
    this.rangeHigh = high;
    const next = this.base.slice();
    for (let i = low; i <= high && i < next.length; i++) {
      next[i] = this.target;
    }
    this.controller.setPickSelection(next);
  }

  private scrollBy(delta: number): boolean {
    const next = Math.max(0, Math.min(this.maxScroll(), this.scrollY + delta));
    if (next === this.scrollY) {
      return false;
    }
    this.scrollY = next;
    return true;
  }

  private updateEdgeScroll(): void {
    const nearTop = this.lastY < EDGE_SCROLL_VP;
    const nearBottom = this.lastY > this.areaHeight - this.bottomInset - EDGE_SCROLL_VP;
    if (!nearTop && !nearBottom) {
      this.stopEdgeScroll();
      return;
    }
    if (this.edgeTimer !== -1) {
      return;
    }
    this.edgeTimer = setInterval(() => {
      const top = this.lastY < EDGE_SCROLL_VP;
      const bottom = this.lastY > this.areaHeight - this.bottomInset - EDGE_SCROLL_VP;
      if (this.dragMode !== DragMode.SELECT || (!top && !bottom)) {
        this.stopEdgeScroll();
        return;
      }
      if (this.scrollBy(top ? -EDGE_SCROLL_STEP_VP : EDGE_SCROLL_STEP_VP)) {
        this.applyRange(this.nearestTokenAt(this.lastX, this.lastY + this.scrollY));
      }
    }, EDGE_SCROLL_MS);
  }

  private stopEdgeScroll(): void {
    if (this.edgeTimer !== -1) {
      clearInterval(this.edgeTimer);
      this.edgeTimer = -1;
    }
  }

  private endDrag(): void {
    this.stopEdgeScroll();
    this.dragId = -1;
    this.dragMode = DragMode.NONE;
    this.anchor = -1;
    this.base = [];
    this.rangeLow = -1;
    this.rangeHigh = -1;
  }

  private onPickTouch(event: TouchEvent): void {
    for (const touch of event.changedTouches) {
      if (touch.type === TouchType.Down) {
        if (this.dragId !== -1) {
          continue;
        }
        this.dragId = touch.id;
        this.lastX = touch.x;
        this.lastY = touch.y;
        const index = this.exactTokenAt(touch.x, touch.y + this.scrollY);
        if (index >= 0) {
          this.dragMode = DragMode.SELECT;
          this.anchor = index;
          this.base = this.state.pickSelected.slice();
          this.target = !this.base[index];
          this.applyRange(index);
        } else {
          this.dragMode = DragMode.SCROLL;
        }
      } else if (touch.id !== this.dragId) {
        continue;
      } else if (touch.type === TouchType.Move) {
        if (this.dragMode === DragMode.SELECT) {
          this.lastX = touch.x;
          this.lastY = touch.y;
          this.applyRange(this.nearestTokenAt(touch.x, touch.y + this.scrollY));
          this.updateEdgeScroll();
        } else if (this.dragMode === DragMode.SCROLL) {
          this.scrollBy(this.lastY - touch.y);
          this.lastX = touch.x;
          this.lastY = touch.y;
        }
      } else if (touch.type === TouchType.Up || touch.type === TouchType.Cancel) {
        this.endDrag();
      }
    }
  }

  // ---------- 界面 ----------

  @Builder
  pickCell(cell: PickCell) {
    Text(pickTokenLabel(this.tokenText(cell.index)))
      .fontSize(PICK_FONT_SIZE)
      .maxFontScale(1.2)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .textAlign(TextAlign.Center)
      .fontColor(this.isSelected(cell.index) ? $r('app.color.kb_accent_text') :
        (isWhitespaceToken(this.tokenText(cell.index)) ? $r('app.color.key_hint_text') :
        $r('app.color.key_text')))
      .backgroundColor(this.isSelected(cell.index) ? $r('app.color.kb_accent') :
        $r('app.color.key_background'))
      .borderRadius(PICK_RADIUS_VP)
      .width(cell.w)
      .height(PICK_CELL_VP)
      .position({ x: cell.x, y: 0 })
      .accessibilityText(this.tokenText(cell.index))
  }

  @Builder
  pickRow(row: PickRow) {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(row.cells, (cell: PickCell) => {
        this.pickCell(cell)
      }, (cell: PickCell) => `${cell.index}_${cell.x.toFixed(1)}_${cell.w.toFixed(1)}`)
    }
    .width('100%')
    .height(PICK_CELL_VP)
    .position({ x: 0, y: row.top - this.scrollY })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(this.visibleRows(), (row: PickRow) => {
        this.pickRow(row)
      }, (row: PickRow) => row.key)
    }
    .width(this.areaWidth)
    .height(this.areaHeight)
    .clip(true)
    .backgroundColor($r('app.color.kb_background'))
    .onTouch((event: TouchEvent) => this.onPickTouch(event))
  }
}
