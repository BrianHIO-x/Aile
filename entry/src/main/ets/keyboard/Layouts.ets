import {
  charKey,
  functionKey,
  KeyboardLayout,
  KeyboardPageType,
  KeyDef,
  KeyType,
  LayoutForm,
  letterKey,
  PaneDef,
  PaneSide,
  punctKey,
  RowDef,
  spaceKey
} from './KeyDefinitions';

export interface SymbolCategory {
  name: string;
  symbols: string[];
}

// 每个分类 28 个符号，正好填满分离布局与常规布局的三行符号位
export const SYMBOL_CATEGORIES: SymbolCategory[] = [
  {
    name: '中文',
    symbols: ['，', '。', '？', '！', '、', '；', '：', '“', '”', '‘', '’', '（', '）', '《', '》', '【', '】',
      '……', '——', '·', '～', '￥', '「', '」', '『', '』', '〈', '〉']
  },
  {
    name: '英文',
    symbols: [',', '.', '?', '!', '\'', '"', ';', ':', '(', ')', '[', ']', '{', '}', '<', '>', '/', '\\', '|',
      '`', '~', '@', '#', '$', '%', '^', '&', '*']
  },
  {
    name: '数学',
    symbols: ['+', '-', '×', '÷', '=', '≠', '≈', '±', '<', '>', '≤', '≥', '%', '‰', '°', '√', '∞', 'π', '∑',
      '∫', '∠', '⊥', '∥', '∵', '∴', '²', '³', '_']
  },
  {
    name: '特殊',
    symbols: ['★', '☆', '○', '●', '◎', '◇', '◆', '□', '■', '△', '▲', '※', '→', '←', '↑', '↓', '✓', '✗', '♀',
      '♂', '§', '№', '©', '®', '™', '℃', '€', '£']
  }
];

export const SYMBOL_CATEGORY_ZH: number = 0;
export const SYMBOL_CATEGORY_EN: number = 1;

export const DEFAULT_SPACE_WEIGHT: number = 2.5;
export const RIGHT_G_KEY_ID: string = 'letter_g_right';
export const RIGHT_V_KEY_ID: string = 'letter_v_right';
// 字母页右手区向中间伸出的宽度，G、V 与空格都按这个宽度伸出，左边界连成一条直线
const RIGHT_LETTER_OVERHANG: number = 0.5;
// 数字页右手区分成三列数字与右侧一列，合计 5 个键宽，与字母页右手区相同
const NUMBER_SIDE_WEIGHT: number = 1.5;
const NUMBER_DIGIT_WEIGHT: number = 3.5 / 3;

function row(lead: number, keys: KeyDef[]): RowDef {
  const r: RowDef = { lead: lead, keys: keys };
  return r;
}

function pane(side: PaneSide, rows: RowDef[]): PaneDef {
  const p: PaneDef = { side: side, rows: rows };
  return p;
}

function letters(chars: string): KeyDef[] {
  const keys: KeyDef[] = [];
  for (let i = 0; i < chars.length; i++) {
    keys.push(letterKey(chars.charAt(i)));
  }
  return keys;
}

// localize 为 true 时字符在中文状态下输出对应中文标点，用于数字键盘
function chars(prefix: string, texts: string[], weight: number, localize: boolean = false): KeyDef[] {
  const keys: KeyDef[] = [];
  for (let i = 0; i < texts.length; i++) {
    keys.push(charKey(`${prefix}_${i}`, texts[i], weight, '', localize));
  }
  return keys;
}

function shiftKey(weight: number): KeyDef {
  return functionKey('shift', KeyType.SHIFT, '⇧', weight, '大写');
}

function deleteKey(weight: number): KeyDef {
  return functionKey('delete', KeyType.DELETE, '⌫', weight, '删除，上滑清空全部文字');
}

function langKey(weight: number): KeyDef {
  return functionKey('lang', KeyType.LANG, '中/英', weight, '切换中英文');
}

// 符号页不需要切换中英文，同一位置放锁定键，锁定后输入符号不返回字母页
function langOrLockKey(page: KeyboardPageType, weight: number): KeyDef {
  if (page === KeyboardPageType.SYMBOLS) {
    return functionKey('symbol_lock', KeyType.SYMBOL_LOCK, '锁定', weight, '锁定符号键盘');
  }
  return langKey(weight);
}

function enterKey(weight: number): KeyDef {
  return functionKey('enter', KeyType.ENTER, '回车', weight, '回车');
}

// 最下排在所有页面保持相同位置，当前页面对应的切换键显示为“返回”
function symbolSwitchKey(page: KeyboardPageType, weight: number): KeyDef {
  if (page === KeyboardPageType.SYMBOLS) {
    return functionKey('symbol_page', KeyType.LETTER_PAGE, '返回', weight, '返回字母键盘');
  }
  return functionKey('symbol_page', KeyType.SYMBOL_PAGE, '符号', weight, '符号键盘');
}

