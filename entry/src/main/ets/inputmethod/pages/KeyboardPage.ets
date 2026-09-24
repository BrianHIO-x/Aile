import { enterLabel, ImeController, isPasswordPattern } from '../../ime/ImeController';
import { ImeState, InputLang, PanelMode, ShiftState } from '../../ime/ImeState';
import {
  CLEAR_SWIPE_LABEL,
  displaySymbol,
  isFunctionKey,
  KeyboardLayout,
  KeyboardPageType,
  KeyType,
  LayoutForm,
  resolveOutput,
  resolveSwipeUp
} from '../../keyboard/KeyDefinitions';
import { computeKeyRects, computePaneBounds, KeyRect, PaneBounds } from '../../keyboard/LayoutEngine';
import { getLayout } from '../../keyboard/Layouts';
import { PANEL_EDGE_VP, PanelZone } from '../../keyboard/PanelZones';
import { KeyPress, TouchRouter, TouchTrack } from '../../keyboard/TouchRouter';
import { letterAlternatives } from '../../keyboard/TouchCorrection';
import { NO_TAP, TouchModel, TouchOffset } from '../../keyboard/TouchModel';
import { CANDIDATE_BAR_HEIGHT_VP, KEYBOARD_BOTTOM_INSET_VP } from '../../keyboard/LayoutProfile';
import { KeyCap, KeyIcon } from '../../keyboard/components/KeyCap';
import { CandidateBar } from '../../keyboard/components/CandidateBar';
import { ClipboardPanel } from '../../keyboard/components/ClipboardPanel';
import { EmojiPanel } from '../../keyboard/components/EmojiPanel';
import { FreeSelectPanel } from '../../keyboard/components/FreeSelectPanel';
import { LayoutTuner } from '../../keyboard/components/LayoutTuner';
import { SettingsHub } from '../../keyboard/components/SettingsHub';
import { ROUND_BUTTON_SIZE_VP } from '../../keyboard/components/AileControls';
import { FlickPreview } from '../../keyboard/components/FlickPreview';
import {
  backdropTransition,
  cardTransition,
  enterAnimation,
  exitAnimation,
  PANEL_SETTLE_MS,
  panelTransition
} from '../../keyboard/Motion';

const TUNER_MAX_WIDTH_VP: number = 460;
const SEPARATOR_LABEL: string = '\'词';

interface ThumbZones {
  split: boolean;
  leftX: number;
  leftWidth: number;
  rightX: number;
  rightWidth: number;
}

@Entry
@ComponentV2
struct KeyboardPage {
  @Local state: ImeState = ImeState.get();
  @Local keysWidth: number = 0;
  @Local keysHeight: number = 0;
  // 面板完全盖住按键后按键停止绘制，面板内滚动时不再重绘下方按键
  @Local keysCovered: boolean = false;
  private controller: ImeController = ImeController.get();
  private router: TouchRouter = new TouchRouter();
  private routedSignature: string = '';
  private coverTimer: number = -1;

  aboutToDisappear(): void {
    this.clearCoverTimer();
  }

  // 表情、剪贴板和功能面板铺满按键区；布局校准是浮在按键上的卡片，按键需要保持可见
  private panelCoversKeys(): boolean {
    const mode = this.state.panelMode;
    return mode === PanelMode.SETTINGS || mode === PanelMode.EMOJI || mode === PanelMode.CLIPBOARD;
  }

  private clearCoverTimer(): void {
    if (this.coverTimer !== -1) {
      clearTimeout(this.coverTimer);
      this.coverTimer = -1;
    }
  }

  // 打开面板时等进入动效结束再隐藏按键，关闭面板时立即显示按键，面板淡出时按键已经在下方
  @Monitor('state.panelMode')
  onPanelModeChanged(monitor: IMonitor): void {
    this.clearCoverTimer();
    if (!this.panelCoversKeys()) {
      this.keysCovered = false;
      return;
    }
    this.coverTimer = setTimeout(() => {
      this.coverTimer = -1;
      this.keysCovered = this.panelCoversKeys();
    }, PANEL_SETTLE_MS);
  }

  @Computed
  get layout(): KeyboardLayout {
    return getLayout(this.state.currentForm(), this.state.page, this.state.symbolCategory);
  }

  @Computed
  get rects(): KeyRect[] {
    return computeKeyRects(this.layout, this.keysWidth, this.keysHeight, this.state.currentProfile());
  }

