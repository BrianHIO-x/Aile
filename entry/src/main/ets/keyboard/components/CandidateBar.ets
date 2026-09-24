import { ClipTab, ImeState, LexiconStatus, PanelMode } from '../../ime/ImeState';
import { countCodePoints } from '../PickText';
import { ImeController } from '../../ime/ImeController';
import { allocateBar, BarAllocation, CandidateSlot } from '../CandidateLayout';
import { EMOJI_CATEGORIES, EmojiCategory } from '../EmojiData';
import { KeyboardPageType } from '../KeyDefinitions';
import { SYMBOL_CATEGORIES, SymbolCategory } from '../Layouts';
import { AileIcon, ROUND_BUTTON_SIZE_VP, RoundIconButton, SegmentedTabs } from './AileControls';
import { EMOJI_LEFT_TAB_COUNT } from './EmojiPanel';
import { headerTransition, popTransition } from '../Motion';
import { SETTINGS_LEFT_TABS, SETTINGS_RIGHT_TABS } from './SettingsHub';

// 顶部栏按钮之间与候选、标签之间保留的最小间距
const BAR_SPACING_VP: number = 8;
export const CANDIDATE_FONT_SIZE: number = 19;
const CANDIDATE_PADDING_VP: number = 10;
const CANDIDATE_GAP_VP: number = 4;
const PREEDIT_HEIGHT_VP: number = 16;
// 第一候选坐在一块键帽色的圆角底上，上下各留一点空隙，底色因此是一枚胶囊
const CANDIDATE_PILL_INSET_VP: number = 1;
const CANDIDATE_PILL_RADIUS_VP: number = 9;
const SEGMENT_HEIGHT_VP: number = 36;
const SEGMENT_TRACK_PADDING_VP: number = 3;
const EMOJI_TAB_PADDING_VP: number = 12;
const CLIP_TABS: string[] = ['剪贴板', '常用语'];

enum ShortcutId {
  EMOJI = 'emoji',
  CLIPBOARD = 'clipboard'
}

// 顶部栏按模式整组切换的内容
enum BarHeader {
  IDLE = 0,
  COMPOSING = 1,
  SETTINGS = 2,
  EMOJI = 3,
  CLIPBOARD = 4,
  PICK = 5,
  TUNER = 6
}

interface ShortcutSlot {
  id: ShortcutId;
  centerX: number;
}

@ComponentV2
export struct BarButton {
  @Param text: string = '';
  @Param selected: boolean = false;
  @Param available: boolean = true;
  @Param accessibility: string = '';
  @Event action: () => void = () => {
  };

  build() {
    Text(this.text)
      .fontSize(14)
      .maxFontScale(1.2)
      .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.selected ? $r('app.color.kb_accent_text') : $r('app.color.key_text'))
      .backgroundColor(this.selected ? $r('app.color.kb_accent') : $r('app.color.key_background'))
      .borderRadius(16)
      .padding({ left: 14, right: 14 })
      .height(32)
      .opacity(this.available ? 1 : 0.4)
      .animation({ duration: 140, curve: Curve.FastOutSlowIn })
      .accessibilityText(this.accessibility.length > 0 ? this.accessibility : this.text)
      .onClick(() => {
        if (this.available) {
          this.action();
        }
      })
  }
}

/**
 * 撤销清空按钮：强调色胶囊，高度与圆形按钮一致。
 */
@ComponentV2
struct UndoPill {
  @Event action: () => void = () => {
  };

  @Styles
  pillNormal() {
    .opacity(1)
  }

  @Styles
  pillPressed() {
    .opacity(0.72)
  }

  build() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
        .fontSize(16)
        .fontColor([$r('app.color.kb_accent_text')])
      Text('撤销清空')
        .fontSize(14)
        .maxFontScale(1.2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.kb_accent_text'))
    }
    .height(ROUND_BUTTON_SIZE_VP)
    .padding({ left: 12, right: 14 })
    .borderRadius(ROUND_BUTTON_SIZE_VP / 2)
    .backgroundColor($r('app.color.kb_accent'))
    .stateStyles({ normal: this.pillNormal, pressed: this.pillPressed })
    .accessibilityText('撤销清空')
    .onClick(() => this.action())
  }
}

/**
 * 顶部栏。左上角 Aile 标志对齐 Q 键，右上角圆形按钮对齐 P 键，快捷入口依次对齐 O 键与 I 键。
 * 空闲时显示标志、快捷入口和状态；组词时显示候选；功能面板、表情和剪贴板各有对应的标题栏。
 */
