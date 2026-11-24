import { ImeController } from '../../ime/ImeController';
import { CandidateFilter, CandidateView, ImeState } from '../../ime/ImeState';
import { flowGrid, GridCell } from '../CandidateLayout';
import { KeyRect } from '../LayoutEngine';
import { anchorOf } from './CandidateBar';

// 候选文字两侧留白，相邻两条候选之间因此至少隔开两倍的留白
const CANDIDATE_PADDING_VP: number = 12;
// 排布的最小单位取按键宽的四分之一，词条宽度因此贴近文字本身
const SPAN_DIVISIONS: number = 4;
// 白色卡片与按键同样带一点阴影，圆角稍大，内容离卡片边缘留出一段距离
const CARD_RADIUS_VP: number = 12;
const CARD_PADDING_VP: number = 6;
// 行分隔线两端离卡片边缘的距离
const DIVIDER_INSET_VP: number = 14;
const DIVIDER_VP: number = 0.5;
// 同一行相邻候选之间的竖线占行高的比例
const SEPARATOR_RATIO: number = 0.36;
// 候选按下时的圆角底色相对行高上下各缩进的距离
const CELL_INSET_VP: number = 5;
const CELL_RADIUS_VP: number = 8;
// 两侧的灰色轨道与轨道里的白色胶囊，与顶部栏的分段标签同一套样式
const TRACK_PADDING_VP: number = 3;
const TRACK_RADIUS_VP: number = 12;

enum ControlId {
  RETYPE = 'retype',
  LETTERS = 'letters',
  DELETE = 'delete'
}

interface ColumnItem {
  id: ControlId;
  label: string;
  selected: boolean;
}

interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
}

// 一块候选卡片，以及卡片里排候选的横向范围与列数
interface PaneSlot {
  card: Box;
  x: number;
  w: number;
  columns: number;
}

// 网格单元格与渲染时捕获的候选对象；事件闭包只持有这一份快照
interface GridEntry {
  cell: GridCell;
  candidate: CandidateView;
}

interface GridRowView {
  panes: GridEntry[][];
}

const EMPTY_BOX: Box = { x: 0, y: 0, w: 0, h: 0 };

function findRect(rects: KeyRect[], id: string): KeyRect | undefined {
  for (const rect of rects) {
    if (rect.key.id === id) {
      return rect;
    }
  }
  return undefined;
}

/**
 * 平板自由选词界面，相当于手机输入法展开候选后的“更多候选”，沿用键盘本身的视觉：候选排在与字母键同色的白色卡片里。
 * 左手区外侧一列是可滚动的可选拼音音节列表（全部/词语/单字移至展开后的顶部栏），右手区外侧一列是重输、原文与删除。
 * 两列是成对的灰色轨道，宽度都等于最外侧一列按键，选中项或按下项浮起白色胶囊。收起这个界面用右上角的圆形按钮。
 * 每一行先排左手区再排右手区，两块卡片一起上下滚动。排满的行右端对齐，行与行之间画分隔线，同一行的候选之间画短竖线。
 */
@ComponentV2
export struct FreeSelectPanel {
  @Local state: ImeState = ImeState.get();
  // 候选或筛选变化时加一，网格整行重建并滚回顶部
  @Local generation: number = 0;
  // 当前键盘形态下字母页的按键矩形，由键盘页面按同一档案计算后传入
  @Param letterRects: KeyRect[] = [];
  @Param split: boolean = true;
  @Param areaWidth: number = 0;
  @Param areaHeight: number = 0;
  @Param keyGap: number = 6;
  private controller: ImeController = ImeController.get();
  private scroller: Scroller = new Scroller();
  private pinyinScroller: Scroller = new Scroller();

  @Monitor('state.candidatesAll', 'state.candidatesWords', 'state.candidatesChars', 'state.candidateFilter')
  onCandidatesChanged(monitor: IMonitor): void {
    this.generation++;
    this.scroller.scrollToIndex(0);
  }

  @Monitor('state.pinyinOptions')
  onPinyinOptionsChanged(monitor: IMonitor): void {
    this.pinyinScroller.scrollToIndex(0);
  }

