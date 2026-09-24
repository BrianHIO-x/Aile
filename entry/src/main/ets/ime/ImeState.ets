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

export enum CandidateFilter {
  ALL = 'all',
  WORDS = 'words',
  CHARS = 'chars'
}

export interface CandidateView {
  index: number;
  text: string;
  // 字符数，原文候选记为 0，用于自由选词的词语与单字筛选
  chars: number;
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
  @Trace candidates: CandidateView[] = [];
  @Trace candidatesExpanded: boolean = false;
  @Trace candidateFilter: CandidateFilter = CandidateFilter.ALL;
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