@ComponentV2
export struct CandidateBar {
  @Local state: ImeState = ImeState.get();
  @Param barHeight: number = 50;
  @Param barWidth: number = 0;
  // 左右拇指候选区，单位 vp；rightWidth 为 0 表示常规布局只用一个分组
  @Param leftStart: number = 0;
  @Param leftWidth: number = 0;
  @Param rightStart: number = 0;
  @Param rightWidth: number = 0;
  // 字母键中心横坐标，顶部栏按钮与之对齐
  @Param anchorQ: number = 0;
  @Param anchorI: number = 0;
  @Param anchorO: number = 0;
  @Param anchorP: number = 0;
  private controller: ImeController = ImeController.get();

  private candidateWidth(text: string): number {
    const ui = this.getUIContext();
    const textWidth = ui.px2vp(ui.getMeasureUtils().measureText({
      textContent: text,
      fontSize: CANDIDATE_FONT_SIZE
    }));
    return textWidth + CANDIDATE_PADDING_VP * 2;
  }

  @Computed
  get allocation(): BarAllocation {
    const widths: number[] = [];
    const limit = Math.max(this.leftWidth, 0) + Math.max(this.rightWidth, 0);
    let total = 0;
    for (const candidate of this.state.candidates) {
      const width = this.candidateWidth(candidate.text);
      widths.push(width);
      total += width + CANDIDATE_GAP_VP;
      if (total > limit) {
        break;
      }
    }
    return allocateBar(widths, this.leftWidth, this.rightWidth, CANDIDATE_GAP_VP);
  }

  // ---------- 位置 ----------

  private buttonY(): number {
    return (this.barHeight - ROUND_BUTTON_SIZE_VP) / 2;
  }

  private buttonX(centerX: number): number {
    return centerX - ROUND_BUTTON_SIZE_VP / 2;
  }

  // 已开启的快捷入口从右向左依次占用 O 键与 I 键上方
  private shortcuts(): ShortcutSlot[] {
    const slots: ShortcutSlot[] = [];
    const centers = [this.anchorO, this.anchorI];
    if (this.state.toolbarEmoji) {
      slots.push({ id: ShortcutId.EMOJI, centerX: centers[slots.length] });
    }
    if (this.state.toolbarClipboard) {
      slots.push({ id: ShortcutId.CLIPBOARD, centerX: centers[slots.length] });
    }
    return slots;
  }

  // 标志右侧到最左一个快捷入口（没有时为圆形按钮）左侧之间的中部区域
  private middleLeft(): number {
    return this.anchorQ + ROUND_BUTTON_SIZE_VP / 2 + BAR_SPACING_VP;
  }

  private middleRight(): number {
    const slots = this.shortcuts();
    const center = slots.length > 0 ? slots[slots.length - 1].centerX : this.anchorP;
    return center - ROUND_BUTTON_SIZE_VP / 2 - BAR_SPACING_VP;
  }

  private middleWidth(): number {
    return Math.max(0, this.middleRight() - this.middleLeft());
  }

  // ---------- 组词候选 ----------

  private pillHeight(): number {
    return Math.max(0, this.barHeight - PREEDIT_HEIGHT_VP - CANDIDATE_PILL_INSET_VP * 2);
  }

  @Builder
  candidateItem(slot: CandidateSlot) {
    if (slot.index < this.state.candidates.length) {
      Text(this.state.candidates[slot.index].text)
        .fontSize(CANDIDATE_FONT_SIZE)
        .fontWeight(slot.index === 0 ? FontWeight.Medium : FontWeight.Normal)
        .maxFontScale(1.2)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(slot.index === 0 ? $r('app.color.kb_accent') : $r('app.color.key_text'))
        .textAlign(TextAlign.Center)
        .width(slot.width)
        .height(this.pillHeight())
        .borderRadius(CANDIDATE_PILL_RADIUS_VP)
        .backgroundColor(slot.index === 0 ? $r('app.color.kb_candidate_pill') : Color.Transparent)
        .position({ x: slot.x, y: CANDIDATE_PILL_INSET_VP })
        .accessibilityText(`候选 ${slot.index + 1}`)
        .onClick(() => this.controller.selectCandidate(slot.index))
        .gesture(LongPressGesture({ repeat: false })
          .onAction(() => this.controller.forgetCandidate(slot.index)))
    }
  }