  // 同一键区内最左与最右的单元格边界，右手区里向中间伸出的 G、V 与空格都算在内
  private paneEdges(origin: KeyRect): number[] {
    let left = origin.cellX;
    let right = origin.cellX + origin.cellW;
    for (const rect of this.letterRects) {
      if (rect.paneIndex === origin.paneIndex) {
        left = Math.min(left, rect.cellX);
        right = Math.max(right, rect.cellX + rect.cellW);
      }
    }
    return [left, right];
  }

  // 字母区的纵向范围：从 Q 一排的顶端到最下排的底端，与按键一样上下各让出半个键间距
  @Computed
  get bounds(): Box {
    const top = findRect(this.letterRects, 'letter_q');
    if (top === undefined) {
      return EMPTY_BOX;
    }
    let bottom = top.cellY + top.cellH;
    for (const rect of this.letterRects) {
      bottom = Math.max(bottom, rect.cellY + rect.cellH);
    }
    const gap = this.keyGap / 2;
    const box: Box = { x: 0, y: top.cellY + gap, w: this.areaWidth, h: Math.max(0, bottom - top.cellY - this.keyGap) };
    return box;
  }

  // 卡片高度正好放下与按键排数相同的几行候选
  private rowHeight(): number {
    const top = findRect(this.letterRects, 'letter_q');
    const pitch = top !== undefined ? top.cellH : 50;
    const rows = Math.max(1, Math.round((this.bounds.h + this.keyGap) / pitch));
    return this.bounds.h / rows;
  }

  private columnBox(cellX: number, cellW: number): Box {
    const bounds = this.bounds;
    const box: Box = { x: cellX + this.keyGap / 2, y: bounds.y, w: Math.max(0, cellW - this.keyGap), h: bounds.h };
    return box;
  }

  // 左列占 Q 键所在键区最左侧一列，宽度等于 Q 键
  @Computed
  get filterColumn(): Box {
    const q = findRect(this.letterRects, 'letter_q');
    return q === undefined ? EMPTY_BOX : this.columnBox(this.paneEdges(q)[0], q.cellW);
  }

  // 右列占 P 键所在键区最右侧一列，宽度等于 P 键
  @Computed
  get actionColumn(): Box {
    const p = findRect(this.letterRects, 'letter_p');
    return p === undefined ? EMPTY_BOX : this.columnBox(this.paneEdges(p)[1] - p.cellW, p.cellW);
  }

  // 候选卡片：分离布局是两个键区各自让出外侧一列，常规布局是两列之间的整段
  @Computed
  get panes(): PaneSlot[] {
    const result: PaneSlot[] = [];
    const q = findRect(this.letterRects, 'letter_q');
    const p = findRect(this.letterRects, 'letter_p');
    if (q === undefined || p === undefined) {
      return result;
    }
    const unit = q.cellW / SPAN_DIVISIONS;
    const ranges: number[][] = [];
    const leftEdges = this.paneEdges(q);
    const rightEdges = this.paneEdges(p);
    if (this.split && q.paneIndex !== p.paneIndex) {
      ranges.push([leftEdges[0] + q.cellW, leftEdges[1]]);
      ranges.push([rightEdges[0], rightEdges[1] - p.cellW]);
    } else {
      ranges.push([leftEdges[0] + q.cellW, rightEdges[1] - p.cellW]);
    }
    const bounds = this.bounds;
    for (const range of ranges) {
      const card: Box = {
        x: range[0] + this.keyGap / 2,
        y: bounds.y,
        w: Math.max(0, range[1] - range[0] - this.keyGap),
        h: bounds.h
      };
      const w = Math.max(0, card.w - CARD_PADDING_VP * 2);
      const slot: PaneSlot = { card: card, x: card.x + CARD_PADDING_VP, w: w, columns: Math.floor(w / unit + 0.01) };
      result.push(slot);
    }
    return result;
  }