  // 自由选词界面沿用字母页的按键网格
  @Computed
  get letterRects(): KeyRect[] {
    return computeKeyRects(getLayout(this.state.currentForm(), KeyboardPageType.LETTERS), this.keysWidth,
      this.keysHeight, this.state.currentProfile());
  }

  /**
   * 左右拇指区与键盘左右键区对齐，常规布局只有一个整宽区域。
   */
  @Computed
  get zones(): ThumbZones {
    const bounds: PaneBounds[] = computePaneBounds(this.layout, this.keysWidth, this.state.currentProfile());
    if (this.layout.form === LayoutForm.SPLIT && bounds.length === 2) {
      const zones: ThumbZones = {
        split: true,
        leftX: bounds[0].x,
        leftWidth: bounds[0].width,
        rightX: bounds[1].x,
        rightWidth: bounds[1].width
      };
      return zones;
    }
    const full: PaneBounds = bounds.length > 0 ? bounds[0] : { x: 0, width: this.keysWidth };
    const single: ThumbZones = { split: false, leftX: full.x, leftWidth: full.width, rightX: 0, rightWidth: 0 };
    return single;
  }

  /**
   * 表情与剪贴板的内容区域：分离布局下与两侧键帽边缘对齐，常规布局按整宽排列。
   */
  @Computed
  get contentZones(): PanelZone[] {
    const zones = this.zones;
    const gap = this.state.currentProfile().keyGapVp;
    if (zones.split) {
      const left: PanelZone = { x: zones.leftX + gap / 2, width: Math.max(0, zones.leftWidth - gap) };
      const right: PanelZone = { x: zones.rightX + gap / 2, width: Math.max(0, zones.rightWidth - gap) };
      return [left, right];
    }
    const full: PanelZone = { x: PANEL_EDGE_VP, width: Math.max(0, this.keysWidth - PANEL_EDGE_VP * 2) };
    return [full];
  }

  // 顶部栏按钮对齐的字母键中心，始终取字母页的按键，切换数字页和符号页时按钮位置不跳动。
  // 顶部栏与按键区同在带边距的列中，两者共用同一横坐标系。
  private anchorX(id: string, fallback: number): number {
    for (const rect of this.letterRects) {
      if (rect.key.id === id) {
        return rect.x + rect.w / 2;
      }
    }
    return fallback;
  }

  // 候选区右端停在对齐 P 键的圆形按钮左侧
  private candidateRightLimit(): number {
    return this.anchorX('letter_p', this.keysWidth - 26) - ROUND_BUTTON_SIZE_VP / 2 - 4;
  }

  // 键区边界含半个键间距，候选两侧各缩进这么多，第一候选的底色与键帽边缘落在同一条线上
  private barInset(): number {
    return this.state.currentProfile().keyGapVp / 2;
  }

  private barLeftStart(): number {
    return this.zones.leftX + this.barInset();
  }

  private barRightStart(): number {
    return this.zones.rightX + this.barInset();
  }

  private barRightWidth(): number {
    const zones = this.zones;
    if (!zones.split) {
      return 0;
    }
    const right = Math.min(zones.rightX + zones.rightWidth - this.barInset(), this.candidateRightLimit());
    return Math.max(0, right - this.barRightStart());
  }

  private barLeftWidth(): number {
    const zones = this.zones;
    if (zones.split) {
      return Math.max(0, zones.leftX + zones.leftWidth - this.barInset() - this.barLeftStart());
    }
    return Math.max(0, this.candidateRightLimit() - this.barLeftStart());
  }

  private isSeparatorMode(): boolean {
    return this.state.lang === InputLang.ZH && this.state.page === KeyboardPageType.LETTERS &&
      this.state.isComposing() && !isPasswordPattern(this.state.inputPattern);
  }

  // 与总控一致：中文状态显示中文标点，英文状态与密码框显示英文符号
  private zhSymbols(): boolean {
    return this.state.lang === InputLang.ZH && !isPasswordPattern(this.state.inputPattern);
  }

  private keyLabel(rect: KeyRect): string {
    const key = rect.key;
    switch (key.type) {
      case KeyType.PUNCT:
      case KeyType.CHAR:
        return displaySymbol(resolveOutput(key, this.zhSymbols()));
      case KeyType.SHIFT:
        return this.isSeparatorMode() ? SEPARATOR_LABEL : '';
      case KeyType.SYMBOL_LOCK:
        return this.state.symbolLocked ? '已锁定' : '锁定';
      case KeyType.ENTER:
      case KeyType.DELETE:
      case KeyType.LANG:
      case KeyType.SPACE:
        return '';
      default:
        return key.label;
    }
  }