function numberSwitchKey(page: KeyboardPageType, weight: number): KeyDef {
  if (page === KeyboardPageType.NUMBERS) {
    return functionKey('number_page', KeyType.LETTER_PAGE, '返回', weight, '返回字母键盘');
  }
  return functionKey('number_page', KeyType.NUMBER_PAGE, '123', weight, '数字键盘');
}

// 竖着跨两行的空格，数字页右侧一列的上半截用它
function tallSpaceKey(id: string, weight: number, accessibility: string): KeyDef {
  const key = spaceKey(id, weight, accessibility);
  key.rowSpan = 2;
  return key;
}

function splitBottomLeft(page: KeyboardPageType): RowDef {
  return row(0, [
    symbolSwitchKey(page, 1),
    numberSwitchKey(page, 1),
    punctKey('punct', 1),
    spaceKey('space_left', DEFAULT_SPACE_WEIGHT, '左空格')
  ]);
}

// overhang 为整行向左伸出的宽度，回车键补上同样的宽度，右边界与上面几行保持整齐
function splitBottomRight(page: KeyboardPageType, overhang: number = 0): RowDef {
  return row(-overhang, [
    spaceKey('space_right', DEFAULT_SPACE_WEIGHT, '右空格'),
    langOrLockKey(page, 1),
    enterKey(1.5 + overhang)
  ]);
}

function normalBottom(page: KeyboardPageType): RowDef {
  return row(0, [
    symbolSwitchKey(page, 1.2),
    numberSwitchKey(page, 1.2),
    punctKey('punct', 1),
    spaceKey('space', 4.1, '空格'),
    langOrLockKey(page, 1.2),
    enterKey(1.3)
  ]);
}

function buildSplitLetters(): KeyboardLayout {
  const page = KeyboardPageType.LETTERS;
  const left = pane(PaneSide.LEFT, [
    row(0, letters('qwert')),
    row(0.5, letters('asdfg')),
    row(0, [shiftKey(1.5)].concat(letters('zxcv'))),
    splitBottomLeft(page)
  ]);
  // 右手区在 H 左侧再放一个 G，在 B 左侧再放一个 V，右手不用越过中线也能按到这两个字母。
  // 两个补出来的字母与最下排的空格同样向中间伸出半个键，右手区的左边界因此是一条直线
  const right = pane(PaneSide.RIGHT, [
    row(0, letters('yuiop')),
    row(-RIGHT_LETTER_OVERHANG, [letterKey('g', 1, RIGHT_G_KEY_ID)].concat(letters('hjkl'))),
    row(-RIGHT_LETTER_OVERHANG,
      [letterKey('v', 1, RIGHT_V_KEY_ID)].concat(letters('bnm')).concat([deleteKey(1.5)])),
    splitBottomRight(page, RIGHT_LETTER_OVERHANG)
  ]);
  const layout: KeyboardLayout = { id: 'split_letters', form: LayoutForm.SPLIT, page: page, panes: [left, right] };
  return layout;
}

function buildNormalLetters(): KeyboardLayout {
  const page = KeyboardPageType.LETTERS;
  const full = pane(PaneSide.FULL, [
    row(0, letters('qwertyuiop')),
    row(0.5, letters('asdfghjkl')),
    row(0, [shiftKey(1.5)].concat(letters('zxcvbnm')).concat([deleteKey(1.5)])),
    normalBottom(page)
  ]);
  const layout: KeyboardLayout = { id: 'normal_letters', form: LayoutForm.NORMAL, page: page, panes: [full] };
  return layout;
}

function buildSplitNumbers(): KeyboardLayout {
  const page = KeyboardPageType.NUMBERS;
  const left = pane(PaneSide.LEFT, [
    row(0, chars('num_op0', ['+', '-', '×', '÷', '='], 1.1, true)),
    row(0, chars('num_op1', ['(', ')', '%', '@', '#'], 1.1, true)),
    row(0, chars('num_op2', ['/', ':', ';', '~', '&'], 1.1, true)),
    splitBottomLeft(page)
  ]);
  // 右侧一列的上面两格合成一个竖着的空格，小数点与 0 落到最下排 7、8 的正下方。
  // 中英切换对齐 9，回车对齐删除键，四行按同一套列宽排成网格，回车与删除键和字母页同宽
  const right = pane(PaneSide.RIGHT, [
    row(0, chars('num_d0', ['1', '2', '3'], NUMBER_DIGIT_WEIGHT)
      .concat([tallSpaceKey('space_right', NUMBER_SIDE_WEIGHT, '右空格')])),
    row(0, chars('num_d1', ['4', '5', '6'], NUMBER_DIGIT_WEIGHT)),
    row(0, chars('num_d2', ['7', '8', '9'], NUMBER_DIGIT_WEIGHT).concat([deleteKey(NUMBER_SIDE_WEIGHT)])),
    row(0, [
      charKey('num_dot', '.', NUMBER_DIGIT_WEIGHT, '小数点'),
      charKey('num_zero', '0', NUMBER_DIGIT_WEIGHT),
      langKey(NUMBER_DIGIT_WEIGHT),
      enterKey(NUMBER_SIDE_WEIGHT)
    ])
  ]);
  const layout: KeyboardLayout = { id: 'split_numbers', form: LayoutForm.SPLIT, page: page, panes: [left, right] };
  return layout;
}

