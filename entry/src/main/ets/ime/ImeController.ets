import { inputMethodEngine, InputMethodExtensionContext, InputMethodSubtype } from '@kit.IMEKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  hasSwipeUp,
  KeyboardPageType,
  KeyDef,
  KeyType,
  LayoutForm,
  resolveOutput,
  resolveSwipeUp
} from '../keyboard/KeyDefinitions';
import { SYMBOL_CATEGORY_EN, SYMBOL_CATEGORY_ZH } from '../keyboard/Layouts';
import { copyProfile, defaultProfile, LayoutProfile, ProfileOrientation } from '../keyboard/LayoutProfile';
import { LONG_PRESS_MS, REPEAT_INTERVAL_MS, TouchTrack } from '../keyboard/TouchRouter';
import { ConfirmedTyping, NO_TAP, TapSample, TouchModel } from '../keyboard/TouchModel';
import {
  CandidateOrigin,
  CandidateProvider,
  CandidateSource,
  LetterAlternative,
  RawCandidateProvider
} from '../engine/EngineTypes';
import { characterCount } from '../engine/UserLexicon';
import { consumedForSyllable, extractPinyinOptions } from '../engine/PinyinFilter';
import { RECENT_EMOJI_LIMIT } from '../keyboard/EmojiData';
import { PICK_TEXT_LIMIT, splitPickTokens } from '../keyboard/PickText';
import {
  KEY_CANDIDATE_SIZE,
  KEY_CLIPBOARD_ITEMS,
  KEY_FUZZY_PINYIN,
  KEY_PHRASE_ITEMS,
  KEY_RECENT_EMOJI,
  KEY_TOOLBAR_CLIPBOARD,
  KEY_TOOLBAR_EMOJI,
  LayoutStore
} from '../storage/LayoutStore';
import { ClipboardService } from './ClipboardService';
import {
  CandidateAnchor,
  CandidateFilter,
  CandidateSize,
  CandidateView,
  ClipTab,
  ImeState,
  InputLang,
  LexiconStatus,
  PanelMode,
  ShiftState
} from './ImeState';
import {
  CandidateRules,
  CommitLearner,
  CommitResult,
  CompositionController,
  CompositionSnapshot
} from './CompositionController';
import { CLEAR_TEXT_LIMIT, ClearResult, ClearStatus, EditorAdapter } from './EditorAdapter';
import { continuableSegments, ContinuationStart, ContinuationTracker } from './ContinuationTracker';
import { PanelController } from './PanelController';
import { Log } from './Log';

const DOUBLE_TAP_MS: number = 300;
// 拖动键盘高度时两次调整面板窗口的最短间隔，每次调整都要跨进程重新排布窗口
const HEIGHT_PREVIEW_INTERVAL_MS: number = 60;
const CONTEXT_TAIL_LENGTH: number = 8;
const CLIPBOARD_LIMIT: number = 30;
const CLIPBOARD_TEXT_LIMIT: number = 5000;
const PHRASE_LIMIT: number = 100;
// 一次按键的组词耗时超过这个毫秒数时记一条日志，便于发现词库搜索退化
const SLOW_COMPOSE_MS: number = 25;
// 按住删除键时手指上移超过上滑阈值的这个比例，就算开始上滑。这次按住不再连续删除，手指回落也不恢复，
// 按住时的轻微抖动达不到这个距离
const DELETE_SWIPE_START_PROGRESS: number = 0.3;
// 删除候选以后撤销提示停留的时间
const REMOVED_NOTICE_MS: number = 4000;

/**
 * 最近一次清空的撤销内容，只在内存中保留一份。清空拼音时 composition 为按下前的组词快照，清空编辑框时为 undefined。
 */
interface ClearUndo {
  session: number;
  text: string;
  caret: number;
  composition: CompositionSnapshot | undefined;
}

export function isPasswordPattern(pattern: number): boolean {
  return pattern === inputMethodEngine.PATTERN_PASSWORD ||
    pattern === inputMethodEngine.PATTERN_PASSWORD_SCREEN_LOCK ||
    pattern === inputMethodEngine.PATTERN_PASSWORD_NUMBER ||
    pattern === inputMethodEngine.PATTERN_NEW_PASSWORD;
}

export function isNumberPattern(pattern: number): boolean {
  return pattern === inputMethodEngine.PATTERN_NUMBER ||
    pattern === inputMethodEngine.PATTERN_PHONE ||
    pattern === inputMethodEngine.PATTERN_NUMBER_DECIMAL ||
    pattern === inputMethodEngine.PATTERN_PASSWORD_NUMBER;
}

export function isLatinPattern(pattern: number): boolean {
  return pattern === inputMethodEngine.PATTERN_EMAIL ||
    pattern === inputMethodEngine.PATTERN_URI ||
    pattern === inputMethodEngine.PATTERN_USER_NAME ||
    pattern === inputMethodEngine.PATTERN_ONE_TIME_CODE ||
    isPasswordPattern(pattern);
}

export function enterLabel(enterKeyType: number): string {
  switch (enterKeyType) {
    case inputMethodEngine.ENTER_KEY_TYPE_GO:
      return '前往';
    case inputMethodEngine.ENTER_KEY_TYPE_SEARCH:
      return '搜索';
    case inputMethodEngine.ENTER_KEY_TYPE_SEND:
      return '发送';
    case inputMethodEngine.ENTER_KEY_TYPE_NEXT:
      return '下一项';
    case inputMethodEngine.ENTER_KEY_TYPE_DONE:
      return '完成';
    case inputMethodEngine.ENTER_KEY_TYPE_PREVIOUS:
      return '上一项';
    case inputMethodEngine.ENTER_KEY_TYPE_NEWLINE:
      return '换行';
    default:
      return '回车';
  }
}

function isActionEnter(enterKeyType: number): boolean {
  return enterKeyType === inputMethodEngine.ENTER_KEY_TYPE_GO ||
    enterKeyType === inputMethodEngine.ENTER_KEY_TYPE_SEARCH ||
    enterKeyType === inputMethodEngine.ENTER_KEY_TYPE_SEND ||
    enterKeyType === inputMethodEngine.ENTER_KEY_TYPE_NEXT ||
    enterKeyType === inputMethodEngine.ENTER_KEY_TYPE_DONE ||
    enterKeyType === inputMethodEngine.ENTER_KEY_TYPE_PREVIOUS;
}

/**
 * 输入法总控：事件注册、会话管理、按键动作分发与组词提交。
 */
export class ImeController {
  private static instance: ImeController | undefined = undefined;

  readonly state: ImeState = ImeState.get();
  private context: InputMethodExtensionContext | undefined = undefined;
  private readonly panelController: PanelController = new PanelController();
  private readonly editor: EditorAdapter = new EditorAdapter();
  private readonly composition: CompositionController = new CompositionController();
  // 相邻两次确认的组合学习：只判断能不能连，记录与提示在 UserLexicon 里
  private readonly continuation: ContinuationTracker = new ContinuationTracker();
  private readonly layoutStore: LayoutStore = new LayoutStore();
  private readonly clipboard: ClipboardService = new ClipboardService();
  private keyboardController: inputMethodEngine.KeyboardController | undefined = undefined;
  private inputStartTime: number = 0;
  // 布局校准拖动键盘高度时调整面板窗口的节流状态
  private heightPreviewTimer: number = -1;
  private heightPreviewPending: boolean = false;
  private learner: CommitLearner | undefined = undefined;
  private rules: CandidateRules | undefined = undefined;
  // 长按菜单要对同一版候选生效，打开时保存这一份快照，候选刷新后随菜单一起失效
  private menuView: CandidateView | undefined = undefined;
  private removedTimer: number = -1;
  private readonly rawCandidateProvider: CandidateProvider = new RawCandidateProvider();
  private sessionCounter: number = 0;
  private preferredLang: InputLang = InputLang.ZH;
  private lastShiftTap: number = 0;
  private deleteDelayTimer: number = -1;
  private deleteRepeatTimer: number = -1;
  private committedTail: string = '';
  // 上下文代次与当前上下文的提交者：异步提交失败时，只有代次没前进、且上下文仍属于这次提交才能回退
  private contextGeneration: number = 0;
  private contextOwner: number = 0;
  private commitSequence: number = 0;
  private registered: boolean = false;
  // 编辑框推送的最新全文，只持有引用；密码框与超长文本不保存
  private editorText: string = '';
  // 删除键按下时的全文与组词快照，抬起时释放
  private pressText: string = '';
  private pressComposition: CompositionSnapshot | undefined = undefined;
  // 按住的删除键触点，以及这次按住期间是否已经连续删除过
  private deleteTrack: TouchTrack | undefined = undefined;
  private deleteRepeated: boolean = false;
  // 这次按住已经开始上滑，以及是否到达过清空的触发线
  private deleteSwiping: boolean = false;
  private deleteSwipeReached: boolean = false;
  private clearUndo: ClearUndo | undefined = undefined;
  // 滑动选字的预上屏：同一时间只执行一次，执行期间的新选择合并为最后一次。关闭选字界面时代次加一，旧回调随之失效
  private pickGeneration: number = 0;
  private pickPreviewBusy: boolean = false;
  private pickPreviewDirty: boolean = false;
  private pickPreviewLength: number = 0;
  private pickPreviewUnsupported: boolean = false;
  // 横向滑动移动光标：尚未发送的净移动字数，以及是否正在逐个发送
  private cursorPending: number = 0;
  private cursorBusy: boolean = false;

