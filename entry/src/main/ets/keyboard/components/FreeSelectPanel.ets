import { ImeController } from '../../ime/ImeController';
import { CandidateFilter, CandidateView, ImeState } from '../../ime/ImeState';
import { paginateUnits, UnitCell } from '../CandidateLayout';
import { KeyRect } from '../LayoutEngine';
import { slideInTransition } from '../Motion';

// 候选文字两侧留白，相邻两条候选之间因此至少隔开两倍的留白
const CANDIDATE_PADDING_VP: number = 12;
// 排布的最小单位取按键宽的四分之一，词条宽度因此贴近文字本身
const SPAN_DIVISIONS: number = 4;
const CELL_RADIUS_VP: number = 10;
const CONTROL_RADIUS_VP: number = 12;
// 分段控件里选中胶囊相对整条轨道的内缩
const SEGMENT_INSET_VP: number = 4;
const DIVIDER_HEIGHT_VP: number = 0.5;
// 常规布局下翻页控件中间留给页码的宽度
const COUNTER_WIDTH_VP: number = 72;

enum ControlId {
  ALL = 'all',
  WORDS = 'words',
  CHARS = 'chars',
  PREV = 'prev',
  NEXT = 'next',
  BACK = 'back',
  DELETE = 'delete'
}

interface ControlKey {
  id: ControlId;
  label: string;
  x: number;
  y: number;
  w: number;
  h: number;
  selected: boolean;
  enabled: boolean;
}

interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
}

interface RowSlot {
  originX: number;
  unit: number;
  columns: number;
  paneW: number;
  y: number;
  h: number;
  // 该键区里的最后一行不画分隔线
  last: boolean;
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
 * 平板自由选词界面。候选按键位网格排布，外观是平铺的文字加行分隔线，按下时才出现圆角底色。
 * 最下排沿用键盘按键的原位置：筛选合成一条分段控件，翻页、返回与删除各自落在一块浅色轨道上。
 */
@ComponentV2
export struct FreeSelectPanel {
  @Local state: ImeState = ImeState.get();
  @Local pageIndex: number = 0;
  // 当前键盘形态下字母页的按键矩形，由键盘页面按同一档案计算后传入
  @Param letterRects: KeyRect[] = [];
  @Param split: boolean = true;
  @Param areaWidth: number = 0;
  @Param areaHeight: number = 0;
  @Param keyGap: number = 6;
  private controller: ImeController = ImeController.get();
  // 翻页时新一页候选的滑入方向，筛选或候选变化时只淡入
  private pageDirection: number = 0;

  @Monitor('state.candidates', 'state.candidateFilter')
  onCandidatesChanged(monitor: IMonitor): void {
    this.pageDirection = 0;
    this.pageIndex = 0;
  }

  @Computed
  get slots(): RowSlot[] {
    const result: RowSlot[] = [];
    const rowIds = ['letter_q', 'letter_a', 'letter_z'];
    const origins = this.split ? ['letter_q', 'letter_y'] : ['letter_q'];
    for (const originId of origins) {
      const origin = findRect(this.letterRects, originId);
      if (origin === undefined) {
        continue;
      }
      const paneX = this.paneLeft(origin);
      const paneWidth = this.paneRight(origin) - paneX;
      const unit = origin.cellW / SPAN_DIVISIONS;
      const columns = Math.max(1, Math.floor(paneWidth / unit + 0.01));
      for (let i = 0; i < rowIds.length; i++) {
        const rowRect = findRect(this.letterRects, rowIds[i]);
        if (rowRect === undefined) {
          continue;
        }
        const slot: RowSlot = {
          originX: paneX,
          unit: unit,
          columns: columns,
          paneW: paneWidth,
          y: rowRect.cellY,
          h: rowRect.cellH,
          last: i === rowIds.length - 1
        };
        result.push(slot);
      }
    }
    return result;
  }

  // 键区左边界取同一键区内最左侧的单元格，右手区里向中间伸出的 G、V 与空格都算在内
  private paneLeft(origin: KeyRect): number {
    let left = origin.cellX;
    for (const rect of this.letterRects) {
      if (rect.paneIndex === origin.paneIndex) {
        left = Math.min(left, rect.cellX);
      }
    }
    return left;
  }

  // 键区右边界取同一键区内最右侧的单元格
  private paneRight(origin: KeyRect): number {
    let right = origin.cellX + origin.cellW;
    for (const rect of this.letterRects) {
      if (rect.paneIndex === origin.paneIndex) {
        right = Math.max(right, rect.cellX + rect.cellW);
      }
    }
    return right;
  }

