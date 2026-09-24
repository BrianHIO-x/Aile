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
import { CandidateProvider, CandidateSource, LetterAlternative, RawCandidateProvider } from '../engine/EngineTypes';
import { characterCount } from '../engine/UserLexicon';
import { RECENT_EMOJI_LIMIT } from '../keyboard/EmojiData';
import { PICK_TEXT_LIMIT, splitPickTokens } from '../keyboard/PickText';
import {
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
  CandidateFilter,
  CandidateView,
  ClipTab,
  ImeState,
  InputLang,
  LexiconStatus,
  PanelMode,
  ShiftState
} from './ImeState';
import { CommitLearner, CommitResult, CompositionController, CompositionSnapshot } from './CompositionController';
import { CLEAR_TEXT_LIMIT, ClearResult, ClearStatus, EditorAdapter } from './EditorAdapter';
import { PanelController } from './PanelController';
import { Log } from './Log';

const DOUBLE_TAP_MS: number = 300;
const CONTEXT_TAIL_LENGTH: number = 8;
const CLIPBOARD_LIMIT: number = 30;
const CLIPBOARD_TEXT_LIMIT: number = 5000;
const PHRASE_LIMIT: number = 100;
// 一次按键的组词耗时超过这个毫秒数时记一条日志，便于发现词库搜索退化
const SLOW_COMPOSE_MS: number = 25;

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
  private readonly layoutStore: LayoutStore = new LayoutStore();
  private readonly clipboard: ClipboardService = new ClipboardService();
  private keyboardController: inputMethodEngine.KeyboardController | undefined = undefined;
  private learner: CommitLearner | undefined = undefined;
  private readonly rawCandidateProvider: CandidateProvider = new RawCandidateProvider();
  private sessionCounter: number = 0;
  private preferredLang: InputLang = InputLang.ZH;
  private lastShiftTap: number = 0;
  private deleteDelayTimer: number = -1;
  private deleteRepeatTimer: number = -1;
  private committedTail: string = '';
  private registered: boolean = false;
  // 编辑框推送的最新全文，只持有引用；密码框与超长文本不保存
  private editorText: string = '';
  // 删除键按下时的全文与组词快照，抬起时释放
  private pressText: string = '';
  private pressComposition: CompositionSnapshot | undefined = undefined;
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
    this.keyboardController = kbController;
    this.editor.bind(client, sessionId);
    this.stopDeleteRepeat();
    this.releaseEditorText();
    this.composition.reset();
    this.committedTail = '';
    this.composition.setPreviousText('');
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
        this.applyEditorAttribute(attribute, true);
      }
    }).catch((error: BusinessError) => {
      Log.warn(`getEditorAttribute failed, code=${error.code}`);
    });
    Log.info(`inputStart session=${sessionId}`);
  };

  private onInputStop = (): void => {
    const sessionId = this.editor.currentSession();
    this.stopDeleteRepeat();
    this.releaseEditorText();
    this.resetPick();
    this.resetCursor();
    this.composition.reset();
    this.syncComposition();
    this.editor.unbind(sessionId);
    this.keyboardController = undefined;
    this.learner?.flush();
    Log.info(`inputStop session=${sessionId}`);
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
    this.learner?.flush();
  };

  private onSetSubtype = (subtype: InputMethodSubtype): void => {
    const lang = subtype.id === 'en_qwerty' ? InputLang.EN : InputLang.ZH;
    this.preferredLang = lang;
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

  // 系统输入框在光标或内容变化时推送全文，这里只替换引用，旧字符串随之可被回收
  private onTextChange = (text: string): void => {
    this.editorText = text.length <= CLEAR_TEXT_LIMIT * 2 && !isPasswordPattern(this.state.inputPattern) ? text : '';
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
    this.state.clipboardItems = this.layoutStore.loadList(KEY_CLIPBOARD_ITEMS).slice(0, CLIPBOARD_LIMIT);
    this.state.phraseItems = this.layoutStore.loadList(KEY_PHRASE_ITEMS).slice(0, PHRASE_LIMIT);
    this.state.recentEmoji = this.layoutStore.loadList(KEY_RECENT_EMOJI).slice(0, RECENT_EMOJI_LIMIT);
    this.clipboard.init(context, () => this.state.clipboardEnabled, (text: string) => this.addClip(text));
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
    this.registered = false;
  }

  private applyEditorAttribute(attribute: inputMethodEngine.EditorAttribute, isNewSession: boolean): void {
    this.state.enterKeyType = attribute.enterKeyType;
    const patternChanged = this.state.inputPattern !== attribute.inputPattern;
    this.state.inputPattern = attribute.inputPattern;
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

  setLearner(learner: CommitLearner | undefined): void {
    this.learner = learner;
  }

  rawProvider(): CandidateProvider {
    return this.rawCandidateProvider;
  }

  /**
   * 长按候选删除学习记录，只影响用户词库。
   */
  forgetCandidate(index: number): void {
    const candidates = this.composition.getCandidates();
    const learner = this.learner;
    if (learner === undefined || index < 0 || index >= candidates.length) {
      return;
    }
    const candidate = candidates[index];
    if (candidate.syllables.length === 0) {
      return;
    }
    const removed = learner.forget(candidate.syllables, candidate.text);
    if (removed) {
      this.composition.refresh();
      this.syncComposition();
    }
    this.showStatus(removed ? '已删除该词的学习记录' : '该词没有学习记录');
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
    this.composition.refresh();
    this.syncComposition();
    this.showStatus('学习数据已清除');
  }

  // ---------- 按键动作 ----------

  onKeyDown(track: TouchTrack): void {
    const key = track.rect.key;
    this.state.pressedKeyIds = this.state.pressedKeyIds.concat([key.id]);
    if (key.type === KeyType.DELETE) {
      // 按下即删除一个字符，删除前记下全文与组词快照，同一手势上滑清空时据此恢复完整内容
      this.pressText = this.editorText;
      this.pressComposition = this.composition.isComposing() ? this.composition.snapshot() : undefined;
      this.performDelete();
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
    }
  }

  /**
   * 横向滑动移动光标。进入光标模式时收起按下与上滑的效果，之后把每次换算出的字数交给编辑框。
   */
  onCursorSwipe(track: TouchTrack): void {
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
    // 删除键上滑越过阈值的这一次通知只出现一次，立即清空，不等手指抬起
    if (track.swipeFired && track.rect.key.type === KeyType.DELETE) {
      this.clearAll();
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

  selectCandidate(index: number): void {
    const result = this.composition.select(index);
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
      }
      return;
    }
    this.hideKeyboard();
  }

  setCandidateFilter(filter: CandidateFilter): void {
    this.state.candidateFilter = filter;
  }

  closeFreeSelect(): void {
    this.state.candidatesExpanded = false;
  }

  deleteInFreeSelect(): void {
    this.performDelete();
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
    if (this.composition.isComposing()) {
      this.composition.backspace();
      this.syncComposition();
      return;
    }
    this.editor.deleteBeforeCursor(1);
    this.committedTail = '';
    this.composition.setPreviousText('');
  }

  /**
   * 删除键上滑。按下时正在输入拼音，就只清空拼音与候选，编辑框保持不动；否则清空编辑框中光标前后的全部文字。
   */
  private clearAll(): void {
    this.stopDeleteRepeat();
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
    this.committedTail = '';
    this.composition.setPreviousText('');
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

  private startDeleteRepeat(): void {
    this.stopDeleteRepeat();
    this.deleteDelayTimer = setTimeout(() => {
      this.deleteDelayTimer = -1;
      this.deleteRepeatTimer = setInterval(() => {
        this.performDelete();
      }, REPEAT_INTERVAL_MS);
    }, LONG_PRESS_MS);
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
    this.editor.insertText(text);
    this.rememberCommitted(text, false);
  }

  /**
   * 组词状态先行复位，编辑框提交成功后产生学习事件，提交失败且期间没有新的组词时恢复快照。
   * explicit 为 false 表示自动提交，用户没有确认候选，词频与按键偏移都不学习。
   */
  private finishCommit(result: CommitResult | undefined, explicit: boolean = true): void {
    if (result === undefined) {
      this.syncComposition();
      return;
    }
    this.dismissUndo();
    const sessionId = this.editor.currentSession();
    const previousText = this.committedTail;
    const learn = explicit && !result.raw && this.state.learningEnabled &&
      !isPasswordPattern(this.state.inputPattern);
    this.rememberCommitted(result.text, !result.raw);
    this.syncComposition();
    this.editor.insertText(result.text).then((ok: boolean) => {
      if (sessionId !== this.editor.currentSession()) {
        return;
      }
      if (ok) {
        if (learn) {
          this.learner?.learn(result, previousText);
          this.learnTaps(result);
        }
        return;
      }
      if (!this.composition.isComposing()) {
        this.composition.restore({ rawCode: '', alternatives: [], taps: [], segments: result.segments });
        this.syncComposition();
      }
    });
  }

  private learnTaps(result: CommitResult): void {
    const typings: ConfirmedTyping[] = [];
    for (const segment of result.segments) {
      if (segment.source !== CandidateSource.RAW && segment.syllables.length > 0) {
        const typing: ConfirmedTyping = { code: segment.code, syllables: segment.syllables, taps: segment.taps };
        typings.push(typing);
      }
    }
    TouchModel.get().learn(typings);
  }

  private rememberCommitted(text: string, isChinese: boolean): void {
    if (!isChinese) {
      this.committedTail = '';
      this.composition.setPreviousText('');
      return;
    }
    this.committedTail = text.length > CONTEXT_TAIL_LENGTH ? text.substring(text.length - CONTEXT_TAIL_LENGTH) : text;
    this.composition.setPreviousText(this.committedTail);
  }

  private syncComposition(): void {
    this.state.preedit = this.composition.preeditText();
    const candidates = this.composition.getCandidates();
    const views: CandidateView[] = [];
    for (let i = 0; i < candidates.length; i++) {
      const chars = candidates[i].source === CandidateSource.RAW ? 0 : characterCount(candidates[i].text);
      const view: CandidateView = { index: i, text: candidates[i].text, chars: chars };
      views.push(view);
    }
    this.state.candidates = views;
    if (views.length === 0) {
      this.state.candidatesExpanded = false;
    }
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
   * 拖动滑块期间只刷新预览，松手后再保存并调整面板高度。
   */
  previewProfile(orientation: ProfileOrientation, profile: LayoutProfile): void {
    const copy = copyProfile(profile);
    if (orientation === ProfileOrientation.LANDSCAPE) {
      this.state.landscapeProfile = copy;
    } else {
      this.state.portraitProfile = copy;
    }
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
    this.rememberCommitted(text, false);
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

  private addClip(text: string): void {
    const clipped = text.length > CLIPBOARD_TEXT_LIMIT ? text.substring(0, CLIPBOARD_TEXT_LIMIT) : text;
    const items = this.state.clipboardItems.filter((item: string) => item !== clipped);
    items.unshift(clipped);
    this.saveClips(items.slice(0, CLIPBOARD_LIMIT));
  }

  private saveClips(items: string[]): void {
    this.state.clipboardItems = items;
    this.layoutStore.saveList(KEY_CLIPBOARD_ITEMS, items);
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