  static get(): ImeController {
    if (ImeController.instance === undefined) {
      ImeController.instance = new ImeController();
    }
    return ImeController.instance;
  }

  // ---------- 生命周期 ----------

  private onInputStart = (kbController: inputMethodEngine.KeyboardController,
    client: inputMethodEngine.InputClient): void => {
    this.sessionCounter++;
    const sessionId = this.sessionCounter;
    this.inputStartTime = Date.now();
    this.keyboardController = kbController;
    this.editor.bind(client, sessionId);
    this.stopDeleteRepeat();
    this.releaseEditorText();
    this.composition.reset();
    this.setContext('');
    // 换编辑框以后两次确认不可能再相邻
    this.continuation.reset();
    // 预上屏属于上一个编辑框，新会话只复位选字状态
    this.resetPick();
    this.resetCursor();
    this.state.clipActionIndex = -1;
    this.state.panelMode = PanelMode.KEYBOARD;
    this.state.candidatesExpanded = false;
    this.syncComposition();
    this.refreshClipboardGrant();
    client.getEditorAttribute().then((attribute: inputMethodEngine.EditorAttribute) => {
      if (sessionId === this.editor.currentSession()) {
        Log.info(`editor session=${sessionId} pattern=${attribute.inputPattern} enter=${attribute.enterKeyType}`);
        this.applyEditorAttribute(attribute, true);
      }
    }).catch((error: BusinessError) => {
      Log.warn(`getEditorAttribute failed, code=${error.code}`);
    });
    Log.info(`inputStart session=${sessionId}`);
  };

  // 结束事件不携带会话信息，安卓兼容环境里它可能晚于下一次开始事件到达。
  // 这里保留客户端与键盘控制器，下一次开始事件到来时自然替换，详见 EditorAdapter.markStopped
  private onInputStop = (): void => {
    const sessionId = this.editor.currentSession();
    this.stopDeleteRepeat();
    this.releaseEditorText();
    this.resetPick();
    this.resetCursor();
    this.composition.reset();
    this.syncComposition();
    this.continuation.reset();
    this.editor.markStopped(sessionId);
    this.learner?.flush();
    Log.info(`inputStop session=${sessionId} sinceStart=${Date.now() - this.inputStartTime}ms`);
  };

  private onKeyboardHide = (): void => {
    this.stopDeleteRepeat();
    this.releaseEditorText();
    this.state.pressedKeyIds = [];
    this.clearFlick();
    this.resetCursor();
    if (this.composition.isComposing()) {
      this.composition.reset();
      this.syncComposition();
    }
    this.cancelPick();
    this.state.clipActionIndex = -1;
    this.state.panelMode = PanelMode.KEYBOARD;
    this.closeCandidateMenu();
    this.dismissRemovedNotice();
    this.continuation.reset();
    this.learner?.flush();
  };

  private onSetSubtype = (subtype: InputMethodSubtype): void => {
    const lang = subtype.id === 'en_qwerty' ? InputLang.EN : InputLang.ZH;
    this.preferredLang = lang;
    this.continuation.break();
    if (!isLatinPattern(this.state.inputPattern)) {
      this.switchLang(lang);
    }
  };

  private onEditorAttributeChanged = (attribute: inputMethodEngine.EditorAttribute): void => {
    this.applyEditorAttribute(attribute, false);
  };

  private onSecurityModeChange = (mode: inputMethodEngine.SecurityMode): void => {
    Log.info(`securityMode=${mode}`);
  };

  // 系统输入框在光标或内容变化时推送全文，这里只替换引用，旧字符串随之可被回收。
  // 组合学习只按长度核对自己有没有在别处被改动，不保存也不转发这里的文字
  private onTextChange = (text: string): void => {
    this.editorText = text.length <= CLEAR_TEXT_LIMIT * 2 && !isPasswordPattern(this.state.inputPattern) ? text : '';
    this.continuation.noteTextLength(text.length);
  };

  // 选区的变化同样不含文字。自己的插入让光标往后走，其它移动说明两次确认不再紧挨着同一处
  private onSelectionChange = (oldBegin: number, oldEnd: number, newBegin: number, newEnd: number): void => {
    this.continuation.noteSelection(oldBegin, oldEnd, newBegin, newEnd);
  };

  /**
   * 会话开始、结束、收起键盘与销毁时释放所有与编辑框文字有关的内存，撤销按钮随之消失。
   */
  private releaseEditorText(): void {
    this.editorText = '';
    this.pressText = '';
    this.pressComposition = undefined;
    this.dismissUndo();
  }

  onCreate(context: InputMethodExtensionContext): void {
    this.context = context;
    this.layoutStore.init(context);
    this.state.landscapeProfile = this.layoutStore.loadProfile(ProfileOrientation.LANDSCAPE);
    this.state.portraitProfile = this.layoutStore.loadProfile(ProfileOrientation.PORTRAIT);
    // 词频学习与剪贴板收录不再提供开关，始终开启
    this.state.learningEnabled = true;
    this.state.toolbarEmoji = this.layoutStore.loadFlag(KEY_TOOLBAR_EMOJI, true);
    this.state.toolbarClipboard = this.layoutStore.loadFlag(KEY_TOOLBAR_CLIPBOARD, true);
    this.state.clipboardEnabled = true;
    this.state.fuzzyPinyin = this.layoutStore.loadFlag(KEY_FUZZY_PINYIN, false);
    this.composition.setFuzzy(this.state.fuzzyPinyin);
    this.state.candidateSize = this.validCandidateSize(this.layoutStore.loadNumber(KEY_CANDIDATE_SIZE,
      CandidateSize.SMALL));
    this.state.clipboardItems = this.layoutStore.loadList(KEY_CLIPBOARD_ITEMS).slice(0, CLIPBOARD_LIMIT);
    this.state.phraseItems = this.layoutStore.loadList(KEY_PHRASE_ITEMS).slice(0, PHRASE_LIMIT);
    this.state.recentEmoji = this.layoutStore.loadList(KEY_RECENT_EMOJI).slice(0, RECENT_EMOJI_LIMIT);
    this.clipboard.init(context, () => this.state.clipboardEnabled,
      (text: string, fresh: boolean) => this.onClipboardText(text, fresh));
    this.refreshClipboardGrant();
    this.state.isLandscape = this.panelController.detectLandscape();
    this.registerListeners();
    this.panelController.setGeometryListener(() => this.updateProbe());
    this.panelController.applyHeights(this.state.landscapeProfile.keyboardHeightVp,
      this.state.portraitProfile.keyboardHeightVp);
    this.panelController.create(context);
    try {
      Log.info(`securityMode=${inputMethodEngine.getInputMethodAbility().getSecurityMode()}`);
    } catch (error) {
      Log.warn(`getSecurityMode failed, code=${(error as BusinessError).code}`);
    }
  }

  onDestroy(): void {
    this.stopDeleteRepeat();
    this.releaseEditorText();
    this.resetPick();
    this.unregisterListeners();
    this.learner?.flush();
    this.clipboard.destroy();
    this.editor.unbind(this.editor.currentSession());
    this.panelController.destroy();
    this.context = undefined;
  }

  getContext(): InputMethodExtensionContext | undefined {
    return this.context;
  }

  private registerListeners(): void {
    if (this.registered) {
      return;
    }
    const ability = inputMethodEngine.getInputMethodAbility();
    ability.on('inputStart', this.onInputStart);
    ability.on('inputStop', this.onInputStop);
    ability.on('keyboardHide', this.onKeyboardHide);
    ability.on('setSubtype', this.onSetSubtype);
    ability.on('securityModeChange', this.onSecurityModeChange);
    inputMethodEngine.getKeyboardDelegate().on('editorAttributeChanged', this.onEditorAttributeChanged);
    inputMethodEngine.getKeyboardDelegate().on('textChange', this.onTextChange);
    inputMethodEngine.getKeyboardDelegate().on('selectionChange', this.onSelectionChange);
    this.registered = true;
  }