  // 三个筛选各自消费候选快照里已经排好的顺序，不在这里过滤普通栏，也不重新比较
  @Computed
  get filtered(): CandidateView[] {
    const filter = this.state.candidateFilter;
    if (filter === CandidateFilter.WORDS) {
      return this.state.candidatesWords;
    }
    if (filter === CandidateFilter.CHARS) {
      return this.state.candidatesChars;
    }
    return this.state.candidatesAll;
  }

  @Computed
  get rows(): GridRowView[] {
    const panes = this.panes;
    if (panes.length === 0) {
      return [];
    }
    // 左右键区键宽可能不同，按较窄的列宽换算占用列数，保证不会越界
    let unit = Number.MAX_VALUE;
    for (const pane of panes) {
      if (pane.columns > 0) {
        unit = Math.min(unit, pane.w / pane.columns);
      }
    }
    if (unit === Number.MAX_VALUE) {
      return [];
    }
    const filtered = this.filtered;
    const fontSize = this.candidateFontSize();
    const ui = this.getUIContext();
    const spans: number[] = filtered.map((view: CandidateView) => {
      const width = ui.px2vp(ui.getMeasureUtils().measureText({ textContent: view.text, fontSize: fontSize }));
      return (width + CANDIDATE_PADDING_VP * 2) / unit;
    });
    const layout = flowGrid(spans, panes.map((pane: PaneSlot) => pane.columns));
    const rows: GridRowView[] = [];
    for (const row of layout) {
      const rowPanes: GridEntry[][] = [];
      for (const cells of row.panes) {
        const entries: GridEntry[] = [];
        for (const cell of cells) {
          if (cell.index >= 0 && cell.index < filtered.length) {
            const entry: GridEntry = { cell: cell, candidate: filtered[cell.index] };
            entries.push(entry);
          }
        }
        rowPanes.push(entries);
      }
      const view: GridRowView = { panes: rowPanes };
      rows.push(view);
    }
    return rows;
  }

  private candidateFontSize(): number {
    return Math.max(16, Math.min(this.rowHeight() * 0.32, 21));
  }

  // 键里带上候选版本与标识，候选刷新后整行重建，点按不会落到旧候选上
  private rowKey(row: GridRowView, rowIndex: number): string {
    let key = `${this.generation}_${rowIndex}`;
    for (const entries of row.panes) {
      key += '|';
      for (const entry of entries) {
        key += `${entry.cell.index}:${entry.candidate.revision}:${entry.candidate.id}:${entry.cell.width.toFixed(4)},`;
      }
    }
    return key;
  }

  // ---------- 两侧功能列 ----------

  private actionItems(): ColumnItem[] {
    const retype: ColumnItem = { id: ControlId.RETYPE, label: '重输', selected: false };
    const letters: ColumnItem = { id: ControlId.LETTERS, label: '原文', selected: false };
    const del: ColumnItem = { id: ControlId.DELETE, label: '删除', selected: false };
    return [retype, letters, del];
  }

  private runControl(id: ControlId): void {
    switch (id) {
      case ControlId.RETYPE:
        this.controller.retypeInFreeSelect();
        break;
      case ControlId.LETTERS:
        this.controller.commitLettersInFreeSelect();
        break;
      case ControlId.DELETE:
        this.controller.deleteInFreeSelect();
        break;
      default:
        break;
    }
  }

  private pinyinItemHeight(): number {
    return Math.max(36, Math.min(this.rowHeight() * 0.85, 44));
  }

  private pinyinTextSize(): number {
    return Math.max(13, Math.min(this.rowHeight() * 0.26, 15));
  }

  private columnTextSize(): number {
    return Math.max(13, Math.min(this.rowHeight() * 0.24, 15));
  }

  private itemAccessibility(item: ColumnItem): string {
    switch (item.id) {
      case ControlId.RETYPE:
        return '重输，清空拼音';
      case ControlId.LETTERS:
        return '原文，按下的字母原样上屏';
      case ControlId.DELETE:
        return '删除拼音';
      default:
        return item.label;
    }
  }

  // ---------- 外观 ----------

  @Styles
  flatNormal() {
    .backgroundColor(Color.Transparent)
  }

  @Styles
  flatPressed() {
    .backgroundColor($r('app.color.key_pressed_background'))
  }

