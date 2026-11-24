import { KeyboardPageType, LayoutForm } from '../keyboard/KeyDefinitions';
import { defaultProfile, LayoutProfile, ProfileOrientation } from '../keyboard/LayoutProfile';

export enum InputLang {
  ZH = 'zh',
  EN = 'en'
}

export enum ShiftState {
  OFF = 0,
  ONCE = 1,
  LOCKED = 2
}

export enum PanelMode {
  KEYBOARD = 'keyboard',
  TUNER = 'tuner',
  SETTINGS = 'settings',
  EMOJI = 'emoji',
  CLIPBOARD = 'clipboard'
}

// 剪贴板面板的两个标签页
export enum ClipTab {
  CLIPBOARD = 0,
  PHRASES = 1
}

// 功能面板的分页，与顶部分段标签一一对应
export enum SettingsTab {
  COMMON = 0,
  MODE = 1,
  PINYIN = 2,
  TOOLBAR = 3
}

export enum LexiconStatus {
  LOADING = 'loading',
  READY = 'ready',
  MISSING = 'missing',
  FAILED = 'failed'
}

// 候选栏文字大小，序号与设置页分段标签一一对应
export enum CandidateSize {
  SMALL = 0,
  MEDIUM = 1,
  LARGE = 2
}

export enum CandidateFilter {
  ALL = 'all',
  WORDS = 'words',
  CHARS = 'chars'
}

export interface CandidateView {
  // 候选在本次组词版本里的序号
  index: number;
  text: string;
  // 字符数，原文候选记为 0，用于自由选词的词语与单字筛选
  chars: number;
  // 引擎候选的稳定标识与消耗长度，与 revision 一起防止旧候选事件改到新候选
  id: string;
  consumedCodeLength: number;
  // 生成这个候选的组词版本
  revision: number;
}

// 长按的候选在键盘页面里的矩形，单位 vp，候选菜单与撤销提示贴着它弹出
export interface CandidateAnchor {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface AreaPadding {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

@ObservedV2
export class ImeState {
  private static instance: ImeState | undefined = undefined;

  @Trace lang: InputLang = InputLang.ZH;
  @Trace shift: ShiftState = ShiftState.OFF;
  @Trace page: KeyboardPageType = KeyboardPageType.LETTERS;
  @Trace symbolCategory: number = 0;
  @Trace symbolLocked: boolean = false;
  @Trace isLandscape: boolean = true;
  @Trace landscapeProfile: LayoutProfile = defaultProfile(ProfileOrientation.LANDSCAPE);
  @Trace portraitProfile: LayoutProfile = defaultProfile(ProfileOrientation.PORTRAIT);
  @Trace enterKeyType: number = 0;
  @Trace inputPattern: number = 0;
  @Trace preedit: string = '';
  // 拼音前面已经选定的汉字，是 preedit 的开头一段
  @Trace preeditChosen: string = '';
  // 候选视图：同一批 CandidateView 按四种用途各自排好顺序，index 始终是候选池里的原始序号
  @Trace candidates: CandidateView[] = [];
  @Trace candidatesAll: CandidateView[] = [];
  @Trace candidatesWords: CandidateView[] = [];
  @Trace candidatesChars: CandidateView[] = [];
  @Trace candidatesExpanded: boolean = false;
  @Trace candidateFilter: CandidateFilter = CandidateFilter.ALL;
  // 自由选词左侧的可选首音节列表与当前选中的拼音筛选（空串表示未筛选）
  @Trace pinyinOptions: string[] = [];
  @Trace selectedPinyin: string = '';
  @Trace candidateSize: number = CandidateSize.SMALL;
  // 候选栏当前一页，以及翻到这一页的方向：1 为向后，-1 为向前，0 表示候选刚刷新
  @Trace candidatePage: number = 0;
  @Trace candidatePageMotion: number = 0;
  // 长按候选弹出的菜单：候选序号为 -1 表示没有菜单
  @Trace menuIndex: number = -1;
  @Trace menuAnchor: CandidateAnchor = { x: 0, y: 0, w: 0, h: 0 };
  @Trace menuPinned: boolean = false;
  // 刚删除的候选，撤销提示显示期间不为空
  @Trace removedWord: string = '';
  @Trace pressedKeyIds: string[] = [];
  // 上滑手势：进行中的按键、进度 0～1、是否已越过触发阈值
  @Trace flickKeyId: string = '';
  @Trace flickProgress: number = 0;
  @Trace flickCommitted: boolean = false;
  // 横向滑动移动光标时，键帽上的文字隐去，整块键盘当作触控板
  @Trace cursorMode: boolean = false;
  @Trace panelMode: PanelMode = PanelMode.KEYBOARD;
  @Trace showProbe: boolean = false;
  @Trace probeLines: string[] = [];
  @Trace keyboardPadding: AreaPadding = { left: 0, top: 0, right: 0, bottom: 0 };
  @Trace lexiconStatus: LexiconStatus = LexiconStatus.LOADING;
  @Trace learningEnabled: boolean = true;
  // 模糊拼音：平翘舌、n 与 l、f 与 h、r 与 l、前后鼻音可以互换
  @Trace fuzzyPinyin: boolean = false;
  @Trace statusMessage: string = '';
  // 顶部栏是否显示撤销清空按钮；被清空的文字保存在总控的私有字段中，不进入界面状态
  @Trace clearUndoAvailable: boolean = false;
  @Trace settingsTab: number = SettingsTab.COMMON;
  // 顶部栏快捷入口
  @Trace toolbarEmoji: boolean = true;
  @Trace toolbarClipboard: boolean = true;
  // 表情：当前分类与最近使用
  @Trace emojiCategory: number = 0;
  @Trace recentEmoji: string[] = [];
  // 剪贴板：收录开关、读取授权与历史条目
  @Trace clipboardEnabled: boolean = true;
  @Trace clipboardGranted: boolean = false;
  @Trace clipboardItems: string[] = [];
  // 刚复制的文字，空闲时显示在候选栏，点按上屏后清空；为空表示没有
  @Trace clipSuggestion: string = '';
  // 剪贴板面板当前标签页与常用语条目
  @Trace clipTab: number = ClipTab.CLIPBOARD;
  @Trace phraseItems: string[] = [];
  // 长按后显示操作按钮的卡片序号，-1 表示没有
  @Trace clipActionIndex: number = -1;
  // 滑动选字：原文切分出的片段与各片段的选中状态，片段为空表示不在选字界面
  @Trace pickTokens: string[] = [];
  @Trace pickSelected: boolean[] = [];

  currentClipItems(): string[] {
    return this.clipTab === ClipTab.PHRASES ? this.phraseItems : this.clipboardItems;
  }

  isPicking(): boolean {
    return this.pickTokens.length > 0;
  }

  static get(): ImeState {
    if (ImeState.instance === undefined) {
      ImeState.instance = new ImeState();
    }
    return ImeState.instance;
  }

  currentOrientation(): ProfileOrientation {
    return this.isLandscape ? ProfileOrientation.LANDSCAPE : ProfileOrientation.PORTRAIT;
  }

  currentProfile(): LayoutProfile {
    return this.isLandscape ? this.landscapeProfile : this.portraitProfile;
  }

  currentForm(): LayoutForm {
    return this.currentProfile().form;
  }

  isComposing(): boolean {
    return this.preedit.length > 0;
  }
}