  private unregisterListeners(): void {
    if (!this.registered) {
      return;
    }
    const ability = inputMethodEngine.getInputMethodAbility();
    ability.off('inputStart', this.onInputStart);
    ability.off('inputStop', this.onInputStop);
    ability.off('keyboardHide', this.onKeyboardHide);
    ability.off('setSubtype', this.onSetSubtype);
    ability.off('securityModeChange', this.onSecurityModeChange);
    inputMethodEngine.getKeyboardDelegate().off('editorAttributeChanged', this.onEditorAttributeChanged);
    inputMethodEngine.getKeyboardDelegate().off('textChange', this.onTextChange);
    inputMethodEngine.getKeyboardDelegate().off('selectionChange', this.onSelectionChange);
    this.registered = false;
  }

  private applyEditorAttribute(attribute: inputMethodEngine.EditorAttribute, isNewSession: boolean): void {
    this.state.enterKeyType = attribute.enterKeyType;
    const patternChanged = this.state.inputPattern !== attribute.inputPattern;
    this.state.inputPattern = attribute.inputPattern;
    if (isNewSession || patternChanged) {
      // 换了输入框类型或进入密码框，之前的两次确认不再相邻
      this.continuation.break();
    }
    if (!isNewSession && !patternChanged) {
      return;
    }
    this.switchLang(isLatinPattern(attribute.inputPattern) ? InputLang.EN : this.preferredLang);
    if (isNumberPattern(attribute.inputPattern)) {
      this.state.page = KeyboardPageType.NUMBERS;
    } else if (isNewSession) {
      this.state.page = KeyboardPageType.LETTERS;
    }
    if (isPasswordPattern(attribute.inputPattern)) {
      this.state.shift = ShiftState.OFF;
    }
  }

  // ---------- 引擎与学习 ----------

  setCandidateProvider(provider: CandidateProvider, status: LexiconStatus): void {
    this.composition.setProvider(provider);
    this.state.lexiconStatus = status;
    this.syncComposition();
  }

  setLearner(learner: CommitLearner | undefined, rules: CandidateRules | undefined): void {
    this.learner = learner;
    this.rules = rules;
    this.composition.setRules(rules);
    this.syncComposition();
  }

  rawProvider(): CandidateProvider {
    return this.rawCandidateProvider;
  }

  // ---------- 长按候选 ----------

  /**
   * 长按候选弹出菜单，可以把它固定在这串拼音的首位，或者删除。原文候选与词库没加载好时不弹出。
   * view 是长按时候选栏或自由选词捕获的那一版候选，菜单后续操作只认这一版。
   */
  openCandidateMenu(view: CandidateView, anchor: CandidateAnchor): void {
    const rules = this.rules;
    const candidate = this.composition.matchCandidate(view);
    if (rules === undefined || candidate === undefined || candidate.syllables.length === 0) {
      return;
    }
    const code = this.composition.consumedCodeFor(view);
    if (code.length === 0) {
      return;
    }
    this.dismissRemovedNotice();
    this.menuView = view;
    this.state.menuAnchor = anchor;
    this.state.menuPinned = rules.isPinned(code, candidate.text);
    this.state.menuIndex = view.index;
  }

  // 候选刷新时一并调用，旧菜单和它指向的那一版候选一起失效
  closeCandidateMenu(): void {
    this.menuView = undefined;
    if (this.state.menuIndex !== -1) {
      this.state.menuIndex = -1;
    }
  }

  // 固定以后候选栏回到第一页，用户能马上看到它排到了首位
  togglePinCandidate(): void {
    const view = this.menuView;
    this.closeCandidateMenu();
    const rules = this.rules;
    if (view === undefined || rules === undefined) {
      return;
    }
    const candidate = this.composition.matchCandidate(view);
    if (candidate === undefined) {
      return;
    }
    const code = this.composition.consumedCodeFor(view);
    if (code.length === 0) {
      return;
    }
    if (rules.isPinned(code, candidate.text)) {
      rules.unpin(code);
    } else {
      rules.pin(code, candidate.syllables, candidate.text);
    }
    this.composition.refresh();
    this.syncComposition();
  }

  removeCandidate(): void {
    const view = this.menuView;
    this.closeCandidateMenu();
    const rules = this.rules;
    if (view === undefined || rules === undefined) {
      return;
    }
    const candidate = this.composition.matchCandidate(view);
    if (candidate === undefined) {
      return;
    }
    rules.remove(candidate.syllables, candidate.text);
    this.composition.refresh();
    this.syncComposition();
    this.showRemovedNotice(candidate.text);
  }

  undoRemoveCandidate(): void {
    const rules = this.rules;
    this.dismissRemovedNotice();
    if (rules !== undefined && rules.restoreRemoved()) {
      this.composition.refresh();
      this.syncComposition();
    }
  }

  // 撤销提示贴在原来的候选旁边，几秒后或按下任意键时消失
  private showRemovedNotice(word: string): void {
    this.clearRemovedTimer();
    this.state.removedWord = word;
    this.removedTimer = setTimeout(() => {
      this.removedTimer = -1;
      this.state.removedWord = '';
    }, REMOVED_NOTICE_MS);
  }

  dismissRemovedNotice(): void {
    this.clearRemovedTimer();
    if (this.state.removedWord.length > 0) {
      this.state.removedWord = '';
    }
  }

  private clearRemovedTimer(): void {
    if (this.removedTimer !== -1) {
      clearTimeout(this.removedTimer);
      this.removedTimer = -1;
    }
  }

  // 候选栏左右滑动翻页，页数由候选栏按宽度排布后决定
  setCandidatePage(page: number): void {
    const next = Math.max(0, page);
    this.state.candidatePageMotion = next > this.state.candidatePage ? 1 : -1;
    this.state.candidatePage = next;
  }

  private showStatus(message: string): void {
    this.state.statusMessage = message;
    setTimeout(() => {
      if (this.state.statusMessage === message) {
        this.state.statusMessage = '';
      }
    }, 2000);
  }

  clearLearning(): void {
    this.learner?.clear();
    TouchModel.get().clear();
    this.continuation.reset();
    this.composition.refresh();
    this.syncComposition();
    this.showStatus('学习数据已清除');
  }

  // ---------- 按键动作 ----------

  onKeyDown(track: TouchTrack): void {
    const key = track.rect.key;
    this.dismissRemovedNotice();
    this.state.pressedKeyIds = this.state.pressedKeyIds.concat([key.id]);
    if (key.type === KeyType.DELETE) {
      // 删除键在松手时才执行，按下时只记下全文与组词快照，上滑清空时据此保存撤销内容
      this.pressText = this.editorText;
      this.pressComposition = this.composition.isComposing() ? this.composition.snapshot() : undefined;
      this.deleteTrack = track;
      this.deleteRepeated = false;
      this.deleteSwiping = false;
      this.deleteSwipeReached = false;
      this.startDeleteRepeat();
    }
  }

  onKeyRelease(track: TouchTrack): void {
    const key = track.rect.key;
    if (track.cursorMode) {
      this.endCursorMode();
    }
    const index = this.state.pressedKeyIds.indexOf(key.id);
    if (index >= 0) {
      const next = this.state.pressedKeyIds.slice();
      next.splice(index, 1);
      this.state.pressedKeyIds = next;
    }
    if (this.state.flickKeyId === key.id) {
      this.clearFlick();
    }
    if (key.type === KeyType.DELETE) {
      this.stopDeleteRepeat();
      this.pressText = '';
      this.pressComposition = undefined;
      this.deleteTrack = undefined;
      this.deleteSwiping = false;
      this.deleteSwipeReached = false;
    }
  }

  /**
   * 横向滑动移动光标。进入光标模式时收起按下与上滑的效果，之后把每次换算出的字数交给编辑框。
   */
  onCursorSwipe(track: TouchTrack): void {
    // 移动光标以后两次确认不再落在同一处
    this.continuation.break();
    if (!this.state.cursorMode) {
      this.state.cursorMode = true;
      this.clearFlick();
      this.state.pressedKeyIds = [];
    }
    if (track.cursorSteps !== 0) {
      this.cursorPending += track.cursorSteps;
      track.cursorSteps = 0;
      if (!this.cursorBusy) {
        this.drainCursor();
      }
    }
  }