  private keyHint(rect: KeyRect): string {
    const key = rect.key;
    if (key.type === KeyType.LETTER || key.type === KeyType.PUNCT) {
      return displaySymbol(resolveSwipeUp(key, this.zhSymbols()));
    }
    return '';
  }

  private keyIcon(rect: KeyRect): KeyIcon {
    switch (rect.key.type) {
      case KeyType.ENTER:
        return KeyIcon.ENTER;
      case KeyType.DELETE:
        return KeyIcon.DELETE;
      case KeyType.LANG:
        return this.state.lang === InputLang.ZH ? KeyIcon.LANG_ZH : KeyIcon.LANG_EN;
      case KeyType.SHIFT:
        if (this.isSeparatorMode()) {
          return KeyIcon.NONE;
        }
        if (this.state.shift === ShiftState.LOCKED) {
          return KeyIcon.SHIFT_LOCK;
        }
        return this.state.shift === ShiftState.ONCE ? KeyIcon.SHIFT_ONCE : KeyIcon.SHIFT_OFF;
      default:
        return KeyIcon.NONE;
    }
  }

  private keyAccent(rect: KeyRect): boolean {
    if (rect.key.type === KeyType.SYMBOL_LOCK) {
      return this.state.symbolLocked;
    }
    return rect.key.type === KeyType.ENTER && enterLabel(this.state.enterKeyType) !== '回车' &&
      enterLabel(this.state.enterKeyType) !== '换行';
  }

  private keyAccessibility(rect: KeyRect): string {
    if (rect.key.type === KeyType.ENTER) {
      return enterLabel(this.state.enterKeyType);
    }
    if (rect.key.type === KeyType.SHIFT && this.isSeparatorMode()) {
      return '分词';
    }
    return rect.key.accessibility;
  }

  private swipeRect(): KeyRect | undefined {
    const id = this.state.flickKeyId;
    if (id.length === 0) {
      return undefined;
    }
    for (const rect of this.rects) {
      if (rect.key.id === id) {
        return rect;
      }
    }
    return undefined;
  }

  private isPunctZh(rect: KeyRect): boolean {
    return rect.key.type === KeyType.PUNCT && this.zhSymbols();
  }

  private swipeText(rect: KeyRect): string {
    if (rect.key.type === KeyType.DELETE) {
      return CLEAR_SWIPE_LABEL;
    }
    return displaySymbol(resolveSwipeUp(rect.key, this.zhSymbols()));
  }

  // ForEach 对相同键值不重新执行子项构建，按键传入的矩形会停留在旧值。
  // 删除键、符号键等跨页面共用 ID，键值必须包含按键定义与几何，页面切换后才会刷新宽度、位置和标签。
  private keyCapId(rect: KeyRect): string {
    return `${rect.key.id}|${rect.key.type}|${rect.key.label}|${rect.x.toFixed(1)}|${rect.y.toFixed(1)}|` +
      `${rect.w.toFixed(1)}|${rect.h.toFixed(1)}`;
  }

  // 状态管理可能返回代理数组，用布局签名判断几何是否真正变化
  private layoutSignature(): string {
    return `${this.layout.id}|${this.keysWidth.toFixed(1)}|${this.keysHeight.toFixed(1)}|` +
      JSON.stringify(this.state.currentProfile());
  }

  private syncRouter(): void {
    const signature = this.layoutSignature();
    if (this.routedSignature !== signature) {
      this.routedSignature = signature;
      this.router.setRects(computeKeyRects(this.layout, this.keysWidth, this.keysHeight,
        this.state.currentProfile()));
      this.controller.stopDeleteRepeat();
      this.state.pressedKeyIds = [];
      this.controller.clearFlick();
      this.controller.endCursorMode();
    }
  }

  // 光标模式下只移动光标；其余情况更新上滑进度，移出按键时取消按下
  private applyMove(track: TouchTrack): void {
    if (track.cursorMode) {
      this.controller.onCursorSwipe(track);
      return;
    }
    this.controller.onSwipeChanged(track);
    if (track.cancelled) {
      this.controller.onKeyRelease(track);
    }
  }