  @Builder
  candidateRow() {
    Text(this.state.preedit)
      .fontSize(12)
      .maxFontScale(1.1)
      .fontColor($r('app.color.key_hint_text'))
      .height(PREEDIT_HEIGHT_VP)
      .maxLines(1)
      .position({ x: this.leftStart + CANDIDATE_PADDING_VP, y: 0 })
    // 自由选词界面打开时候选全部在下方网格中，候选栏只保留拼音
    if (!this.state.candidatesExpanded) {
      Stack() {
        ForEach(this.allocation.left, (slot: CandidateSlot) => {
          this.candidateItem(slot)
        }, (slot: CandidateSlot) => `${slot.index}_${slot.x.toFixed(1)}_${slot.width.toFixed(1)}`)
      }
      .width(this.leftWidth)
      .height(this.barHeight - PREEDIT_HEIGHT_VP)
      .position({ x: this.leftStart, y: PREEDIT_HEIGHT_VP })
      if (this.rightWidth > 0) {
        Stack() {
          ForEach(this.allocation.right, (slot: CandidateSlot) => {
            this.candidateItem(slot)
          }, (slot: CandidateSlot) => `${slot.index}_${slot.x.toFixed(1)}_${slot.width.toFixed(1)}`)
        }
        .width(this.rightWidth)
        .height(this.barHeight - PREEDIT_HEIGHT_VP)
        .position({ x: this.rightStart, y: PREEDIT_HEIGHT_VP })
      }
    }
  }

  // ---------- 空闲 ----------

  @Builder
  brandMark() {
    RoundIconButton({
      icon: AileIcon.MARK,
      iconSize: 24,
      accessibility: 'Aile 功能面板',
      action: () => this.controller.openSettings()
    })
      .position({ x: this.buttonX(this.anchorQ), y: this.buttonY() })
  }

  @Builder
  shortcutButtons() {
    ForEach(this.shortcuts(), (slot: ShortcutSlot) => {
      RoundIconButton({
        icon: slot.id === ShortcutId.EMOJI ? AileIcon.EMOJI : AileIcon.CLIPBOARD,
        accessibility: slot.id === ShortcutId.EMOJI ? '表情' : '剪贴板',
        action: () => {
          if (slot.id === ShortcutId.EMOJI) {
            this.controller.openEmoji();
          } else {
            this.controller.openClipboard();
          }
        }
      })
        .position({ x: this.buttonX(slot.centerX), y: this.buttonY() })
    }, (slot: ShortcutSlot) => `${slot.id}_${slot.centerX.toFixed(1)}`)
  }

  @Builder
  statusLine() {
    Text(this.statusText())
      .fontSize(12)
      .maxFontScale(1.1)
      .fontColor($r('app.color.key_hint_text'))
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .width(this.middleWidth())
      .height('100%')
      .position({ x: this.middleLeft(), y: 0 })
  }

  // 清空由右手拇指完成，撤销按钮贴在中部区域右端，紧挨快捷入口
  @Builder
  undoButton() {
    Row() {
      UndoPill({ action: () => this.controller.undoClear() })
    }
    .justifyContent(FlexAlign.End)
    .width(this.middleWidth())
    .height(ROUND_BUTTON_SIZE_VP)
    .position({ x: this.middleLeft(), y: this.buttonY() })
    .hitTestBehavior(HitTestMode.Transparent)
    .transition(popTransition())
  }

  private tabsY(): number {
    return (this.barHeight - SEGMENT_HEIGHT_VP) / 2;
  }

  // 符号分类放在左手区，紧跟 Aile 标志；锁定改由右下角的锁定键负责
  @Builder
  symbolTabs() {
    SegmentedTabs({
      items: SYMBOL_CATEGORIES.map((c: SymbolCategory) => c.name),
      selected: this.state.symbolCategory,
      itemPadding: 14,
      select: (index: number) => this.controller.selectSymbolCategory(index)
    })
      .position({ x: this.middleLeft(), y: this.tabsY() })
  }