function buildNormalNumbers(): KeyboardLayout {
  const page = KeyboardPageType.NUMBERS;
  const full = pane(PaneSide.FULL, [
    row(0, chars('num_d', ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'], 1)),
    row(0, chars('num_s1', ['-', '/', ':', ';', '(', ')', '$', '&', '@', '"'], 1, true)),
    row(0, [charKey('num_hash', '#', 1.5)]
      .concat(chars('num_s2', ['.', ',', '?', '!', '\'', '%', '+'], 1, true))
      .concat([deleteKey(1.5)])),
    normalBottom(page)
  ]);
  const layout: KeyboardLayout = { id: 'normal_numbers', form: LayoutForm.NORMAL, page: page, panes: [full] };
  return layout;
}

function buildSplitSymbols(categoryIndex: number): KeyboardLayout {
  const page = KeyboardPageType.SYMBOLS;
  const symbols = SYMBOL_CATEGORIES[categoryIndex].symbols;
  const prefix = `sym${categoryIndex}`;
  const left = pane(PaneSide.LEFT, [
    row(0, chars(`${prefix}_a`, symbols.slice(0, 5), 1.1)),
    row(0, chars(`${prefix}_b`, symbols.slice(5, 10), 1.1)),
    row(0, chars(`${prefix}_c`, symbols.slice(10, 15), 1.1)),
    splitBottomLeft(page)
  ]);
  const right = pane(PaneSide.RIGHT, [
    row(0, chars(`${prefix}_d`, symbols.slice(15, 20), 1)),
    row(0, chars(`${prefix}_e`, symbols.slice(20, 25), 1)),
    row(0, chars(`${prefix}_f`, symbols.slice(25, 28), 1).concat([deleteKey(2)])),
    splitBottomRight(page)
  ]);
  const layout: KeyboardLayout = {
    id: `split_symbols_${categoryIndex}`, form: LayoutForm.SPLIT, page: page, panes: [left, right]
  };
  return layout;
}

function buildNormalSymbols(categoryIndex: number): KeyboardLayout {
  const page = KeyboardPageType.SYMBOLS;
  const symbols = SYMBOL_CATEGORIES[categoryIndex].symbols;
  const prefix = `sym${categoryIndex}`;
  const full = pane(PaneSide.FULL, [
    row(0, chars(`${prefix}_a`, symbols.slice(0, 10), 1)),
    row(0, chars(`${prefix}_b`, symbols.slice(10, 20), 1)),
    row(0, chars(`${prefix}_c`, symbols.slice(20, 28), 1).concat([deleteKey(2)])),
    normalBottom(page)
  ]);
  const layout: KeyboardLayout = {
    id: `normal_symbols_${categoryIndex}`, form: LayoutForm.NORMAL, page: page, panes: [full]
  };
  return layout;
}

const layoutCache: Map<string, KeyboardLayout> = new Map<string, KeyboardLayout>();

export function getLayout(form: LayoutForm, page: KeyboardPageType, symbolCategory: number = 0): KeyboardLayout {
  const category = Math.max(0, Math.min(SYMBOL_CATEGORIES.length - 1, Math.floor(symbolCategory)));
  const cacheKey = `${form}_${page}_${page === KeyboardPageType.SYMBOLS ? category : 0}`;
  const cached = layoutCache.get(cacheKey);
  if (cached !== undefined) {
    return cached;
  }
  let layout: KeyboardLayout;
  if (page === KeyboardPageType.NUMBERS) {
    layout = form === LayoutForm.SPLIT ? buildSplitNumbers() : buildNormalNumbers();
  } else if (page === KeyboardPageType.SYMBOLS) {
    layout = form === LayoutForm.SPLIT ? buildSplitSymbols(category) : buildNormalSymbols(category);
  } else {
    layout = form === LayoutForm.SPLIT ? buildSplitLetters() : buildNormalLetters();
  }
  layoutCache.set(cacheKey, layout);
  return layout;
}