  @Computed
  get filtered(): CandidateView[] {
    const filter = this.state.candidateFilter;
    return this.state.candidates.filter((view: CandidateView) => {
      if (filter === CandidateFilter.WORDS) {
        return view.chars >= 2;
      }
      if (filter === CandidateFilter.CHARS) {
        return view.chars === 1;
      }
      return true;
    });
  }

  @Computed
  get pages(): UnitCell[][] {
    const slots = this.slots;
    if (slots.length === 0) {
      return [];
    }
    // 左右键区键宽可能不同，按较窄的单位换算占用列数，保证不会越界
    let unit = slots[0].unit;
    for (const slot of slots) {
      unit = Math.min(unit, slot.unit);
    }
    const fontSize = this.candidateFontSize();
    const ui = this.getUIContext();
    const spans: number[] = this.filtered.map((view: CandidateView) => {
      const width = ui.px2vp(ui.getMeasureUtils().measureText({ textContent: view.text, fontSize: fontSize }));
      return (width + CANDIDATE_PADDING_VP * 2) / unit;
    });
    return paginateUnits(spans, slots.map((slot: RowSlot) => slot.columns));
  }

  private candidateFontSize(): number {
    const slots = this.slots;
    const h = slots.length > 0 ? slots[0].h - this.keyGap : 50;
    return Math.max(16, Math.min(h * 0.38, 22));
  }

  private currentPage(): UnitCell[] {
    const pages = this.pages;
    if (pages.length === 0) {
      return [];
    }
    return pages[Math.min(this.pageIndex, pages.length - 1)];
  }

  private pageCount(): number {
    return this.pages.length;
  }

  // ---------- 最下排控件 ----------

  private controlOf(rectId: string, id: ControlId, label: string, selected: boolean, enabled: boolean):
    ControlKey | undefined {
    const rect = findRect(this.letterRects, rectId);
    if (rect === undefined) {
      return undefined;
    }
    const key: ControlKey = {
      id: id, label: label, x: rect.x, y: rect.y, w: rect.w, h: rect.h, selected: selected, enabled: enabled
    };
    return key;
  }

  @Computed
  get filters(): ControlKey[] {
    const list: ControlKey[] = [];
    const filter = this.state.candidateFilter;
    const all = this.controlOf('symbol_page', ControlId.ALL, '全部', filter === CandidateFilter.ALL, true);
    const words = this.controlOf('number_page', ControlId.WORDS, '词语', filter === CandidateFilter.WORDS, true);
    const chars = this.controlOf('punct', ControlId.CHARS, '单字', filter === CandidateFilter.CHARS, true);
    if (all !== undefined) {
      list.push(all);
    }
    if (words !== undefined) {
      list.push(words);
    }
    if (chars !== undefined) {
      list.push(chars);
    }
    return list;
  }

  // 三个筛选键合成一条轨道，轨道连同它们之间的缝隙一起铺满
  @Computed
  get filterTrack(): Box {
    const list = this.filters;
    if (list.length === 0) {
      return EMPTY_BOX;
    }
    let left = list[0].x;
    let right = list[0].x + list[0].w;
    for (const key of list) {
      left = Math.min(left, key.x);
      right = Math.max(right, key.x + key.w);
    }
    const box: Box = { x: left, y: list[0].y, w: right - left, h: list[0].h };
    return box;
  }

  @Computed
  get pager(): ControlKey[] {
    const list: ControlKey[] = [];
    const count = this.pageCount();
    const canPrev = this.pageIndex > 0;
    const canNext = this.pageIndex < count - 1;
    if (this.split) {
      const prev = this.controlOf('space_left', ControlId.PREV, '上一页', false, canPrev);
      const next = this.controlOf('space_right', ControlId.NEXT, '下一页', false, canNext);
      if (prev !== undefined) {
        list.push(prev);
      }
      if (next !== undefined) {
        list.push(next);
      }
      return list;
    }
    const space = findRect(this.letterRects, 'space');
    if (space === undefined) {
      return list;
    }
    // 常规布局下空格键一分为三，页码居中，翻页各占一端
    const side = Math.max(0, (space.w - COUNTER_WIDTH_VP - this.keyGap * 2) / 2);
    const prev: ControlKey = {
      id: ControlId.PREV, label: '上一页', x: space.x, y: space.y, w: side, h: space.h,
      selected: false, enabled: canPrev
    };
    const next: ControlKey = {
      id: ControlId.NEXT, label: '下一页', x: space.x + space.w - side, y: space.y, w: side, h: space.h,
      selected: false, enabled: canNext
    };
    list.push(prev);
    list.push(next);
    return list;
  }