  private handleTouch(event: TouchEvent): void {
    if (this.state.panelMode !== PanelMode.KEYBOARD || this.state.candidatesExpanded) {
      return;
    }
    this.syncRouter();
    for (const touch of event.changedTouches) {
      if (touch.type === TouchType.Down) {
        // 移动光标时整块键盘当作触控板，其他手指按下不输入
        if (this.state.cursorMode) {
          continue;
        }
        const track = this.router.down(touch.id, touch.x, touch.y, Date.now());
        if (track !== undefined) {
          this.controller.onKeyDown(track);
        }
        this.controller.reportContentSize(this.keysWidth, this.keysHeight,
          `${touch.x.toFixed(0)},${touch.y.toFixed(0)} id${touch.id}`);
      } else if (touch.type === TouchType.Move) {
        const changed: TouchTrack | undefined = this.router.move(touch.id, touch.x, touch.y, Date.now());
        if (changed !== undefined) {
          this.applyMove(changed);
        }
      } else if (touch.type === TouchType.Up) {
        // 快速上滑可能没有中间的移动事件，抬起坐标先按移动处理，越过阈值即执行的动作不会丢失
        const moved: TouchTrack | undefined = this.router.move(touch.id, touch.x, touch.y, Date.now());
        if (moved !== undefined) {
          if (moved.cursorMode) {
            this.controller.onCursorSwipe(moved);
          } else {
            this.controller.onSwipeChanged(moved);
          }
        }
        const track = this.router.getTrack(touch.id);
        const press: KeyPress | undefined = this.router.up(touch.id, touch.x, touch.y, Date.now());
        if (track !== undefined) {
          this.controller.onKeyRelease(track);
        }
        if (press !== undefined) {
          const isLetter = press.key.type === KeyType.LETTER && !press.swipeUp;
          // 分离与常规布局的拇指姿势不同，按键偏移分开记录
          const form: string = this.state.currentProfile().form;
          const model = TouchModel.get();
          const alternatives = isLetter ? letterAlternatives(this.router.getRects(), press.rect, press.x, press.y,
            (rect: KeyRect): TouchOffset => model.offsetOf(form, rect)) : [];
          const tap = isLetter ? TouchModel.sampleOf(form, press.rect, press.x, press.y) : NO_TAP;
          this.controller.onKeyPress(press.key, press.swipeUp, alternatives, tap);
        }
      } else if (touch.type === TouchType.Cancel) {
        const cancelled = this.router.cancel(touch.id);
        if (cancelled !== undefined) {
          this.controller.onKeyRelease(cancelled);
        }
      }
    }
  }