  endCursorMode(): void {
    if (this.state.cursorMode) {
      this.state.cursorMode = false;
    }
  }

  // 换输入框或收起键盘时丢弃尚未发送的移动，正在发送的那一次由编辑队列按会话丢弃
  private resetCursor(): void {
    this.cursorPending = 0;
    this.endCursorMode();
  }

  /**
   * 编辑框一次只移动一个字，这里逐个发送，前一次完成后再发下一次。
   * 手指来回移动时只累计净移动量，不会积压已经过时的移动。
   * 光标停在行首或行尾时，同方向剩余的移动全部丢弃，手指往回滑时光标立即反向移动。
   */
  private drainCursor(): void {
    if (this.cursorPending === 0) {
      this.cursorBusy = false;
      return;
    }
    this.cursorBusy = true;
    const right = this.cursorPending > 0;
    this.cursorPending += right ? -1 : 1;
    this.editor.moveCursorInLine(right).then((moved: boolean) => {
      if (!moved && (right ? this.cursorPending > 0 : this.cursorPending < 0)) {
        this.cursorPending = 0;
      }
      this.drainCursor();
    });
  }

  onSwipeChanged(track: TouchTrack): void {
    if (track === this.deleteTrack && !track.cancelled) {
      this.noteDeleteSwipe(track);
    }
    if (track.cancelled || track.progress <= 0) {
      if (this.state.flickKeyId === track.rect.key.id) {
        this.clearFlick();
      }
      return;
    }
    this.state.flickKeyId = track.rect.key.id;
    this.state.flickProgress = track.progress;
    this.state.flickCommitted = track.swipeUp;
  }

  clearFlick(): void {
    this.state.flickKeyId = '';
    this.state.flickProgress = 0;
    this.state.flickCommitted = false;
  }

  /**
   * alternatives 为字母键落点附近的其他字母，中文组词时交给引擎纠错。
   * tap 为这次落点相对按键中心的位置，提交成功后用来学习按键偏移。
   */
  onKeyPress(key: KeyDef, swipeUp: boolean, alternatives: LetterAlternative[] = [], tap: TapSample = NO_TAP): void {
    switch (key.type) {
      case KeyType.LETTER:
        if (swipeUp && hasSwipeUp(key)) {
          this.commitBestIfComposing();
          this.insert(resolveSwipeUp(key, this.usesChineseSymbols()));
        } else {
          this.inputLetter(key.output, alternatives, tap);
        }
        break;
      case KeyType.CHAR:
        this.inputChar(resolveOutput(key, this.usesChineseSymbols()));
        break;
      case KeyType.SPACE:
        this.inputSpace();
        break;
      case KeyType.PUNCT:
        this.inputPunct(key, swipeUp);
        break;
      case KeyType.ENTER:
        this.inputEnter();
        break;
      case KeyType.DELETE:
        this.releaseDelete(swipeUp);
        break;
      case KeyType.SHIFT:
        if (this.isSeparatorMode()) {
          this.composition.appendSeparator();
          this.syncComposition();
        } else {
          this.toggleShift();
        }
        break;
      case KeyType.LANG:
        this.toggleLang();
        break;
      case KeyType.SYMBOL_PAGE:
        this.switchPage(KeyboardPageType.SYMBOLS);
        break;
      case KeyType.NUMBER_PAGE:
        this.switchPage(KeyboardPageType.NUMBERS);
        break;
      case KeyType.LETTER_PAGE:
        this.switchPage(KeyboardPageType.LETTERS);
        break;
      case KeyType.SYMBOL_LOCK:
        this.toggleSymbolLock();
        break;
      default:
        break;
    }
  }

  /**
   * 中文组词期间大写键变为分词键。
   */
  isSeparatorMode(): boolean {
    return this.usesComposition() && this.composition.isComposing();
  }

  private usesComposition(): boolean {
    return this.state.lang === InputLang.ZH && this.state.page === KeyboardPageType.LETTERS &&
      !isPasswordPattern(this.state.inputPattern);
  }

  private inputLetter(letter: string, alternatives: LetterAlternative[], tap: TapSample): void {
    const upper = this.state.shift !== ShiftState.OFF;
    const text = upper ? letter.toUpperCase() : letter;
    if (this.usesComposition() && (!upper || this.composition.isComposing())) {
      this.dismissUndo();
      const startTime = Date.now();
      this.composition.appendCode(text, upper ? [] : alternatives, upper ? NO_TAP : tap);
      this.syncComposition();
      const elapsed = Date.now() - startTime;
      if (elapsed >= SLOW_COMPOSE_MS) {
        Log.warn(`compose slow length=${this.composition.getRawCode().length} ms=${elapsed}`);
      }
    } else {
      this.insert(text);
    }
    if (this.state.shift === ShiftState.ONCE) {
      this.state.shift = ShiftState.OFF;
    }
  }

  private inputChar(text: string): void {
    this.commitBestIfComposing();
    this.insert(text);
    if (this.state.page === KeyboardPageType.SYMBOLS && !this.state.symbolLocked) {
      this.state.page = KeyboardPageType.LETTERS;
    }
  }

  private inputSpace(): void {
    if (this.composition.isComposing()) {
      this.finishCommit(this.composition.selectFirst());
      return;
    }
    this.insert(' ');
  }

  /**
   * 中文状态输出中文标点，英文状态与密码框输出英文符号。
   */
  usesChineseSymbols(): boolean {
    return this.state.lang === InputLang.ZH && !isPasswordPattern(this.state.inputPattern);
  }

  private inputPunct(key: KeyDef, swipeUp: boolean): void {
    const zh = this.usesChineseSymbols();
    const text = swipeUp ? resolveSwipeUp(key, zh) : resolveOutput(key, zh);
    this.commitBestIfComposing();
    this.insert(text);
  }

  private inputEnter(): void {
    if (this.composition.isComposing()) {
      this.finishCommit(this.composition.commitRaw());
      return;
    }
    const enterKeyType = this.state.enterKeyType;
    if (isActionEnter(enterKeyType)) {
      this.dismissUndo();
      // 发送、搜索等动作键会把焦点交出去，两次确认不可能再相邻
      this.continuation.break();
      this.editor.sendKeyFunction(enterKeyType);
    } else {
      this.insert('\n');
    }
  }

  private toggleShift(): void {
    const now = Date.now();
    if (this.state.shift === ShiftState.LOCKED) {
      this.state.shift = ShiftState.OFF;
    } else if (now - this.lastShiftTap <= DOUBLE_TAP_MS) {
      this.state.shift = ShiftState.LOCKED;
    } else {
      this.state.shift = this.state.shift === ShiftState.ONCE ? ShiftState.OFF : ShiftState.ONCE;
    }
    this.lastShiftTap = now;
  }

  private toggleLang(): void {
    const next = this.state.lang === InputLang.ZH ? InputLang.EN : InputLang.ZH;
    if (!isLatinPattern(this.state.inputPattern)) {
      this.preferredLang = next;
    }
    this.switchLang(next);
  }

  private switchLang(lang: InputLang): void {
    if (this.state.lang === lang) {
      return;
    }
    this.continuation.break();
    if (this.composition.isComposing()) {
      this.finishCommit(this.composition.commitRaw());
    }
    this.state.lang = lang;
  }

  switchPage(page: KeyboardPageType): void {
    if (page !== KeyboardPageType.LETTERS) {
      this.commitBestIfComposing();
    }
    // 打开符号页时默认显示与当前语言一致的分类：中文状态为中文标点，英文状态为英文符号
    if (page === KeyboardPageType.SYMBOLS && this.state.page !== KeyboardPageType.SYMBOLS) {
      this.state.symbolCategory = this.usesChineseSymbols() ? SYMBOL_CATEGORY_ZH : SYMBOL_CATEGORY_EN;
    }
    this.state.page = page;
    this.state.candidatesExpanded = false;
  }

  selectSymbolCategory(index: number): void {
    this.state.symbolCategory = index;
  }

  toggleSymbolLock(): void {
    this.state.symbolLocked = !this.state.symbolLocked;
  }

  /**
   * 点按候选栏或自由选词里的候选。view 来自渲染时捕获，已经过期时什么都不做，也不重刷候选。
   */
  selectCandidate(view: CandidateView): void {
    const selection = this.composition.selectCandidate(view);
    if (!selection.accepted) {
      return;
    }
    const result = selection.result;
    if (result !== undefined) {
      this.state.candidatesExpanded = false;
      this.finishCommit(result);
    } else {
      this.syncComposition();
    }
  }