  // 打字与空闲时位置和外观保持不变：点按空闲时收起键盘，组词时打开自由选词；长按打开功能面板
  @Builder
  circleButton() {
    RoundIconButton({
      icon: AileIcon.CHEVRON_DOWN,
      rotation: this.state.candidatesExpanded ? 180 : 0,
      filled: true,
      accessibility: this.state.isComposing() ? '展开自由选词' : '收起键盘',
      action: () => this.controller.onCircleButton(),
      longAction: () => this.controller.openSettings()
    })
      .position({ x: this.buttonX(this.anchorP), y: this.buttonY() })
  }

  // ---------- 面板标题栏 ----------

  // 功能面板标签：左组紧跟返回按钮，右组贴在圆形按钮左侧
  @Builder
  settingsTabs() {
    SegmentedTabs({
      items: SETTINGS_LEFT_TABS,
      selected: this.state.settingsTab < SETTINGS_LEFT_TABS.length ? this.state.settingsTab : -1,
      itemPadding: 16,
      parkAt: SETTINGS_LEFT_TABS.length - 1,
      select: (index: number) => this.controller.setSettingsTab(index)
    })
      .position({ x: this.middleLeft(), y: this.tabsY() })
    Row() {
      SegmentedTabs({
        items: SETTINGS_RIGHT_TABS,
        selected: this.state.settingsTab >= SETTINGS_LEFT_TABS.length ?
          this.state.settingsTab - SETTINGS_LEFT_TABS.length : -1,
        itemPadding: 16,
        select: (index: number) => this.controller.setSettingsTab(SETTINGS_LEFT_TABS.length + index)
      })
    }
    .justifyContent(FlexAlign.End)
    .width(this.barWidth / 2)
    .height('100%')
    .position({ x: this.anchorP - ROUND_BUTTON_SIZE_VP / 2 - BAR_SPACING_VP - this.barWidth / 2, y: 0 })
  }

  private emojiTabNames(from: number, to: number): string[] {
    return EMOJI_CATEGORIES.slice(from, to).map((c: EmojiCategory) => c.name);
  }

  // 分段标签的宽度：每项文字宽度加左右内边距，再加轨道内边距
  private tabsWidth(items: string[], itemPadding: number): number {
    const ui = this.getUIContext();
    let total = SEGMENT_TRACK_PADDING_VP * 2;
    for (const item of items) {
      const textWidth = ui.px2vp(ui.getMeasureUtils().measureText({
        textContent: item,
        fontSize: 14,
        fontWeight: FontWeight.Medium
      }));
      total += textWidth + itemPadding * 2;
    }
    return total;
  }

  // 表情标签右组贴在对齐 O 键的删除按钮左侧
  private emojiTabsRight(): number {
    return this.anchorO - ROUND_BUTTON_SIZE_VP / 2 - BAR_SPACING_VP;
  }

  // 分离布局下两组标签之间仍留有间距时才分组显示
  private emojiTabsSplit(): boolean {
    if (this.rightWidth <= 0) {
      return false;
    }
    const leftEnd = this.middleLeft() +
      this.tabsWidth(this.emojiTabNames(0, EMOJI_LEFT_TAB_COUNT), EMOJI_TAB_PADDING_VP);
    const rightStart = this.emojiTabsRight() -
      this.tabsWidth(this.emojiTabNames(EMOJI_LEFT_TAB_COUNT, EMOJI_CATEGORIES.length), EMOJI_TAB_PADDING_VP);
    return leftEnd + BAR_SPACING_VP <= rightStart;
  }

  // 表情分类：分离布局下左组紧跟返回按钮，右组贴在删除按钮左侧；常规布局合为一组居中
  @Builder
  emojiTabs() {
    if (this.emojiTabsSplit()) {
      SegmentedTabs({
        items: this.emojiTabNames(0, EMOJI_LEFT_TAB_COUNT),
        selected: this.state.emojiCategory < EMOJI_LEFT_TAB_COUNT ? this.state.emojiCategory : -1,
        itemPadding: EMOJI_TAB_PADDING_VP,
        parkAt: EMOJI_LEFT_TAB_COUNT - 1,
        select: (index: number) => this.controller.selectEmojiCategory(index)
      })
        .position({ x: this.middleLeft(), y: this.tabsY() })
      Row() {
        SegmentedTabs({
          items: this.emojiTabNames(EMOJI_LEFT_TAB_COUNT, EMOJI_CATEGORIES.length),
          selected: this.state.emojiCategory >= EMOJI_LEFT_TAB_COUNT ?
            this.state.emojiCategory - EMOJI_LEFT_TAB_COUNT : -1,
          itemPadding: EMOJI_TAB_PADDING_VP,
          select: (index: number) => this.controller.selectEmojiCategory(EMOJI_LEFT_TAB_COUNT + index)
        })
      }
      .justifyContent(FlexAlign.End)
      .width(this.barWidth / 2)
      .height('100%')
      .position({ x: this.emojiTabsRight() - this.barWidth / 2, y: 0 })
      .hitTestBehavior(HitTestMode.Transparent)
    } else {
      Row() {
        SegmentedTabs({
          items: this.emojiTabNames(0, EMOJI_CATEGORIES.length),
          selected: this.state.emojiCategory,
          itemPadding: EMOJI_TAB_PADDING_VP,
          select: (index: number) => this.controller.selectEmojiCategory(index)
        })
      }
      .justifyContent(FlexAlign.Center)
      .width(this.panelMiddleWidth())
      .height('100%')
      .position({ x: this.panelMiddleLeft(), y: 0 })
    }
  }