  // 轨道里的按钮平时透明，按下时浮起与筛选选中项同样的白色胶囊
  @Styles
  pillNormal() {
    .backgroundColor(Color.Transparent)
  }

  @Styles
  pillPressed() {
    .backgroundColor($r('app.color.key_background'))
  }

  @Styles
  pinyinNormal() {
    .opacity(1)
  }

  @Styles
  pinyinPressed() {
    .opacity(0.6)
  }

  @Builder
  pinyinItem(syllable: string) {
    Text(syllable)
      .fontSize(this.pinyinTextSize())
      .maxFontScale(1.2)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .textAlign(TextAlign.Center)
      .fontWeight(this.state.selectedPinyin === syllable ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.state.selectedPinyin === syllable ? $r('app.color.kb_accent') : $r('app.color.key_text'))
      .backgroundColor(this.state.selectedPinyin === syllable ? $r('app.color.key_background') : Color.Transparent)
      .shadow(this.state.selectedPinyin === syllable ? { radius: 2, color: $r('app.color.key_shadow'), offsetY: 1 } :
        { radius: 0, color: Color.Transparent })
      .borderRadius(TRACK_RADIUS_VP - TRACK_PADDING_VP)
      .width('100%')
      .height(this.pinyinItemHeight())
      .stateStyles({ normal: this.pinyinNormal, pressed: this.pinyinPressed })
      .animation({ duration: 140, curve: Curve.FastOutSlowIn })
      .accessibilityText(this.state.selectedPinyin === syllable ? `取消筛选拼音 ${syllable}` :
        `按拼音 ${syllable} 筛选`)
      .accessibilitySelected(this.state.selectedPinyin === syllable)
      .onClick(() => this.controller.togglePinyinFilter(syllable))
  }

