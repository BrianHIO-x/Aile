export enum KeyType {
  LETTER = 'letter',
  CHAR = 'char',
  SHIFT = 'shift',
  DELETE = 'delete',
  SPACE = 'space',
  PUNCT = 'punct',
  ENTER = 'enter',
  LANG = 'lang',
  SYMBOL_PAGE = 'symbolPage',
  NUMBER_PAGE = 'numberPage',
  LETTER_PAGE = 'letterPage',
  // 符号页用锁定键替换中英切换键
  SYMBOL_LOCK = 'symbolLock'
}

export enum KeyboardPageType {
  LETTERS = 'letters',
  NUMBERS = 'numbers',
  SYMBOLS = 'symbols'
}

export enum LayoutForm {
  SPLIT = 'split',
  NORMAL = 'normal'
}

export enum PaneSide {
  LEFT = 'left',
  RIGHT = 'right',
  FULL = 'full'
}

export interface KeyDef {
  id: string;
  type: KeyType;
  label: string;
  // output 与 swipeUpOutput 为英文状态的输出，zh 前缀字段为中文状态的输出，为空时两种状态相同
  output: string;
  swipeUpOutput: string;
  zhOutput: string;
  zhSwipeUpOutput: string;
  weight: number;
  accessibility: string;
  // 向下跨越的行数，缺省为一行。下面几行排到这个键的位置时自动跳过
  rowSpan?: number;
}

export interface RowDef {
  lead: number;
  keys: KeyDef[];
}

export interface PaneDef {
  side: PaneSide;
  rows: RowDef[];
}

export interface KeyboardLayout {
  id: string;
  form: LayoutForm;
  page: KeyboardPageType;
  panes: PaneDef[];
}

export function isFunctionKey(key: KeyDef): boolean {
  return key.type !== KeyType.LETTER && key.type !== KeyType.CHAR && key.type !== KeyType.SPACE &&
    key.type !== KeyType.PUNCT;
}

// 字母键上滑输出，顺序与 LETTER_SWIPE_KEYS 一一对应。中文状态全部为中文标点，英文状态全部为英文符号。
// 中文独有的标点按常用输入法的键位对应关系取英文符号：间隔号对应反引号，顿号对应反斜杠。
// 中文左右双引号在英文中都是直双引号，L 键在英文状态改为单引号，避免两个键输出相同。
export const LETTER_SWIPE_KEYS: string = 'qwertyuiopasdfghjklzxcvbnm';
export const LETTER_SWIPE_OUTPUTS_ZH: string[] = [
  '1', '2', '3', '4', '5', '6', '7', '8', '9', '0',
  '-', '/', '：', '；', '（', '）', '～', '“', '”',
  '@', '·', '#', '、', '？', '！', '……'
];
export const LETTER_SWIPE_OUTPUTS_EN: string[] = [
  '1', '2', '3', '4', '5', '6', '7', '8', '9', '0',
  '-', '/', ':', ';', '(', ')', '~', '"', '\'',
  '@', '`', '#', '\\', '?', '!', '...'
];

export function letterSwipeOutput(ch: string, zh: boolean): string {
  const index = LETTER_SWIPE_KEYS.indexOf(ch);
  const outputs = zh ? LETTER_SWIPE_OUTPUTS_ZH : LETTER_SWIPE_OUTPUTS_EN;
  return index >= 0 && index < outputs.length ? outputs[index] : '';
}

export function hasSwipeUp(key: KeyDef): boolean {
  return key.swipeUpOutput.length > 0 || key.zhSwipeUpOutput.length > 0;
}

// 删除键上滑清空编辑框，这一动作不输出文字
export const CLEAR_SWIPE_LABEL: string = '清空';

export function hasSwipeAction(key: KeyDef): boolean {
  return hasSwipeUp(key) || key.type === KeyType.DELETE;
}

export function resolveOutput(key: KeyDef, zh: boolean): string {
  return zh && key.zhOutput.length > 0 ? key.zhOutput : key.output;
}