  // 面板标题栏的中部区域以整栏中线对称，左右各让出一个对齐 O 键的按钮位
  private panelMiddleLeft(): number {
    return this.barWidth - (this.anchorO - ROUND_BUTTON_SIZE_VP / 2 - BAR_SPACING_VP);
  }

  private panelMiddleWidth(): number {
    return Math.max(0, this.anchorO - ROUND_BUTTON_SIZE_VP / 2 - BAR_SPACING_VP - this.panelMiddleLeft());
  }

  // 剪贴板面板标签紧跟返回按钮
  @Builder
  clipTabs() {
    SegmentedTabs({
      items: CLIP_TABS,
      selected: this.state.clipTab,
      itemPadding: 16,
      select: (index: number) => this.controller.selectClipTab(index)
    })
      .position({ x: this.middleLeft(), y: this.tabsY() })
  }

  // 剪贴板页右侧为清空记录，常用语页右侧为保存输入框文字
  @Builder
  clipAction() {
    if (this.state.clipTab === ClipTab.PHRASES) {
      RoundIconButton({
        icon: AileIcon.ADD,
        accessibility: '把输入框里的文字存为常用语',
        action: () => this.controller.addEditorTextToPhrases()
      })
        .position({ x: this.buttonX(this.anchorO), y: this.buttonY() })
        .transition(popTransition())
    } else {
      RoundIconButton({
        icon: AileIcon.CLEAR,
        available: this.state.clipboardItems.length > 0,
        accessibility: '清空剪贴板记录',
        action: () => this.controller.clearClips()
      })
        .position({ x: this.buttonX(this.anchorO), y: this.buttonY() })
        .transition(popTransition())
    }
  }

  private pickCount(): number {
    let count = 0;
    const tokens = this.state.pickTokens;
    const selected = this.state.pickSelected;
    for (let i = 0; i < tokens.length && i < selected.length; i++) {
      if (selected[i]) {
        count += countCodePoints(tokens[i]);
      }
    }
    return count;
  }

  private pickAllSelected(): boolean {
    return this.state.pickSelected.length > 0 && this.state.pickSelected.every((item: boolean) => item);
  }