  @Builder
  overlayLayer() {
    if (this.state.panelMode === PanelMode.TUNER) {
      LayoutTuner()
        .width(Math.min(TUNER_MAX_WIDTH_VP, this.keysWidth * 0.9))
        .height(Math.max(0, this.keysHeight - 12))
        .margin({ top: 4 })
        .transition(cardTransition())
    } else if (this.state.panelMode === PanelMode.SETTINGS) {
      SettingsHub({
        areaWidth: this.keysWidth,
        areaHeight: this.keysHeight,
        split: this.zones.split,
        leftX: this.zones.leftX,
        leftWidth: this.zones.leftWidth,
        rightX: this.zones.rightX,
        rightWidth: this.zones.rightWidth,
        keyGap: this.state.currentProfile().keyGapVp
      })
        .transition(panelTransition())
    } else if (this.state.candidatesExpanded) {
      FreeSelectPanel({
        letterRects: this.letterRects,
        split: this.zones.split,
        areaWidth: this.keysWidth,
        areaHeight: this.keysHeight,
        keyGap: this.state.currentProfile().keyGapVp
      })
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0).animation(enterAnimation(180))
            .combine(TransitionEffect.translate({ y: 12 }).animation(enterAnimation(240))),
          TransitionEffect.opacity(0).animation(exitAnimation(120))))
    }
  }

  private bottomInset(): number {
    return Math.max(this.state.keyboardPadding.bottom, KEYBOARD_BOTTOM_INSET_VP);
  }

  /**
   * 表情与剪贴板属于可滚动内容，按沉浸式要求延伸到底部手势横条下方，
   * 列表内部留出同样高度的底部内边距，最后一行仍可滚动到横条上方。
   */
  @Builder
  immersiveLayer() {
    if (this.state.panelMode === PanelMode.EMOJI) {
      EmojiPanel({
        areaWidth: this.keysWidth,
        areaHeight: this.keysHeight + this.bottomInset(),
        bottomInset: this.bottomInset(),
        zones: this.contentZones
      })
        .position({ x: this.state.keyboardPadding.left, y: CANDIDATE_BAR_HEIGHT_VP })
        .transition(panelTransition())
    } else if (this.state.panelMode === PanelMode.CLIPBOARD) {
      ClipboardPanel({
        areaWidth: this.keysWidth,
        areaHeight: this.keysHeight + this.bottomInset(),
        bottomInset: this.bottomInset(),
        zones: this.contentZones
      })
        .position({ x: this.state.keyboardPadding.left, y: CANDIDATE_BAR_HEIGHT_VP })
        .transition(panelTransition())
    }
  }

  @Builder
  swipeLayer() {
    if (this.swipeRect() !== undefined) {
      FlickPreview({
        keyX: this.state.keyboardPadding.left + (this.swipeRect() as KeyRect).x,
        keyY: CANDIDATE_BAR_HEIGHT_VP + (this.swipeRect() as KeyRect).y,
        keyW: (this.swipeRect() as KeyRect).w,
        keyH: (this.swipeRect() as KeyRect).h,
        text: this.swipeText(this.swipeRect() as KeyRect),
        committed: this.state.flickCommitted,
        danger: (this.swipeRect() as KeyRect).key.type === KeyType.DELETE
      })
        .transition(TransitionEffect.OPACITY.animation({ duration: 90, curve: Curve.EaseOut }))
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        CandidateBar({
          barHeight: CANDIDATE_BAR_HEIGHT_VP,
          barWidth: this.keysWidth,
          leftStart: this.barLeftStart(),
          leftWidth: this.barLeftWidth(),
          rightStart: this.barRightStart(),
          rightWidth: this.barRightWidth(),
          anchorQ: this.anchorX('letter_q', 26),
          anchorI: this.anchorX('letter_i', this.keysWidth - 170),
          anchorO: this.anchorX('letter_o', this.keysWidth - 98),
          anchorP: this.anchorX('letter_p', this.keysWidth - 26)
        })

        Stack({ alignContent: Alignment.Top }) {
          // KeyCap 在组件内部按矩形定位，外层必须从左上角排布，否则每个组件会按自身宽度水平居中
          Stack({ alignContent: Alignment.TopStart }) {
            ForEach(this.rects, (rect: KeyRect) => {
              KeyCap({
                rect: rect,
                label: this.keyLabel(rect),
                hint: this.keyHint(rect),
                icon: this.keyIcon(rect),
                pressed: this.state.pressedKeyIds.indexOf(rect.key.id) >= 0,
                functional: isFunctionKey(rect.key),
                accent: this.keyAccent(rect),
                flickProgress: this.state.flickKeyId === rect.key.id ? this.state.flickProgress : 0,
                flickCommitted: this.state.flickKeyId === rect.key.id && this.state.flickCommitted,
                punctZh: this.isPunctZh(rect),
                muted: this.state.cursorMode
              })
                .accessibilityText(this.keyAccessibility(rect))
            }, (rect: KeyRect) => this.keyCapId(rect))
          }
          .width('100%')
          .height('100%')
          .visibility(this.keysCovered ? Visibility.Hidden : Visibility.Visible)

          // 面板底色：面板之间互相切换时两者交替淡入淡出，下方按键不会透出来
          if (this.panelCoversKeys()) {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor($r('app.color.kb_background'))
              .hitTestBehavior(HitTestMode.None)
              .transition(backdropTransition())
          }

          this.overlayLayer()

          if (this.state.showProbe) {
            Column() {
              ForEach(this.state.probeLines, (line: string) => {
                Text(line)
                  .fontSize(11)
                  .fontColor(Color.White)
                  .maxFontScale(1)
              }, (line: string, index: number) => `${index}_${line}`)
            }
            .padding(6)
            .backgroundColor('#B3000000')
            .borderRadius(6)
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .clip(true)
        .onSizeChange((oldValue: SizeOptions, newValue: SizeOptions) => {
          this.keysWidth = Number(newValue.width ?? 0);
          this.keysHeight = Number(newValue.height ?? 0);
        })
        .onTouch((event: TouchEvent) => this.handleTouch(event))
      }
      .width('100%')
      .height('100%')
      .padding({
        left: this.state.keyboardPadding.left,
        right: this.state.keyboardPadding.right,
        // 系统提供的底部区域与手势横条留白取较大值，避免重复扣除
        bottom: this.bottomInset()
      })

      this.immersiveLayer()
      this.swipeLayer()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.kb_background'))
  }
}