  /**
   * 右上角圆形按钮：组词时开关自由选词界面，空闲时收起键盘。
   */
  onCircleButton(): void {
    if (this.composition.isComposing()) {
      this.state.candidatesExpanded = !this.state.candidatesExpanded;
      if (this.state.candidatesExpanded) {
        this.state.candidateFilter = CandidateFilter.ALL;
      } else if (this.composition.getActiveSyllable().length > 0) {
        this.composition.setSyllableFilter('', 0);
        this.syncComposition();
      }
      return;
    }
    this.hideKeyboard();
  }

  /**
   * 筛选只保留当前候选里确实有结果的那一类。选中没有结果的类时直接留在“全部”，
   * 避免高亮停在一类空列表上；候选刷新后由 syncComposition 再做同样的回退。
   */
  setCandidateFilter(filter: CandidateFilter): void {
    this.state.candidateFilter = this.allowedFilter(filter);
  }

  /**
   * 切换自由选词左侧的拼音筛选；再次点击已选中的音节则取消筛选并恢复全部候选。
   */
  togglePinyinFilter(syllable: string): void {
    if (!this.composition.isComposing() || syllable.length === 0) {
      return;
    }
    if (this.state.selectedPinyin === syllable) {
      this.composition.setSyllableFilter('', 0);
    } else {
      const consumed = consumedForSyllable(this.composition.getRawCode(), syllable, this.composition.isFuzzy());
      this.composition.setSyllableFilter(syllable, consumed);
    }
    this.syncComposition();
  }

  // 筛选只保留当前候选里确实有结果的那一类，空列表直接回到“全部”，不会留下空白页
  private allowedFilter(filter: CandidateFilter): CandidateFilter {
    if (filter === CandidateFilter.WORDS) {
      return this.state.candidatesWords.length > 0 ? CandidateFilter.WORDS : CandidateFilter.ALL;
    }
    if (filter === CandidateFilter.CHARS) {
      return this.state.candidatesChars.length > 0 ? CandidateFilter.CHARS : CandidateFilter.ALL;
    }
    return CandidateFilter.ALL;
  }

  deleteInFreeSelect(): void {
    this.performDelete();
  }

  // 自由选词界面的原文：已选的汉字照常上屏，剩下的拼音按原样的字母上屏，与切换中英文时的做法一致
  commitLettersInFreeSelect(): void {
    if (!this.composition.isComposing()) {
      return;
    }
    this.state.candidatesExpanded = false;
    this.finishCommit(this.composition.commitRaw());
  }

  /**
   * 自由选词界面的重输：清空拼音和已选的汉字，回到键盘。顶部栏随后显示撤销清空，与上滑删除键清空拼音一样。
   */
  retypeInFreeSelect(): void {
    if (!this.composition.isComposing()) {
      return;
    }
    const snapshot = this.composition.snapshot();
    this.composition.reset();
    this.state.candidatesExpanded = false;
    this.syncComposition();
    // 组词作废，之前那次确认不再与后面的输入相邻
    this.continuation.break();
    this.setUndo({ session: this.editor.currentSession(), text: '', caret: 0, composition: snapshot });
  }

  hideKeyboard(): void {
    const controller = this.keyboardController;
    if (controller === undefined) {
      return;
    }
    controller.hide().catch((error: BusinessError) => {
      Log.warn(`hide keyboard failed, code=${error.code}`);
    });
  }

  private performDelete(): void {
    this.continuation.break();
    if (this.composition.isComposing()) {
      this.composition.backspace();
      this.syncComposition();
      return;
    }
    this.continuation.noteOwnDelete(1);
    this.editor.deleteBeforeCursor(1);
    this.setContext('');
  }

  /**
   * 删除键上滑。按下时正在输入拼音，就只清空拼音与候选，编辑框保持不动；否则清空编辑框中光标前后的全部文字。
   */
  private clearAll(): void {
    this.stopDeleteRepeat();
    this.continuation.reset();
    const session = this.editor.currentSession();
    const pressComposition = this.pressComposition;
    const pressText = this.pressText;
    this.pressComposition = undefined;
    this.pressText = '';
    if (pressComposition !== undefined) {
      this.composition.reset();
      this.state.candidatesExpanded = false;
      this.syncComposition();
      this.setUndo({ session: session, text: '', caret: 0, composition: pressComposition });
      return;
    }
    this.editor.clearText(pressText).then((result: ClearResult) => {
      if (session !== this.editor.currentSession()) {
        return;
      }
      if (result.status === ClearStatus.CLEARED && result.text.length > 0) {
        this.setUndo({ session: session, text: result.text, caret: result.caret, composition: undefined });
      } else if (result.status === ClearStatus.TOO_LONG) {
        this.showStatus('文字太长，为防止丢失没有清空');
      }
    });
    this.setContext('');
  }

  // 只保留最近一次清空的内容，新的撤销内容直接替换旧的引用
  private setUndo(undo: ClearUndo): void {
    this.clearUndo = undo;
    this.state.clearUndoAvailable = true;
  }

  /**
   * 输入新内容、会话变化或收起键盘时丢弃撤销内容。删除键不丢弃，空输入框上再次误触清空时仍可撤销上一次。
   */
  dismissUndo(): void {
    this.clearUndo = undefined;
    if (this.state.clearUndoAvailable) {
      this.state.clearUndoAvailable = false;
    }
  }

  undoClear(): void {
    const undo = this.clearUndo;
    this.dismissUndo();
    this.continuation.break();
    if (undo === undefined || undo.session !== this.editor.currentSession()) {
      return;
    }
    if (undo.composition !== undefined) {
      if (!this.composition.isComposing()) {
        this.composition.restore(undo.composition);
        this.syncComposition();
      }
      return;
    }
    this.editor.restoreText(undo.text, undo.caret).then((ok: boolean) => {
      if (!ok && undo.session === this.editor.currentSession()) {
        this.showStatus('输入框已有新内容，无法撤销');
      }
    });
  }

  /**
   * 删除键松手：上滑过阈值时清空，否则删除一个字符。按住期间已经连续删除过，松手时不再多删。
   */
  /**
   * 删除键松手：停在触发线以上时清空。上滑到过触发线又退回，说明手指在撤回清空，这次什么也不做；
   * 没有连续删除过的普通点按删除一个字。
   */
  private releaseDelete(swipeUp: boolean): void {
    if (swipeUp) {
      this.clearAll();
    } else if (!this.deleteRepeated && !this.deleteSwipeReached) {
      this.performDelete();
    }
  }

  // 一旦开始上滑，连续删除立即停下，这次按住期间不再恢复，手指回落到起点附近也一样
  private noteDeleteSwipe(track: TouchTrack): void {
    if (track.swipeUp) {
      this.deleteSwipeReached = true;
    }
    if (!this.deleteSwiping && (track.swipeUp || track.progress >= DELETE_SWIPE_START_PROGRESS)) {
      this.deleteSwiping = true;
      this.stopDeleteRepeat();
    }
  }

  // 按住删除键超过长按时间后连续删除，手指正在上滑时暂停，松手时再决定清空还是停止
  private startDeleteRepeat(): void {
    this.stopDeleteRepeat();
    this.deleteDelayTimer = setTimeout(() => {
      this.deleteDelayTimer = -1;
      this.repeatDelete();
      this.deleteRepeatTimer = setInterval(() => this.repeatDelete(), REPEAT_INTERVAL_MS);
    }, LONG_PRESS_MS);
  }

  private repeatDelete(): void {
    if (this.deleteSwiping) {
      return;
    }
    this.deleteRepeated = true;
    this.performDelete();
  }

  stopDeleteRepeat(): void {
    if (this.deleteDelayTimer !== -1) {
      clearTimeout(this.deleteDelayTimer);
      this.deleteDelayTimer = -1;
    }
    if (this.deleteRepeatTimer !== -1) {
      clearInterval(this.deleteRepeatTimer);
      this.deleteRepeatTimer = -1;
    }
  }

  // 输入标点、数字或切换页面时自动提交首选候选。这不算用户确认，按开发文档 12.4 节的约定不参与学习
  private commitBestIfComposing(): void {
    if (this.composition.isComposing()) {
      this.finishCommit(this.composition.commitBest(), false);
    }
  }

  private insert(text: string): void {
    this.dismissUndo();
    // 标点、空格、数字、英文、剪贴板与表情都不属于拼音确认，插进来就隔开了两次确认
    this.continuation.break();
    this.continuation.noteOwnInsert(text.length);
    this.editor.insertText(text);
    this.rememberCommitted(text, false);
  }