  // 页码落在两个翻页控件之间：分离布局用中央间隙，常规布局用空格键的中段
  @Computed
  get counter(): Box {
    const list = this.pager;
    if (list.length < 2) {
      return EMPTY_BOX;
    }
    const left = list[0];
    const right = list[1];
    const x = left.x + left.w;
    const box: Box = { x: x, y: left.y, w: Math.max(0, right.x - x), h: left.h };
    return box;
  }

  @Computed
  get tailControls(): ControlKey[] {
    const list: ControlKey[] = [];
    const back = this.controlOf('lang', ControlId.BACK, '返回', false, true);
    const del = this.controlOf('enter', ControlId.DELETE, '', false, true);
    if (back !== undefined) {
      list.push(back);
    }
    if (del !== undefined) {
      list.push(del);
    }
    return list;
  }

  private runControl(id: ControlId): void {
    switch (id) {
      case ControlId.ALL:
        this.controller.setCandidateFilter(CandidateFilter.ALL);
        break;
      case ControlId.WORDS:
        this.controller.setCandidateFilter(CandidateFilter.WORDS);
        break;
      case ControlId.CHARS:
        this.controller.setCandidateFilter(CandidateFilter.CHARS);
        break;
      case ControlId.BACK:
        this.controller.closeFreeSelect();
        break;
      case ControlId.PREV:
        this.pageDirection = -1;
        this.pageIndex = Math.max(0, this.pageIndex - 1);
        break;
      case ControlId.NEXT:
        this.pageDirection = 1;
        this.pageIndex = Math.min(Math.max(0, this.pages.length - 1), this.pageIndex + 1);
        break;
      case ControlId.DELETE:
        this.controller.deleteInFreeSelect();
        break;
      default:
        break;
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

  @Styles
  trackNormal() {
    .opacity(1)
  }

  @Styles
  trackPressed() {
    .opacity(0.55)
  }

  private controlTextSize(h: number): number {
    return Math.max(13, Math.min(h * 0.3, 17));
  }

  private controlColor(key: ControlKey): Resource {
    return key.enabled ? $r('app.color.key_text') : $r('app.color.key_hint_text');
  }

  @Builder
  controlContent(key: ControlKey) {
    if (key.id === ControlId.DELETE) {
      SymbolGlyph($r('sys.symbol.delete_left'))
        .fontSize(Math.max(18, Math.min(key.h * 0.4, 26)))
        .fontColor([$r('app.color.key_text')])
    } else if (key.id === ControlId.PREV) {
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(this.controlTextSize(key.h))
          .fontColor([this.controlColor(key)])
        Text(key.label)
          .fontSize(this.controlTextSize(key.h))
          .maxFontScale(1.2)
          .fontColor(this.controlColor(key))
      }
    } else if (key.id === ControlId.NEXT) {
      Row({ space: 4 }) {
        Text(key.label)
          .fontSize(this.controlTextSize(key.h))
          .maxFontScale(1.2)
          .fontColor(this.controlColor(key))
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(this.controlTextSize(key.h))
          .fontColor([this.controlColor(key)])
      }
    } else {
      Text(key.label)
        .fontSize(this.controlTextSize(key.h))
        .maxFontScale(1.2)
        .fontColor(this.controlColor(key))
    }
  }

  @Builder
  trackControl(key: ControlKey) {
    Stack() {
      this.controlContent(key)
    }
    .position({ x: key.x, y: key.y })
    .width(key.w)
    .height(key.h)
    .borderRadius(CONTROL_RADIUS_VP)
    .backgroundColor($r('app.color.kb_segment_track'))
    .stateStyles({ normal: this.trackNormal, pressed: this.trackPressed })
    .accessibilityText(key.id === ControlId.DELETE ? '删除拼音' : key.label)
    .onClick(() => {
      if (key.enabled) {
        this.runControl(key.id);
      }
    })
  }

  @Builder
  filterGroup() {
    Column()
      .position({ x: this.filterTrack.x, y: this.filterTrack.y })
      .width(this.filterTrack.w)
      .height(this.filterTrack.h)
      .borderRadius(CONTROL_RADIUS_VP)
      .backgroundColor($r('app.color.kb_segment_track'))
      .hitTestBehavior(HitTestMode.Transparent)
    ForEach(this.filters, (key: ControlKey) => {
      this.filterItem(key)
    }, (key: ControlKey) => `${key.id}_${key.selected}_${key.x.toFixed(1)}_${key.w.toFixed(1)}`)
  }

  @Builder
  filterItem(key: ControlKey) {
    Text(key.label)
      .fontSize(this.controlTextSize(key.h))
      .maxFontScale(1.2)
      .fontWeight(key.selected ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .fontColor(key.selected ? $r('app.color.kb_accent_text') : $r('app.color.key_text'))
      .backgroundColor(key.selected ? $r('app.color.kb_accent') : Color.Transparent)
      .position({ x: key.x, y: key.y + SEGMENT_INSET_VP })
      .width(key.w)
      .height(Math.max(0, key.h - SEGMENT_INSET_VP * 2))
      .borderRadius(CONTROL_RADIUS_VP - SEGMENT_INSET_VP)
      .animation({ duration: 140, curve: Curve.FastOutSlowIn })
      .accessibilityText(key.label)
      .onClick(() => this.runControl(key.id))
  }

  @Builder
  rowDivider(slot: RowSlot) {
    if (!slot.last) {
      Divider()
        .strokeWidth(DIVIDER_HEIGHT_VP)
        .color($r('app.color.kb_divider'))
        .width(slot.paneW)
        .position({ x: slot.originX, y: slot.y + slot.h })
    }
  }

  @Builder
  candidateCell(cell: UnitCell) {
    if (cell.index < this.filtered.length && cell.slot < this.slots.length) {
      Text(this.filtered[cell.index].text)
        .fontSize(this.candidateFontSize())
        .maxFontScale(1.2)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .fontColor(this.filtered[cell.index].index === 0 ? $r('app.color.kb_accent') : $r('app.color.key_text'))
        .fontWeight(this.filtered[cell.index].index === 0 ? FontWeight.Medium : FontWeight.Normal)
        .position({
          x: this.slots[cell.slot].originX + cell.col * this.slots[cell.slot].unit,
          y: this.slots[cell.slot].y + this.keyGap / 2
        })
        .width(Math.max(0, cell.span * this.slots[cell.slot].unit))
        .height(Math.max(0, this.slots[cell.slot].h - this.keyGap))
        .borderRadius(CELL_RADIUS_VP)
        .stateStyles({ normal: this.flatNormal, pressed: this.flatPressed })
        .accessibilityText(`候选 ${this.filtered[cell.index].index + 1}`)
        .onClick(() => this.controller.selectCandidate(this.filtered[cell.index].index))
        .gesture(LongPressGesture({ repeat: false })
          .onAction(() => this.controller.forgetCandidate(this.filtered[cell.index].index)))
        .transition(slideInTransition(this.pageDirection))
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(this.slots, (slot: RowSlot) => {
        this.rowDivider(slot)
      }, (slot: RowSlot) => `div_${slot.originX.toFixed(1)}_${slot.y.toFixed(1)}`)

      ForEach(this.currentPage(), (cell: UnitCell) => {
        this.candidateCell(cell)
      }, (cell: UnitCell) => `${this.pageIndex}_${cell.index}_${cell.slot}_${cell.col}_${cell.span}`)

      this.filterGroup()

      ForEach(this.pager, (key: ControlKey) => {
        this.trackControl(key)
      }, (key: ControlKey) => `${key.id}_${key.enabled}_${key.x.toFixed(1)}_${key.w.toFixed(1)}`)

      ForEach(this.tailControls, (key: ControlKey) => {
        this.trackControl(key)
      }, (key: ControlKey) => `${key.id}_${key.x.toFixed(1)}_${key.w.toFixed(1)}`)

      if (this.pageCount() > 1 && this.counter.w > 0) {
        Text(`${Math.min(this.pageIndex, this.pageCount() - 1) + 1} / ${this.pageCount()}`)
          .fontSize(13)
          .maxFontScale(1.1)
          .fontColor($r('app.color.key_hint_text'))
          .textAlign(TextAlign.Center)
          .width(this.counter.w)
          .height(this.counter.h)
          .position({ x: this.counter.x, y: this.counter.y })
      }
    }
    .width(this.areaWidth)
    .height(this.areaHeight)
    .backgroundColor($r('app.color.kb_background'))
  }
}