  // 左侧拼音列表：灰色轨道里的可滚动首音节项，点选时浮起白色胶囊，再点取消筛选
  @Builder
  pinyinColumnView() {
    Column() {
      List({ scroller: this.pinyinScroller, space: 2 }) {
        ForEach(this.state.pinyinOptions, (syllable: string) => {
          ListItem() {
            this.pinyinItem(syllable)
          }
        }, (syllable: string) => syllable)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .padding(TRACK_PADDING_VP)
    .position({ x: this.filterColumn.x, y: this.filterColumn.y })
    .width(this.filterColumn.w)
    .height(this.filterColumn.h)
    .borderRadius(TRACK_RADIUS_VP)
    .backgroundColor($r('app.color.kb_segment_track'))
  }

  @Builder
  actionContent(item: ColumnItem) {
    if (item.id === ControlId.DELETE) {
      SymbolGlyph($r('sys.symbol.delete_left'))
        .fontSize(this.columnTextSize() + 5)
        .fontColor([$r('app.color.key_text')])
    } else {
      Text(item.label)
        .fontSize(this.columnTextSize())
        .maxFontScale(1.2)
        .fontColor($r('app.color.key_text'))
    }
  }

  // 重输、原文与删除：与左侧筛选成对的灰色轨道，三项等高，删除落在右下角，离拇指最近
  @Builder
  actionColumnView() {
    Column() {
      ForEach(this.actionItems(), (item: ColumnItem) => {
        Stack() {
          this.actionContent(item)
        }
        .width('100%')
        .layoutWeight(1)
        .borderRadius(TRACK_RADIUS_VP - TRACK_PADDING_VP)
        .stateStyles({ normal: this.pillNormal, pressed: this.pillPressed })
        .accessibilityText(this.itemAccessibility(item))
        .onClick(() => this.runControl(item.id))
      }, (item: ColumnItem) => item.id)
    }
    .padding(TRACK_PADDING_VP)
    .position({ x: this.actionColumn.x, y: this.actionColumn.y })
    .width(this.actionColumn.w)
    .height(this.actionColumn.h)
    .borderRadius(TRACK_RADIUS_VP)
    .backgroundColor($r('app.color.kb_segment_track'))
  }

  // ---------- 候选网格 ----------

  @Builder
  cards() {
    ForEach(this.panes, (pane: PaneSlot) => {
      Column()
        .position({ x: pane.card.x, y: pane.card.y })
        .width(pane.card.w)
        .height(pane.card.h)
        .borderRadius(CARD_RADIUS_VP)
        .backgroundColor($r('app.color.key_background'))
        .shadow({ radius: 1, color: $r('app.color.key_shadow'), offsetY: 1 })
        .hitTestBehavior(HitTestMode.None)
    }, (pane: PaneSlot) => `card_${pane.card.x.toFixed(1)}_${pane.card.w.toFixed(1)}_${pane.card.h.toFixed(1)}`)
  }

  @Builder
  gridCell(entry: GridEntry, pane: number) {
    if (pane < this.panes.length) {
      Text(entry.candidate.text)
        .fontSize(this.candidateFontSize())
        .maxFontScale(1.2)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .fontColor(entry.cell.index === 0 ? $r('app.color.kb_accent') : $r('app.color.key_text'))
        .fontWeight(entry.cell.index === 0 ? FontWeight.Medium : FontWeight.Normal)
        .position({ x: this.panes[pane].x + entry.cell.start * this.panes[pane].w, y: CELL_INSET_VP })
        .width(Math.max(0, entry.cell.width * this.panes[pane].w))
        .height(Math.max(0, this.rowHeight() - CELL_INSET_VP * 2))
        .borderRadius(CELL_RADIUS_VP)
        .stateStyles({ normal: this.flatNormal, pressed: this.flatPressed })
        .accessibilityText(`候选 ${entry.cell.index + 1}，${entry.candidate.text}`)
        .onClick(() => this.controller.selectCandidate(entry.candidate))
        .gesture(LongPressGesture({ repeat: false })
          .onAction((event: GestureEvent) => this.controller.openCandidateMenu(entry.candidate, anchorOf(event))))
      // 同一行里前一个候选的右边界画一条短竖线
      if (entry.cell.start > 0) {
        Column()
          .width(DIVIDER_VP)
          .height(this.rowHeight() * SEPARATOR_RATIO)
          .backgroundColor($r('app.color.kb_divider'))
          .position({
            x: this.panes[pane].x + entry.cell.start * this.panes[pane].w,
            y: this.rowHeight() * (1 - SEPARATOR_RATIO) / 2
          })
          .hitTestBehavior(HitTestMode.None)
      }
    }
  }

  // 分隔线画在每一行的顶端，第一行不画。卡片正好放下整数行，下一行顶端的线落在卡片外面，不会贴着卡片底边露出来
  @Builder
  gridRow(row: GridRowView, rowIndex: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(row.panes, (entries: GridEntry[], pane: number) => {
        if (rowIndex > 0 && pane < this.panes.length) {
          Divider()
            .strokeWidth(DIVIDER_VP)
            .color($r('app.color.kb_divider'))
            .width(Math.max(0, this.panes[pane].card.w - DIVIDER_INSET_VP * 2))
            .position({ x: this.panes[pane].card.x + DIVIDER_INSET_VP, y: 0 })
        }
        ForEach(entries, (entry: GridEntry) => {
          this.gridCell(entry, pane)
        }, (entry: GridEntry) => `${pane}_${entry.cell.index}_${entry.candidate.revision}_${entry.candidate.id}`)
      }, (entries: GridEntry[], pane: number) => `${pane}`)
    }
    .width(this.areaWidth)
    .height(this.rowHeight())
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.cards()

      List({ scroller: this.scroller }) {
        ForEach(this.rows, (row: GridRowView, rowIndex: number) => {
          ListItem() {
            this.gridRow(row, rowIndex)
          }
        }, (row: GridRowView, rowIndex: number) => this.rowKey(row, rowIndex))
      }
      .position({ x: this.bounds.x, y: this.bounds.y })
      .width(this.bounds.w)
      .height(this.bounds.h)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(2)

      this.pinyinColumnView()
      this.actionColumnView()
    }
    .width(this.areaWidth)
    .height(this.areaHeight)
    .backgroundColor($r('app.color.kb_background'))
  }
}