  /**
   * 组词状态先行复位，编辑框提交成功后产生学习事件。提交失败时只有仍停在这次提交的会话与组词版本上，
   * 才把上下文和这次结果恢复成可重试的片段；用户已经开始新的组词时不覆盖。
   * explicit 为 false 表示自动提交，用户没有确认候选，词频、按键偏移与组合续接都不学习。
   *
   * 相邻两次确认的组合学习要等编辑框真正回复成功：verified 只在真回复时置位，
   * 超时按已送达不算成功，失败时这次提交也不能连上后面，见 ContinuationTracker。
   */
  private finishCommit(result: CommitResult | undefined, explicit: boolean = true): void {
    if (result === undefined) {
      this.syncComposition();
      return;
    }
    this.dismissUndo();
    const sessionId = this.editor.currentSession();
    const previousText = this.committedTail;
    const contextGeneration = this.contextGeneration;
    const commitId = ++this.commitSequence;
    // 动作发起时间在按下候选或空格的那一刻取；等异步插入完成再算间隔就不准了
    const actionTime = Date.now();
    const learn = explicit && !result.raw && this.state.learningEnabled &&
      !isPasswordPattern(this.state.inputPattern);
    this.rememberCommitted(result.text, !result.raw, commitId);
    this.syncComposition();
    // 提交完成以后组词状态的版本；期间又按键会刷新候选，版本随之前进
    const revision = this.composition.getRevision();
    if (learn) {
      const start: ContinuationStart = {
        commitId: commitId,
        session: sessionId,
        generation: contextGeneration,
        actionTime: actionTime,
        // 中间只要有一段不能学习，这次提交整体不参与，见 continuableSegments
        segments: continuableSegments(result.segments, result.raw)
      };
      this.continuation.start(start);
    } else {
      // 自动提交、原文、密码框与关闭学习都不参与组合，已经记下的线索随之作废
      this.continuation.break();
    }
    this.continuation.noteOwnInsert(result.text.length);
    let verified = false;
    this.editor.insertText(result.text, () => {
      verified = true;
    }).then((ok: boolean) => {
      if (sessionId !== this.editor.currentSession()) {
        return;
      }
      if (ok) {
        if (learn) {
          // 先记词，再按回执把这一次与上一次连成一条续接：前一个词的记录这时一定已经存在
          this.learner?.learn(result, previousText);
          this.learnTaps(result);
          if (verified) {
            this.learnContinuation(commitId);
          }
        }
        return;
      }
      if (learn) {
        this.continuation.failed(commitId);
      } else {
        this.continuation.break();
      }
      // 这次提交之后又有别的上下文更新或回滚，说明上下文承诺已经换人，不能回退
      if (this.contextGeneration !== contextGeneration + 1 || this.contextOwner !== commitId) {
        return;
      }
      // 没有更新的上下文：先把上一句恢复成提交前的样子
      this.setContext(previousText);
      if (this.composition.isComposing()) {
        // 用户已经重新输入了拼音：只按正确上下文重算候选，保留正在输入的拼音与已选片段
        this.composition.refresh();
        this.syncComposition();
        return;
      }
      // 组词版本仍停在这次提交后的空状态时，才把整次结果放回可提交的片段
      if (this.composition.getRevision() !== revision) {
        return;
      }
      this.composition.restore({ rawCode: '', alternatives: [], taps: [], segments: result.segments });
      this.syncComposition();
    });
  }

  /**
   * 组合续接按实际成功顺序连接：序号正好接在上一次成功提交后面、上下文只前进一代、时间在窗口内，
   * 才把两段交给用户词库记成一条续接。上一次没有成功回执时，后面的提交不会跳过它去连更早的一次。
   */
  private learnContinuation(commitId: number): void {
    const pair = this.continuation.verified(commitId);
    if (pair !== undefined) {
      this.learner?.learnContinuation(pair.previous, pair.next);
    }
  }

  private learnTaps(result: CommitResult): void {
    const typings: ConfirmedTyping[] = [];
    for (const segment of result.segments) {
      // 学到的组合续接把整串拼音读完却只有一部分音节，按键落点对不上，不参与触点学习
      if (segment.source !== CandidateSource.RAW && segment.origin !== CandidateOrigin.CONTINUATION &&
        segment.syllables.length > 0) {
        const typing: ConfirmedTyping = { code: segment.code, syllables: segment.syllables, taps: segment.taps };
        typings.push(typing);
      }
    }
    TouchModel.get().learn(typings);
  }

  // 所有改变上一句上下文的路径都走这里，代次让异步提交失败能判断自己是否还是最新的一次上下文更新
  private setContext(text: string, owner: number = 0): void {
    this.contextGeneration++;
    this.contextOwner = owner;
    this.committedTail = text;
    this.composition.setPreviousText(text);
  }

  private rememberCommitted(text: string, isChinese: boolean, owner: number = 0): void {
    if (!isChinese) {
      this.setContext('', owner);
      return;
    }
    const tail = text.length > CONTEXT_TAIL_LENGTH ? text.substring(text.length - CONTEXT_TAIL_LENGTH) : text;
    this.setContext(tail, owner);
  }

  // 候选刷新以后回到第一页，菜单指向的旧版本也随之失效。
  // 同一批候选按普通栏、全部、词语、单字四份快照分别排好，界面只消费这里的顺序。
  private syncComposition(): void {
    this.state.preedit = this.composition.preeditText();
    this.state.preeditChosen = this.composition.chosenText();
    this.state.candidatePageMotion = 0;
    this.state.candidatePage = 0;
    this.closeCandidateMenu();
    const candidates = this.composition.getCandidates();
    const snapshot = this.composition.getSnapshot();
    const revision = this.composition.getRevision();
    const views: CandidateView[] = [];
    for (let i = 0; i < candidates.length; i++) {
      const chars = candidates[i].source === CandidateSource.RAW ? 0 : characterCount(candidates[i].text);
      const view: CandidateView = {
        index: i,
        text: candidates[i].text,
        chars: chars,
        id: candidates[i].id,
        consumedCodeLength: candidates[i].consumedCodeLength,
        revision: revision
      };
      views.push(view);
    }
    this.state.candidates = this.orderedViews(snapshot.bar, views);
    this.state.candidatesAll = this.orderedViews(snapshot.all, views);
    this.state.candidatesWords = this.orderedViews(snapshot.words, views);
    this.state.candidatesChars = this.orderedViews(snapshot.chars, views);
    this.state.selectedPinyin = this.composition.getActiveSyllable();
    const rawCode = this.composition.getRawCode();
    const nextOptions = rawCode.length > 0 ?
      extractPinyinOptions(rawCode, this.composition.getBaseCandidates(), this.composition.getBaseSnapshot().all,
        this.composition.isFuzzy()) : [];
    if (!this.sameStrings(this.state.pinyinOptions, nextOptions)) {
      this.state.pinyinOptions = nextOptions;
    }
    if (this.composition.getBaseCandidates().length === 0) {
      this.state.candidatesExpanded = false;
    } else if (this.state.candidatesExpanded && this.state.candidateFilter !== CandidateFilter.ALL) {
      // 例如先筛选“词语”再退格到只有单字：高亮和网格一起回到“全部”，不会留下空白列表
      this.state.candidateFilter = this.allowedFilter(this.state.candidateFilter);
    }
  }