  // 滑动选字：左侧为标题，右侧为全选和输入，输入按钮停在 O 键上方；返回按钮由整栏统一放置
  @Builder
  pickHeader() {
    Text(this.pickCount() > 0 ? `滑动选字 · 已选 ${this.pickCount()} 字` : '滑动选字')
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .maxFontScale(1.2)
      .maxLines(1)
      .fontColor($r('app.color.key_text'))
      .height('100%')
      .position({ x: this.middleLeft(), y: 0 })
    Row({ space: 8 }) {
      BarButton({
        text: this.pickAllSelected() ? '取消全选' : '全选',
        action: () => this.controller.togglePickAll()
      })
      BarButton({
        text: '输入',
        selected: true,
        available: this.pickCount() > 0,
        accessibility: '输入选中的文字',
        action: () => this.controller.commitPick()
      })
    }
    .justifyContent(FlexAlign.End)
    .width(this.barWidth / 2)
    .height('100%')
    .position({ x: this.anchorO + ROUND_BUTTON_SIZE_VP / 2 - this.barWidth / 2, y: 0 })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  tunerHeader() {
    Text(this.state.isLandscape ? '布局校准 · 横屏' : '布局校准 · 竖屏')
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .maxFontScale(1.2)
      .fontColor($r('app.color.key_text'))
      .height('100%')
      .position({ x: this.buttonX(this.anchorQ) + 6, y: 0 })
    Row({ space: 8 }) {
      BarButton({
        text: '恢复默认',
        action: () => this.controller.resetProfile(this.state.currentOrientation())
      })
      BarButton({
        text: '完成',
        selected: true,
        action: () => this.controller.setPanelMode(PanelMode.SETTINGS)
      })
    }
    .justifyContent(FlexAlign.End)
    .width(this.barWidth / 2)
    .height('100%')
    .position({ x: this.anchorP + ROUND_BUTTON_SIZE_VP / 2 - this.barWidth / 2, y: 0 })
  }

  private statusText(): string {
    if (this.state.statusMessage.length > 0) {
      return this.state.statusMessage;
    }
    switch (this.state.lexiconStatus) {
      case LexiconStatus.LOADING:
        return '词库加载中';
      case LexiconStatus.MISSING:
        return '未安装中文词库';
      case LexiconStatus.FAILED:
        return '词库加载失败';
      default:
        return '';
    }
  }

  private header(): BarHeader {
    switch (this.state.panelMode) {
      case PanelMode.TUNER:
        return BarHeader.TUNER;
      case PanelMode.SETTINGS:
        return BarHeader.SETTINGS;
      case PanelMode.EMOJI:
        return BarHeader.EMOJI;
      case PanelMode.CLIPBOARD:
        return this.state.isPicking() ? BarHeader.PICK : BarHeader.CLIPBOARD;
      default:
        return this.state.isComposing() ? BarHeader.COMPOSING : BarHeader.IDLE;
    }
  }

  // 左上角按钮：面板中为返回键盘，选字时为返回列表。面板之间切换时按钮保持不动，不随标题重新淡入
  @Builder
  leadingButton() {
    if (this.header() === BarHeader.PICK) {
      RoundIconButton({
        icon: AileIcon.CHEVRON_LEFT,
        accessibility: '返回列表',
        action: () => this.controller.cancelPick()
      })
        .position({ x: this.buttonX(this.anchorQ), y: this.buttonY() })
        .transition(headerTransition(false))
    } else if (this.header() === BarHeader.SETTINGS || this.header() === BarHeader.EMOJI ||
      this.header() === BarHeader.CLIPBOARD) {
      RoundIconButton({
        icon: AileIcon.KEYBOARD,
        accessibility: '返回键盘',
        action: () => this.controller.closePanel()
      })
        .position({ x: this.buttonX(this.anchorQ), y: this.buttonY() })
        .transition(headerTransition(false))
    }
  }

  /**
   * 各模式的内容整组构建。模式切换时旧组立即移除，新组淡入，同一时刻只绘制一组。
   * 组容器铺满整栏且不拦截触摸，组内元素沿用整栏坐标定位。
   */
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.header() === BarHeader.TUNER) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.tunerHeader()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(headerTransition(true))
      } else if (this.header() === BarHeader.SETTINGS) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.settingsTabs()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(headerTransition(true))
      } else if (this.header() === BarHeader.EMOJI) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.emojiTabs()
          RoundIconButton({
            icon: AileIcon.DELETE,
            repeat: true,
            accessibility: '删除',
            action: () => this.controller.deleteInPanel(),
            longAction: () => this.controller.deleteInPanel()
          })
            .position({ x: this.buttonX(this.anchorO), y: this.buttonY() })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(headerTransition(true))
      } else if (this.header() === BarHeader.CLIPBOARD) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.clipTabs()
          this.clipAction()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(headerTransition(true))
      } else if (this.header() === BarHeader.PICK) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.pickHeader()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(headerTransition(true))
      } else if (this.header() === BarHeader.COMPOSING) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.candidateRow()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(headerTransition(false))
      } else {
        Stack({ alignContent: Alignment.TopStart }) {
          if (this.state.page === KeyboardPageType.SYMBOLS) {
            this.symbolTabs()
          } else {
            this.statusLine()
          }
          if (this.state.clearUndoAvailable) {
            this.undoButton()
          }
          this.brandMark()
          this.shortcutButtons()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(headerTransition(false))
      }
      this.leadingButton()
      if (this.header() !== BarHeader.TUNER) {
        this.circleButton()
      }
    }
    .width('100%')
    .height(this.barHeight)
    .backgroundColor($r('app.color.kb_background'))
  }
}