export function resolveSwipeUp(key: KeyDef, zh: boolean): string {
  return zh && key.zhSwipeUpOutput.length > 0 ? key.zhSwipeUpOutput : key.swipeUpOutput;
}

// 英文符号到中文标点的对应表，数字键盘在中文状态下据此转换；小数点保持英文句点
const EN_SYMBOLS: string[] = [',', '?', '!', ':', ';', '(', ')', '~', '$', '<', '>', '[', ']', '\\', '^', '_',
  '`', '"', '\''];
const ZH_SYMBOLS: string[] = ['，', '？', '！', '：', '；', '（', '）', '～', '￥', '《', '》', '【', '】', '、', '……',
  '——', '·', '“', '‘'];

export function toChineseSymbol(text: string): string {
  const index = EN_SYMBOLS.indexOf(text);
  return index >= 0 ? ZH_SYMBOLS[index] : text;
}

/**
 * 键帽与提示块上的显示文本：占两个字宽的省略号与破折号只显示一半。
 */
export function displaySymbol(text: string): string {
  if (text === '……' || text === '...') {
    return '…';
  }
  if (text === '——') {
    return '—';
  }
  return text;
}

/**
 * 字母键。同一字母在键盘上出现两次时，第二个按键传入独立的 id，按下效果与上滑提示互不影响。
 */
export function letterKey(ch: string, weight: number = 1, id: string = ''): KeyDef {
  const swipeEn = letterSwipeOutput(ch, false);
  const swipeZh = letterSwipeOutput(ch, true);
  const def: KeyDef = {
    id: id.length > 0 ? id : `letter_${ch}`,
    type: KeyType.LETTER,
    label: ch.toUpperCase(),
    output: ch,
    swipeUpOutput: swipeEn,
    zhOutput: '',
    zhSwipeUpOutput: swipeZh === swipeEn ? '' : swipeZh,
    weight: weight,
    accessibility: swipeZh.length > 0 ? `${ch.toUpperCase()}，上滑输入${swipeZh}` : ch.toUpperCase()
  };
  return def;
}

/**
 * 字符键。localize 为 true 时中文状态输出对应的中文标点；符号页的中文与英文分类本身已区分，不做转换。
 */
export function charKey(id: string, text: string, weight: number = 1, accessibility: string = '',
  localize: boolean = false): KeyDef {
  const zh = localize ? toChineseSymbol(text) : text;
  const def: KeyDef = {
    id: id,
    type: KeyType.CHAR,
    label: text,
    output: text,
    swipeUpOutput: '',
    zhOutput: zh === text ? '' : zh,
    zhSwipeUpOutput: '',
    weight: weight,
    accessibility: accessibility.length > 0 ? accessibility : text
  };
  return def;
}

export function functionKey(id: string, type: KeyType, label: string, weight: number, accessibility: string): KeyDef {
  const def: KeyDef = {
    id: id,
    type: type,
    label: label,
    output: '',
    swipeUpOutput: '',
    zhOutput: '',
    zhSwipeUpOutput: '',
    weight: weight,
    accessibility: accessibility
  };
  return def;
}

export function spaceKey(id: string, weight: number, accessibility: string): KeyDef {
  const def: KeyDef = {
    id: id,
    type: KeyType.SPACE,
    label: '',
    output: ' ',
    swipeUpOutput: '',
    zhOutput: '',
    zhSwipeUpOutput: '',
    weight: weight,
    accessibility: accessibility
  };
  return def;
}

export function punctKey(id: string, weight: number): KeyDef {
  const def: KeyDef = {
    id: id,
    type: KeyType.PUNCT,
    label: ',',
    output: ',',
    swipeUpOutput: '.',
    zhOutput: '，',
    zhSwipeUpOutput: '。',
    weight: weight,
    accessibility: '逗号，上滑输入句号'
  };
  return def;
}