  private sameStrings(a: string[], b: string[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }

  // 快照里的序号指回候选池，index 与 id 因此保持原样，显示位置由数组先后单独决定
  private orderedViews(order: number[], views: CandidateView[]): CandidateView[] {
    const result: CandidateView[] = [];
    for (const index of order) {
      if (index >= 0 && index < views.length) {
        result.push(views[index]);
      }
    }
    return result;
  }

  // ---------- 布局档案 ----------

  updateProfile(orientation: ProfileOrientation, profile: LayoutProfile): void {
    const copy = copyProfile(profile);
    if (orientation === ProfileOrientation.LANDSCAPE) {
      this.state.landscapeProfile = copy;
    } else {
      this.state.portraitProfile = copy;
    }
    this.layoutStore.saveProfile(orientation, copy);
    this.panelController.applyHeights(this.state.landscapeProfile.keyboardHeightVp,
      this.state.portraitProfile.keyboardHeightVp);
  }

  /**
   * 拖动滑块期间刷新预览，松手后再保存。键盘高度需要调整面板窗口，拖动时按固定间隔节流，
   * 间隔内的最后一次高度在间隔结束时补上，窗口尺寸始终跟上手指。
   */
  previewProfile(orientation: ProfileOrientation, profile: LayoutProfile): void {
    const copy = copyProfile(profile);
    const previous = orientation === ProfileOrientation.LANDSCAPE ? this.state.landscapeProfile :
      this.state.portraitProfile;
    const heightChanged = previous.keyboardHeightVp !== copy.keyboardHeightVp;
    if (orientation === ProfileOrientation.LANDSCAPE) {
      this.state.landscapeProfile = copy;
    } else {
      this.state.portraitProfile = copy;
    }
    if (!heightChanged) {
      return;
    }
    if (this.heightPreviewTimer !== -1) {
      this.heightPreviewPending = true;
      return;
    }
    this.applyPreviewHeights();
  }

  private applyPreviewHeights(): void {
    this.heightPreviewPending = false;
    this.panelController.applyHeights(this.state.landscapeProfile.keyboardHeightVp,
      this.state.portraitProfile.keyboardHeightVp);
    this.heightPreviewTimer = setTimeout(() => {
      this.heightPreviewTimer = -1;
      if (this.heightPreviewPending) {
        this.applyPreviewHeights();
      }
    }, HEIGHT_PREVIEW_INTERVAL_MS);
  }

  resetProfile(orientation: ProfileOrientation): void {
    this.updateProfile(orientation, defaultProfile(orientation));
  }

  toggleForm(): void {
    const orientation = this.state.currentOrientation();
    const profile = copyProfile(this.state.currentProfile());
    profile.form = profile.form === LayoutForm.SPLIT ? LayoutForm.NORMAL : LayoutForm.SPLIT;
    this.updateProfile(orientation, profile);
  }

  setPanelMode(mode: PanelMode): void {
    this.commitBestIfComposing();
    this.continuation.break();
    this.state.candidatesExpanded = false;
    if (mode !== PanelMode.CLIPBOARD) {
      this.cancelPick();
      this.state.clipActionIndex = -1;
    }
    this.state.panelMode = mode;
  }

  // ---------- 功能面板 ----------

  openSettings(): void {
    this.setPanelMode(PanelMode.SETTINGS);
  }

  setSettingsTab(tab: number): void {
    this.state.settingsTab = tab;
  }

  closePanel(): void {
    this.setPanelMode(PanelMode.KEYBOARD);
  }

  setToolbarEmoji(shown: boolean): void {
    this.state.toolbarEmoji = shown;
    this.layoutStore.saveFlag(KEY_TOOLBAR_EMOJI, shown);
  }

  setToolbarClipboard(shown: boolean): void {
    this.state.toolbarClipboard = shown;
    this.layoutStore.saveFlag(KEY_TOOLBAR_CLIPBOARD, shown);
  }

  setFuzzyPinyin(on: boolean): void {
    this.state.fuzzyPinyin = on;
    this.layoutStore.saveFlag(KEY_FUZZY_PINYIN, on);
    this.composition.setFuzzy(on);
    this.syncComposition();
  }

  setCandidateSize(size: number): void {
    const valid = this.validCandidateSize(size);
    this.state.candidateSize = valid;
    this.layoutStore.saveNumber(KEY_CANDIDATE_SIZE, valid);
  }

  // 保存的数值损坏或来自更新的版本时回到默认的小号
  private validCandidateSize(size: number): number {
    return size === CandidateSize.MEDIUM || size === CandidateSize.LARGE ? size : CandidateSize.SMALL;
  }

  // ---------- 表情 ----------

  openEmoji(): void {
    if (this.state.emojiCategory === 0 && this.state.recentEmoji.length === 0) {
      this.state.emojiCategory = 1;
    }
    this.setPanelMode(PanelMode.EMOJI);
  }

  selectEmojiCategory(index: number): void {
    this.state.emojiCategory = index;
  }

  insertEmoji(emoji: string): void {
    this.insert(emoji);
    const recent = this.state.recentEmoji.filter((item: string) => item !== emoji);
    recent.unshift(emoji);
    this.state.recentEmoji = recent.slice(0, RECENT_EMOJI_LIMIT);
    this.layoutStore.saveList(KEY_RECENT_EMOJI, this.state.recentEmoji);
  }

  /**
   * 表情与剪贴板面板中的删除按钮，删除光标前一个字符。
   */
  deleteInPanel(): void {
    this.performDelete();
  }

  // ---------- 剪贴板 ----------

  openClipboard(): void {
    this.refreshClipboardGrant();
    this.clipboard.captureNow();
    this.state.clipTab = ClipTab.CLIPBOARD;
    this.state.clipActionIndex = -1;
    this.setPanelMode(PanelMode.CLIPBOARD);
  }

  openPhrases(): void {
    this.state.clipTab = ClipTab.PHRASES;
    this.state.clipActionIndex = -1;
    this.setPanelMode(PanelMode.CLIPBOARD);
  }

  selectClipTab(tab: number): void {
    this.state.clipActionIndex = -1;
    this.state.clipTab = tab;
    if (tab === ClipTab.CLIPBOARD) {
      this.refreshClipboardGrant();
      this.clipboard.captureNow();
    }
  }

  refreshClipboardGrant(): void {
    this.state.clipboardGranted = this.clipboard.isGranted();
  }

  // 点按卡片：有卡片正在显示操作按钮时只收起按钮，否则输入这条文字
  tapClipItem(index: number): void {
    if (this.state.clipActionIndex >= 0) {
      this.state.clipActionIndex = -1;
      return;
    }
    const items = this.state.currentClipItems();
    if (index >= 0 && index < items.length) {
      // 在面板里用过刚复制的这段文字，候选栏不再重复显示
      if (items[index] === this.state.clipSuggestion) {
        this.state.clipSuggestion = '';
      }
      this.insert(items[index]);
    }
  }

  showClipActions(index: number): void {
    this.state.clipActionIndex = index;
  }

  // 点“取消”、点按空白处或滚动列表时收起操作按钮
  hideClipActions(): void {
    if (this.state.clipActionIndex >= 0) {
      this.state.clipActionIndex = -1;
    }
  }

  removeClipItem(index: number): void {
    this.state.clipActionIndex = -1;
    const items = this.state.currentClipItems();
    if (index < 0 || index >= items.length) {
      return;
    }
    const rest = items.slice();
    rest.splice(index, 1);
    if (this.state.clipTab === ClipTab.PHRASES) {
      this.savePhrases(rest);
    } else {
      this.saveClips(rest);
    }
  }

  clearClips(): void {
    this.state.clipActionIndex = -1;
    this.saveClips([]);
  }

  // ---------- 常用语 ----------

  addClipToPhrases(index: number): void {
    this.state.clipActionIndex = -1;
    if (index >= 0 && index < this.state.clipboardItems.length) {
      this.addPhrase(this.state.clipboardItems[index]);
    }
  }

  /**
   * 把输入框里的全部文字存为常用语。优先使用编辑框推送的全文，没有推送时读取光标两侧的文字。
   */
  addEditorTextToPhrases(): void {
    if (isPasswordPattern(this.state.inputPattern)) {
      this.showStatus('密码框里的文字不能存为常用语');
      return;
    }
    if (this.editorText.length > 0) {
      this.addPhrase(this.editorText);
      return;
    }
    const session = this.editor.currentSession();
    this.editor.readText(CLIPBOARD_TEXT_LIMIT + 1).then((text: string | undefined) => {
      if (session !== this.editor.currentSession()) {
        return;
      }
      if (text === undefined) {
        this.showStatus('文字太长，无法存为常用语');
        return;
      }
      this.addPhrase(text);
    });
  }

  private addPhrase(text: string): void {
    if (text.trim().length === 0) {
      this.showStatus('输入框里没有文字');
      return;
    }
    if (text.length > CLIPBOARD_TEXT_LIMIT) {
      this.showStatus('文字太长，无法存为常用语');
      return;
    }
    if (this.state.phraseItems.indexOf(text) >= 0) {
      this.showStatus('常用语里已经有这段文字');
      return;
    }
    if (this.state.phraseItems.length >= PHRASE_LIMIT) {
      this.showStatus(`常用语最多保存 ${PHRASE_LIMIT} 条`);
      return;
    }
    const items = this.state.phraseItems.slice();
    items.unshift(text);
    this.savePhrases(items);
    this.showStatus('已存为常用语');
  }

  private savePhrases(items: string[]): void {
    this.state.phraseItems = items;
    this.layoutStore.saveList(KEY_PHRASE_ITEMS, items);
  }

  // ---------- 滑动选字 ----------

  openPick(index: number): void {
    this.state.clipActionIndex = -1;
    const items = this.state.currentClipItems();
    if (index < 0 || index >= items.length) {
      return;
    }
    let text = items[index];
    if (text.length > PICK_TEXT_LIMIT) {
      const code = text.charCodeAt(PICK_TEXT_LIMIT - 1);
      text = text.substring(0, code >= 0xd800 && code <= 0xdbff ? PICK_TEXT_LIMIT - 1 : PICK_TEXT_LIMIT);
      this.showStatus(`文字较长，只显示前 ${PICK_TEXT_LIMIT} 字`);
    }
    this.resetPick();
    const tokens = splitPickTokens(text);
    const selected: boolean[] = [];
    for (let i = 0; i < tokens.length; i++) {
      selected.push(false);
    }
    this.state.pickSelected = selected;
    this.state.pickTokens = tokens;
  }

  setPickSelection(selected: boolean[]): void {
    if (!this.state.isPicking() || selected.length !== this.state.pickTokens.length) {
      return;
    }
    this.state.pickSelected = selected;
    this.updatePickPreview();
  }

  togglePickAll(): void {
    const all = this.state.pickSelected.every((item: boolean) => item);
    this.setPickSelection(this.state.pickTokens.map((): boolean => !all));
  }

  pickedText(): string {
    const tokens = this.state.pickTokens;
    const selected = this.state.pickSelected;
    let text = '';
    for (let i = 0; i < tokens.length; i++) {
      if (selected[i]) {
        text += tokens[i];
      }
    }
    return text;
  }

  /**
   * 选中的文字实时显示在编辑框的预上屏区域。编辑框不支持预上屏时不再尝试，点“输入”时直接插入。
   */
  private updatePickPreview(): void {
    if (this.pickPreviewUnsupported) {
      return;
    }
    if (this.pickPreviewBusy) {
      this.pickPreviewDirty = true;
      return;
    }
    const text = this.pickedText();
    if (text.length === 0 && this.pickPreviewLength === 0) {
      return;
    }
    const generation = this.pickGeneration;
    this.pickPreviewBusy = true;
    this.editor.setPreviewText(text).then((ok: boolean) => {
      if (generation !== this.pickGeneration) {
        return;
      }
      this.pickPreviewBusy = false;
      if (!ok) {
        this.pickPreviewUnsupported = true;
        return;
      }
      this.pickPreviewLength = text.length;
      if (this.pickPreviewDirty) {
        this.pickPreviewDirty = false;
        this.updatePickPreview();
      }
    });
  }

  /**
   * 输入选中的文字并回到列表。支持预上屏时把预上屏内容换成最终文字后结束预上屏，否则直接插入。
   */
  commitPick(): void {
    if (!this.state.isPicking()) {
      return;
    }
    const text = this.pickedText();
    const previewed = !this.pickPreviewUnsupported && (this.pickPreviewLength > 0 || this.pickPreviewBusy);
    const usePreview = !this.pickPreviewUnsupported;
    const previewLength = this.pickPreviewLength;
    this.resetPick();
    if (text.length === 0) {
      if (previewed) {
        this.clearPreview(previewLength);
      }
      return;
    }
    this.dismissUndo();
    this.continuation.break();
    this.continuePickInsert(text, usePreview, previewLength);
    this.rememberCommitted(text, false);
  }

  // 滑动选字上屏：预览内容是编辑框自己的文字，不属于拼音确认，只核对长度
  private continuePickInsert(text: string, usePreview: boolean, previewLength: number): void {
    this.continuation.noteOwnInsert(text.length);
    if (!usePreview) {
      this.editor.insertText(text);
      return;
    }
    this.editor.setPreviewText(text).then((ok: boolean) => {
      if (ok) {
        this.editor.finishTextPreview();
      } else if (previewLength === 0) {
        this.editor.insertText(text);
      }
    });
  }

  // 返回列表、切换面板或收起键盘时放弃选择，并清除编辑框里的预上屏文字
  cancelPick(): void {
    if (!this.state.isPicking()) {
      return;
    }
    const previewed = !this.pickPreviewUnsupported && (this.pickPreviewLength > 0 || this.pickPreviewBusy);
    const previewLength = this.pickPreviewLength;
    this.resetPick();
    if (previewed) {
      this.clearPreview(previewLength);
    }
  }

  /**
   * 预上屏内容换成空文字后结束预上屏。部分编辑框不接受空的预上屏文字，此时结束预上屏再删除刚才留下的文字。
   */
  private clearPreview(previewLength: number): void {
    this.editor.setPreviewText('').then((ok: boolean) => {
      this.editor.finishTextPreview();
      if (!ok && previewLength > 0) {
        this.editor.deleteBeforeCursor(previewLength);
      }
    });
  }

  private resetPick(): void {
    this.pickGeneration++;
    this.pickPreviewBusy = false;
    this.pickPreviewDirty = false;
    this.pickPreviewLength = 0;
    this.pickPreviewUnsupported = false;
    if (this.state.pickTokens.length > 0) {
      this.state.pickTokens = [];
      this.state.pickSelected = [];
    }
  }

  /**
   * 粘贴控件点击成功后系统临时放行一次读取：上屏当前剪贴板文字，收录开启时同时记入历史。
   */
  pasteOnce(): void {
    this.clipboard.readText().then((text: string) => {
      if (text.length === 0) {
        this.showStatus('剪贴板中没有文字');
        return;
      }
      if (this.state.clipboardEnabled) {
        this.addClip(text);
      }
      this.insert(text);
    });
  }

  /**
   * 收录剪贴板文字。新复制的文字同时放到候选栏，打开剪贴板面板时补收的旧文字只进历史。
   */
  private onClipboardText(text: string, fresh: boolean): void {
    const clipped = this.addClip(text);
    if (fresh) {
      this.state.clipSuggestion = clipped;
    }
  }

  /**
   * 点按候选栏里刚复制的文字：上屏后从候选栏移除，剪贴板历史保留这一条。
   */
  insertClipSuggestion(): void {
    const text = this.state.clipSuggestion;
    if (text.length === 0) {
      return;
    }
    this.state.clipSuggestion = '';
    this.insert(text);
  }

  /**
   * 点按候选栏里刚复制的文字右端的关闭键：只从候选栏收起，剪贴板历史保留这一条。
   */
  dismissClipSuggestion(): void {
    this.state.clipSuggestion = '';
  }

  private addClip(text: string): string {
    const clipped = text.length > CLIPBOARD_TEXT_LIMIT ? text.substring(0, CLIPBOARD_TEXT_LIMIT) : text;
    const items = this.state.clipboardItems.filter((item: string) => item !== clipped);
    items.unshift(clipped);
    this.saveClips(items.slice(0, CLIPBOARD_LIMIT));
    return clipped;
  }

  // 候选栏里的文字已经不在剪贴板历史中时一并移除，删除或清空的记录不会再从候选栏出现
  private saveClips(items: string[]): void {
    this.state.clipboardItems = items;
    this.layoutStore.saveList(KEY_CLIPBOARD_ITEMS, items);
    if (this.state.clipSuggestion.length > 0 && items.indexOf(this.state.clipSuggestion) < 0) {
      this.state.clipSuggestion = '';
    }
  }

  // ---------- 诊断 ----------

  toggleProbe(): void {
    this.state.showProbe = !this.state.showProbe;
    if (this.state.showProbe) {
      this.panelController.refreshInsets();
    }
    this.updateProbe();
  }

  reportContentSize(widthVp: number, heightVp: number, lastTouch: string): void {
    if (!this.state.showProbe) {
      return;
    }
    this.updateProbe(`content ${widthVp.toFixed(1)}x${heightVp.toFixed(1)}vp touch ${lastTouch}`);
  }

  private probeExtra: string = '';

  private updateProbe(extra?: string): void {
    if (extra !== undefined) {
      this.probeExtra = extra;
    }
    if (!this.state.showProbe) {
      return;
    }
    const g = this.panelController.getGeometry();
    const padding = this.state.keyboardPadding;
    this.state.probeLines = [
      `display ${g.displayId} density ${g.density.toFixed(2)} ${this.state.isLandscape ? 'landscape' : 'portrait'}`,
      `panel ${g.panelWidthPx}x${g.panelHeightPx}px area ${g.areaText}`,
      `insets ${g.insetsText} padding L${padding.left.toFixed(0)} R${padding.right.toFixed(0)} ` +
        `B${padding.bottom.toFixed(0)}vp`,
      this.probeExtra
    ];
  }
}
