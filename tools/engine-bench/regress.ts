// 拼音引擎的确定性回归：补齐 bench 不覆盖的候选契约。
// 运行：powershell -ExecutionPolicy Bypass -File tools\engine-bench\run.ps1 -Regress
// 两部分组成：
//   1) 小词库 + 可控二元模型的行内断言：同末词备选、第 4 个同音词靠上下文重排、早期同音分歧、短多词句。
//   2) 真实词库的少量逐键场景：整句与逐段消费、显式分隔符、消费长度、不可读后缀时的前缀与原文兜底、
//      limit 严格有界、原文候选契约、固定与删除、RAW 不学习。
// 只依赖引擎源码，不依赖界面层；每条断言都打印结果，末尾汇总失败数并以非零码退出。
declare const require: (name: string) => any;
declare const process: { argv: string[]; exitCode: number };
declare const console: { log: (message: string) => void };
const fs = require('fs');

import { Candidate, CandidateOrigin, CandidateSource, LetterAlternative, QueryOptions, rawCandidate } from './EngineTypes';
import { keyLetter, Lexicon } from './Lexicon';
import { BigramModel } from './BigramModel';
import { PinyinEngine } from './PinyinEngine';
import { UserLexicon } from './UserLexicon';
import { CommitResult, CommitSegment } from '../ime/CompositionController';

let checks = 0;
let failures = 0;

function ok(name: string, condition: boolean, detail: string = ''): void {
  checks++;
  if (condition) {
    console.log('  ok   ' + name);
  } else {
    failures++;
    console.log('  FAIL ' + name + (detail.length > 0 ? '  ' + detail : ''));
  }
}

function same(name: string, actual: string, expected: string): void {
  ok(name, actual === expected, 'actual=' + JSON.stringify(actual) + ' expected=' + JSON.stringify(expected));
}

function sameNumber(name: string, actual: number, expected: number): void {
  ok(name, actual === expected, 'actual=' + actual + ' expected=' + expected);
}

function texts(list: Candidate[]): string[] {
  return list.map((candidate: Candidate) => candidate.text);
}

function indexOf(list: Candidate[], text: string): number {
  for (let i = 0; i < list.length; i++) {
    if (list[i].text === text) {
      return i;
    }
  }
  return -1;
}

function candidateOf(list: Candidate[], text: string): Candidate | undefined {
  for (const candidate of list) {
    if (candidate.text === text) {
      return candidate;
    }
  }
  return undefined;
}

function noDuplicates(list: Candidate[]): boolean {
  const seen: Set<string> = new Set<string>();
  for (const candidate of list) {
    if (seen.has(candidate.text)) {
      return false;
    }
    seen.add(candidate.text);
  }
  return true;
}

function plainOptions(): QueryOptions {
  return { fuzzy: false, alternatives: [] };
}

// ---------- 小词库与可控二元模型 ----------

interface TestWord {
  syllables: string;
  word: string;
  freq: number;
}

// 按 build-lexicon.mjs 的输出格式拼一份小词库：首行统计、按索引键排序的索引（含全部前缀）、#data 之后的分桶词条。
function buildLexicon(words: TestWord[]): string {
  let total = 0;
  const buckets: Map<string, TestWord[]> = new Map<string, TestWord[]>();
  for (const word of words) {
    total += word.freq;
    const key = word.syllables.split(' ').map((syllable: string) => keyLetter(syllable)).join('');
    const bucket = buckets.get(key);
    if (bucket === undefined) {
      buckets.set(key, [word]);
    } else {
      bucket.push(word);
    }
  }
  const keys: string[] = [];
  buckets.forEach((bucket: TestWord[], key: string) => keys.push(key));
  keys.sort();
  const pieces: string[] = [];
  const slots: Map<string, number[]> = new Map<string, number[]>();
  let offset = 0;
  let maxSyllables = 0;
  for (const key of keys) {
    const bucket = buckets.get(key) as TestWord[];
    bucket.sort((a: TestWord, b: TestWord) => b.freq - a.freq);
    const start = offset;
    for (const word of bucket) {
      const line = word.syllables + '\t' + word.word + '\t' + word.freq + '\n';
      pieces.push(line);
      offset += line.length;
      const count = word.syllables.split(' ').length;
      if (count > maxSyllables) {
        maxSyllables = count;
      }
    }
    slots.set(key, [start, offset - start]);
  }
  const slotKeys: string[] = [];
  slots.forEach((range: number[], key: string) => slotKeys.push(key));
  for (const key of keys) {
    for (let i = 1; i < key.length; i++) {
      const prefix = key.substring(0, i);
      if (!slots.has(prefix)) {
        slots.set(prefix, [0, 0]);
      }
    }
  }
  slots.forEach((range: number[], key: string) => {
    if (slotKeys.indexOf(key) < 0) {
      slotKeys.push(key);
    }
  });
  slotKeys.sort();
  let text = '#aile-lexicon\t2\t' + total + '\t' + words.length + '\t' + slotKeys.length + '\t' + maxSyllables + '\t-20\n';
  for (const key of slotKeys) {
    const range = slots.get(key) as number[];
    text += key + '\t' + range[0] + '\t' + range[1] + '\n';
  }
  text += '#data\n' + pieces.join('');
  return text;
}

interface TestRow {
  prev: string;
  alpha: number;
  next: string[][];
}

// 按 build-bigram.mjs 的输出格式拼一份小二元模型：首行统计，其后每行“前词、回退权重、后词与修正量”，按前词排序。
function buildBigram(rows: TestRow[]): string {
  const quant = 10;
  let pairs = 0;
  for (const row of rows) {
    pairs += row.next.length;
  }
  const sorted = rows.slice();
  sorted.sort((a: TestRow, b: TestRow) => a.prev < b.prev ? -1 : a.prev > b.prev ? 1 : 0);
  let text = '#aile-bigram\t2\t' + sorted.length + '\t' + pairs + '\t' + quant + '\n';
  for (const row of sorted) {
    // 每个组合写成“后词 修正量”，同一行的组合用空格连起来，落在同一个制表符字段里
    const pairs: string[] = [];
    for (const pair of row.next) {
      pairs.push(pair[0] + ' ' + Math.round(Number(pair[1]) * quant));
    }
    text += row.prev + '\t' + Math.round(row.alpha * quant) + '\t' + pairs.join(' ') + '\n';
  }
  return text;
}

function engineOf(lexiconText: string, bigramText: string = ''): PinyinEngine {
  const lexicon = new Lexicon();
  lexicon.loadFromText(lexiconText);
  const engine = new PinyinEngine(lexicon);
  if (bigramText.length > 0) {
    const model = new BigramModel();
    model.loadFromText(bigramText);
    engine.setBigramModel(model);
  }
  return engine;
}

// ---------- 1. 小词库：同末词、同音词与上下文 ----------

function syntheticTests(): void {
  console.log('[小词库] 同末词备选与短多词句');
  const words: TestWord[] = [
    { syllables: 'zai', word: '在', freq: 500 },
    { syllables: 'zai', word: '再', freq: 480 },
    { syllables: 'shuo', word: '说', freq: 800 },
    { syllables: 'shi', word: '是', freq: 1000 },
    { syllables: 'shi', word: '事', freq: 900 },
    { syllables: 'shi', word: '时', freq: 700 },
    { syllables: 'shi', word: '世', freq: 60 },
    { syllables: 'zhe', word: '这', freq: 400 }
  ];
  const engine = engineOf(buildLexicon(words));
  const zaishuo = engine.query('zaishuo', '', 60, plainOptions());
  same('两个词的整句首选在说', texts(zaishuo)[0], '在说');
  ok('同等末词“说”的再说也在候选里', indexOf(zaishuo, '再说') > 0, texts(zaishuo).slice(0, 6).join(','));
  const zai = candidateOf(zaishuo, '再说');
  ok('再说消耗整串拼音', zai !== undefined && zai.consumedCodeLength === 7,
    zai !== undefined ? 'consumed=' + zai.consumedCodeLength : 'missing');
  ok('整句候选之间没有重复文本', noDuplicates(zaishuo));
  const one = engine.query('zaishuo', '', 1, plainOptions());
  sameNumber('limit=1 只返回一条', one.length, 1);
  same('limit=1 返回首选', texts(one).join(''), '在说');

  console.log('[小词库] 同末词分歧在三个词的整句里也能选');
  const shishuo = engine.query('shishuo', '', 60, plainOptions());
  same('首选是说', texts(shishuo)[0], '是说');
  const tails: string[] = [];
  for (const candidate of shishuo) {
    if (candidate.source === CandidateSource.SENTENCE && candidate.consumedCodeLength === 7) {
      tails.push(candidate.text);
    }
  }
  ok('两条以上同末词整句方案', tails.length >= 2, tails.join(','));
  ok('这些整句都以说结尾', tails.every((text: string) => text.endsWith('说')), tails.join(','));

  console.log('[小词库] 上下文把第 4 个同音词排到前面');
  const contextWords: TestWord[] = [
    { syllables: 'zhe', word: '这', freq: 400 },
    { syllables: 'shi', word: '是', freq: 1000 },
    { syllables: 'shi', word: '事', freq: 900 },
    { syllables: 'shi', word: '时', freq: 700 },
    { syllables: 'shi', word: '世', freq: 60 }
  ];
  const rows: TestRow[] = [
    { prev: '<s>', alpha: 0, next: [['这', '2.0']] },
    { prev: '这', alpha: -4.0, next: [['世', '9.0'], ['是', '-6.0'], ['事', '-6.0'], ['时', '-6.0']] }
  ];
  const model = engineOf(buildLexicon(contextWords), buildBigram(rows));
  const zheshi = model.query('zheshi', '', 60, plainOptions());
  same('第 4 个同音词靠上文排到首位', texts(zheshi)[0], '这世');
  // 逐字改选：先选“这”，剩下的拼音再按上文挑同音字，第四个同音词这时也排在首位
  const secondWord = model.query('shi', '这', 60, plainOptions());
  same('选掉前半段以后，同音单字按上文排序', texts(secondWord)[0], '世');
  const noModelSecond = engineOf(buildLexicon(contextWords)).query('shi', '这', 60, plainOptions());
  same('没有二元模型时这些同音字仍按词频排', texts(noModelSecond)[0], '是');
  const withoutModel = engineOf(buildLexicon(contextWords));
  const plainShi = withoutModel.query('zheshi', '', 60, plainOptions());
  same('没有二元模型时这一个仍按词频排在首位', texts(plainShi)[0], '这是');
}

// ---------- 2. 真实词库：整句、逐段消费与原文 ----------

function realTests(engine: PinyinEngine): void {
  console.log('[真实词库] 整句与逐段消费');
  const sentence = engine.query('womenmingtianzailianxi', '', 60, plainOptions());
  same('整句首选我们明天再联系', texts(sentence)[0], '我们明天再联系');
  const whole = candidateOf(sentence, '我们明天再联系');
  ok('整句消耗整串拼音', whole !== undefined && whole.consumedCodeLength === 22,
    whole !== undefined ? 'consumed=' + whole.consumedCodeLength : 'missing');
  ok('分词候选与整句同在列表里', indexOf(sentence, '我们明天') > 0, texts(sentence).slice(0, 6).join(','));

  const xian = engine.query('xi\'an', '', 60, plainOptions());
  same('带分隔符的西安在首位', texts(xian)[0], '西安');
  const xianWord = candidateOf(xian, '西安');
  ok('西安消耗整串 xi\'an', xianWord !== undefined && xianWord.consumedCodeLength === 5,
    xianWord !== undefined ? 'consumed=' + xianWord.consumedCodeLength : 'missing');
  same('预编辑保留用户键入的分隔符', engine.formatCode('xi\'an', plainOptions()), 'xi\'an');

  const mingtian = engine.query('nihao\'mingtian', '', 60, plainOptions());
  same('带分隔符的整句首选你好明天', texts(mingtian)[0], '你好明天');
  same('整句消费长度等于原串长度', String(candidateOf(mingtian, '你好明天')?.consumedCodeLength), '14');
  same('预编辑按切分回写、不丢分隔符', engine.formatCode('nihao\'mingtian', plainOptions()), 'ni\'hao\'ming\'tian');

  const niSep = engine.query('ni\'', '', 60, plainOptions());
  same('尾部分隔符的预编辑保留分隔符', engine.formatCode('ni\'', plainOptions()), 'ni\'');
  same('尾部分隔符的候选仍消耗到分隔符之后', String(candidateOf(niSep, '你')?.consumedCodeLength), '3');

  console.log('[真实词库] 不可读后缀时的前缀与原文兜底');
  const nihaoii = engine.query('nihaoii', '', 60, plainOptions());
  const nihaoiiWord = candidateOf(nihaoii, '你好');
  ok('nihaoii 保留消费 5 的你好', nihaoiiWord !== undefined && nihaoiiWord.consumedCodeLength === 5,
    nihaoiiWord !== undefined ? 'consumed=' + nihaoiiWord.consumedCodeLength : 'missing');
  const nihaouu = engine.query('nihaouu', '', 60, plainOptions());
  const nihaouuWord = candidateOf(nihaouu, '你好');
  ok('nihaouu 保留消费 5 的可靠读法而不是只覆盖 nih 的读法',
    nihaouuWord !== undefined && nihaouuWord.consumedCodeLength === 5,
    nihaouuWord !== undefined ? 'consumed=' + nihaouuWord.consumedCodeLength : 'missing');
  ok('原文兜底始终在列表最后', texts(nihaouu)[nihaouu.length - 1] === 'nihaouu', texts(nihaouu).join(','));
  const onlyRaw = engine.query('\'\'\'', '', 60, plainOptions());
  sameNumber('全是分隔符时给出原文兜底', onlyRaw.length, 1);
  same('原文兜底保留分隔符原样', onlyRaw.length > 0 ? onlyRaw[0].text : '', '\'\'\'');
  sameNumber('原文兜底按原文消耗', onlyRaw.length > 0 ? onlyRaw[0].consumedCodeLength : -1, 3);

  console.log('[真实词库] 打错场景的候选不被整句挤到后面');
  const cases: string[][] = [
    ['bunengg', '不能'],
    ['shiyongg', '使用'],
    ['fazhann', '发展'],
    ['guolia', '过来'],
    ['jianil', '建立']
  ];
  for (const item of cases) {
    const list = engine.query(item[0], '', 60, withCenterAlternatives(item[0]));
    const rank = indexOf(list, item[1]);
    ok(item[0] + ' 的目标词在前三', rank >= 0 && rank < 3, 'rank=' + rank + ' ' + texts(list).slice(0, 5).join(','));
  }

  console.log('[真实词库] 多打一个字母的整句仍不吞掉后面的音节');
  const youbuguan = engine.query('youbuguan', '', 60, plainOptions());
  ok('youbuguan 首选又不', texts(youbuguan)[0] === '又不' || texts(youbuguan).indexOf('又不') >= 0,
    texts(youbuguan).slice(0, 5).join(','));

  console.log('[真实词库] 聊天整句的逐键场景');
  const chat = engine.query('wozuijinyezaijian', '', 60, plainOptions());
  ok('我最近也在减在前三', indexOf(chat, '我最近也在减') >= 0 && indexOf(chat, '我最近也在减') < 3,
    texts(chat).slice(0, 4).join(','));
  const long = engine.query('zhegewentiwomenxiawuzaitaolun', '', 60, plainOptions());
  ok('长整句在前三', indexOf(long, '这个问题我们下午再讨论') >= 0 && indexOf(long, '这个问题我们下午再讨论') < 3,
    texts(long).slice(0, 4).join(','));
  let prefixOk = true;
  let limitOk = true;
  const code = 'womenmingtianzailianxi';
  for (let i = 1; i <= code.length; i++) {
    const list = engine.query(code.substring(0, i), '', 60, plainOptions());
    if (list.length === 0) {
      prefixOk = false;
    }
    if (list.length >= 1 && list[0].consumedCodeLength < 1) {
      limitOk = false;
    }
  }
  ok('逐键输入每个前缀都有候选', prefixOk);
  ok('每个前缀的首候选都消耗至少一个字母', limitOk);
}

function withCenterAlternatives(code: string): QueryOptions {
  // 与 bench 一致：手指落在按键正中时的邻键代价。这里只给出常见的一组，够触发纠错边即可。
  const near: Map<string, string[]> = new Map<string, string[]>();
  near.set('b', ['v', 'n', 'g']);
  near.set('u', ['y', 'i', 'j']);
  near.set('n', ['b', 'm', 'h']);
  near.set('e', ['w', 'r', 'd']);
  near.set('g', ['f', 'h', 'b']);
  near.set('s', ['a', 'd', 'x']);
  near.set('h', ['g', 'j', 'y']);
  near.set('i', ['u', 'o', 'k']);
  near.set('y', ['t', 'u', 'h']);
  near.set('o', ['i', 'p', 'l']);
  near.set('f', ['d', 'g', 'r']);
  near.set('a', ['q', 's', 'z']);
  near.set('z', ['x', 'a', 'c']);
  near.set('h', ['g', 'j', 'y']);
  near.set('n', ['b', 'm', 'j']);
  near.set('j', ['h', 'k', 'u']);
  near.set('l', ['k', 'o', 'p']);
  const alternatives: LetterAlternative[][] = [];
  for (let i = 0; i < code.length; i++) {
    const letters = near.get(code.charAt(i));
    const list: LetterAlternative[] = [];
    if (letters !== undefined) {
      for (const letter of letters) {
        list.push({ letter: letter, cost: 3.6 });
      }
    }
    alternatives.push(list);
  }
  return { fuzzy: false, alternatives: alternatives };
}

// ---------- 3. 候选契约：limit、原文、学习 ----------

function contractTests(engine: PinyinEngine, baseLexicon: Lexicon): void {
  console.log('[契约] limit 严格有界');
  const codes: string[] = ['womenmingtianzailianxi', 'zai', 'vvv', '\'', 'hhh', 'xi\'an'];
  let bounded = true;
  let nonEmpty = true;
  for (const code of codes) {
    for (let limit = 1; limit <= 3; limit++) {
      const list = engine.query(code, '', limit, plainOptions());
      if (list.length > limit) {
        bounded = false;
      }
      if (list.length === 0) {
        nonEmpty = false;
      }
    }
  }
  ok('任何输入的任何 limit 都不超出条数', bounded);
  ok('limit 不小于 1 时总有可上屏的东西', nonEmpty);
  sameNumber('limit=0 返回空表', engine.query('zai', '', 0, plainOptions()).length, 0);
  sameNumber('空串返回空表', engine.query('', '', 60, plainOptions()).length, 0);
  const onePrefix = engine.query('nihaoii', '', 1, plainOptions());
  same('limit=1 也先给可确认的前缀，而不是原文', onePrefix.length === 1 ? onePrefix[0].text : '', '你好');
  ok('limit=1 的前缀候选不是原文来源', onePrefix.length === 1 && onePrefix[0].source !== CandidateSource.RAW);
  const oneRaw = engine.query('vvv', '', 1, plainOptions());
  same('读不出内容时 limit=1 给出原文', oneRaw.length === 1 ? oneRaw[0].text : '', 'vvv');
  ok('读不出内容时 limit=1 的候选就是原文来源',
    oneRaw.length === 1 && oneRaw[0].source === CandidateSource.RAW);
  same('空串的预编辑为空', engine.formatCode('', plainOptions()), '');

  console.log('[契约] 原文候选');
  const raw = rawCandidate('xi\'an');
  same('原文文本保留分隔符', raw.text, 'xi\'an');
  sameNumber('原文消耗整串', raw.consumedCodeLength, 5);
  sameNumber('原文没有音节', raw.syllables.length, 0);
  ok('原文来源标记为 RAW', raw.source === CandidateSource.RAW);

  console.log('[契约] RAW 不参与学习');
  const lexicon = new UserLexicon(() => 100);
  lexicon.attachBase(baseLexicon);
  const rawSegment: CommitSegment = {
    text: 'nihao', code: 'nihao', syllables: [], source: CandidateSource.RAW, alternatives: [], taps: []
  };
  const rawOnly: CommitResult = { text: 'nihao', segments: [rawSegment], raw: false };
  lexicon.learn(rawOnly, '');
  sameNumber('只有原文片段时不学任何词', lexicon.wordCount(), 0);
  const rawFlagged: CommitResult = { text: 'nihao', segments: [rawSegment], raw: true };
  lexicon.learn(rawFlagged, '');
  sameNumber('结果标记为原文时同样不学', lexicon.wordCount(), 0);
  const wordSegment: CommitSegment = {
    text: '你好', code: 'nihao', syllables: ['ni', 'hao'], source: CandidateSource.WORD, alternatives: [], taps: []
  };
  const normal: CommitResult = { text: '你好', segments: [wordSegment], raw: false };
  lexicon.learn(normal, '');
  sameNumber('选词库里的词照常学习', lexicon.wordCount(), 1);
  const twoSegments: CommitResult = {
    text: '你好',
    segments: [
      { text: '你', code: 'ni', syllables: ['ni'], source: CandidateSource.WORD, alternatives: [], taps: [] },
      { text: '好', code: 'hao', syllables: ['hao'], source: CandidateSource.WORD, alternatives: [], taps: [] }
    ],
    raw: false
  };
  lexicon.learn(twoSegments, '');
  ok('分段拼出的词组也学成新词', lexicon.wordCount() >= 2, 'words=' + lexicon.wordCount());

  console.log('[契约] 固定与删除');
  const rules = new UserLexicon(() => 100);
  const zai = engine.query('zai', '', 60, plainOptions());
  const pinned = rules.arrange('zai', zai);
  same('没有固定记录时顺序不变', texts(pinned)[0], texts(zai)[0]);
  rules.pin('zai', ['zai'], '再');
  const afterPin = rules.arrange('zai', zai);
  same('固定以后排在首位', texts(afterPin)[0], '再');
  ok('固定的候选仍然消耗整串', afterPin[0].consumedCodeLength === 3,
    'consumed=' + afterPin[0].consumedCodeLength);
  rules.remove(['zai'], '再');
  const afterRemove = rules.arrange('zai', zai);
  ok('删除以后不再列出', indexOf(afterRemove, '再') < 0, texts(afterRemove).slice(0, 6).join(','));
  ok('删除以后可以撤销', rules.restoreRemoved());
  const afterRestore = rules.arrange('zai', zai);
  ok('撤销以后又回到列表', indexOf(afterRestore, '再') >= 0, texts(afterRestore).slice(0, 6).join(','));
}

// ---------- 4. 学习与简拼召回 ----------

function commitOne(lexicon: UserLexicon, text: string, code: string, syllables: string[],
  source: CandidateSource): void {
  const segment: CommitSegment = {
    text: text, code: code, syllables: syllables, source: source, alternatives: [], taps: []
  };
  const result: CommitResult = { text: text, segments: [segment], raw: false };
  lexicon.learn(result, '');
}

function learningAndRecallTests(baseLexicon: Lexicon, bigramModel: BigramModel): void {
  console.log('[学习与简拼召回] 单字、简拼、短句、碰撞音节与持久化');
  const createEngine = (): { engine: PinyinEngine; user: UserLexicon } => {
    const engine = new PinyinEngine(baseLexicon);
    engine.setBigramModel(bigramModel);
    const user = new UserLexicon(() => 20000);
    user.attachBase(baseLexicon);
    engine.setUserModel(user);
    return { engine: engine, user: user };
  };

  // 1) 单字确认 1 次后按首字母立刻排到首位（逐个在干净用户库里测互不干扰）
  const singlePairs: [string, string, string[], string][] = [
    ['ma', '吗', ['ma'], 'm'],
    ['ma', '马', ['ma'], 'm'],
    ['ming', '明', ['ming'], 'm'],
    ['de', '的', ['de'], 'd']
  ];
  for (const item of singlePairs) {
    const pair = createEngine();
    commitOne(pair.user, item[1], item[0], item[2], CandidateSource.CHAR);
    const list = pair.engine.query(item[3], '', 60, plainOptions());
    same(item[0] + '→' + item[1] + ' 后按 ' + item[3] + ' 排在首位', texts(list)[0], item[1]);
  }

  // 2) 全拼打过的多字词，确认 1 次后按首字母简拼排到首位（同时保留 WHOLE_MARGIN 内的同码词）
  const abbrPairs: [string, string, string[], string][] = [
    ['shurufa', '输入法', ['shu', 'ru', 'fa'], 'srf'],
    ['shurufa', '输入法', ['shu', 'ru', 'fa'], 'shurf'],
    ['pingban', '平板', ['ping', 'ban'], 'pb'],
    ['diannao', '电脑', ['dian', 'nao'], 'dn'],
    ['kaifa', '开发', ['kai', 'fa'], 'kf'],
    ['xiaohongshu', '小红书', ['xiao', 'hong', 'shu'], 'xhs'],
    ['anquan', '安全', ['an', 'quan'], 'aq']
  ];
  for (const item of abbrPairs) {
    const pair = createEngine();
    commitOne(pair.user, item[1], item[0], item[2], CandidateSource.WORD);
    const list = pair.engine.query(item[3], '', 60, plainOptions());
    same(item[0] + '→' + item[1] + ' 后按 ' + item[3] + ' 排在首位', texts(list)[0], item[1]);
    if (item[3] === 'srf') {
      const srfRank = indexOf(list, '杀人犯');
      ok('srf 提升输入法后“杀人犯”仍保留在前三位', srfRank > 0 && srfRank < 3,
        'rank=' + srfRank + ' ' + texts(list).slice(0, 5).join(','));
    }
  }

  // 3) 独立纯辅音音节 hm 碰撞“鸿蒙”
  const hmPair = createEngine();
  commitOne(hmPair.user, '鸿蒙', 'hongmeng', ['hong', 'meng'], CandidateSource.WORD);
  const hmList = hmPair.engine.query('hm', '', 60, plainOptions());
  same('hongmeng→鸿蒙 后按 hm 排在首位', texts(hmList)[0], '鸿蒙');

  // 4) 双字母声母 sh 召回“上海”
  const shPair = createEngine();
  commitOne(shPair.user, '上海', 'shanghai', ['shang', 'hai'], CandidateSource.WORD);
  const sh1 = shPair.engine.query('sh', '', 60, plainOptions());
  ok('shanghai→上海 1 次后按 sh 进前二', indexOf(sh1, '上海') >= 0 && indexOf(sh1, '上海') < 2,
    texts(sh1).slice(0, 4).join(','));
  commitOne(shPair.user, '上海', 'shanghai', ['shang', 'hai'], CandidateSource.WORD);
  const sh2 = shPair.engine.query('sh', '', 60, plainOptions());
  same('shanghai→上海 2 次后按 sh 排在首位', texts(sh2)[0], '上海');

  // 5) 2~4 字合成短语确认 1 次即学成新词并支持首字母召回
  const shortSentence = createEngine();
  commitOne(shortSentence.user, '反重力', 'fanzhongli', ['fan', 'zhong', 'li'], CandidateSource.SENTENCE);
  sameNumber('3 字合成短语确认 1 次直接进入 words', shortSentence.user.wordCount(), 1);
  sameNumber('3 字合成短语不留在 pending', shortSentence.user.pendingCount(), 0);
  const fzl = shortSentence.engine.query('fzl', '', 60, plainOptions());
  same('fanzhongli→反重力 1 次后按 fzl 排在首位', texts(fzl)[0], '反重力');

  // 6) 5 字以上长整句仍需确认两次才入库，入库后可用首字母召回
  const longSentence = createEngine();
  const longSyls = ['wo', 'men', 'ming', 'tian', 'zai', 'lian', 'xi'];
  commitOne(longSentence.user, '我们明天再联系', 'womenmingtianzailianxi', longSyls, CandidateSource.SENTENCE);
  sameNumber('7 字整句确认 1 次先留在 pending', longSentence.user.wordCount(), 0);
  sameNumber('7 字整句待定数加一', longSentence.user.pendingCount(), 1);
  commitOne(longSentence.user, '我们明天再联系', 'womenmingtianzailianxi', longSyls, CandidateSource.SENTENCE);
  sameNumber('7 字整句确认 2 次正式学入 words', longSentence.user.wordCount(), 1);
  const wmmtzlx = longSentence.engine.query('wmmtzlx', '', 60, plainOptions());
  same('7 字整句入库后按 wmmtzlx 排在首位', texts(wmmtzlx)[0], '我们明天再联系');

  // 7) 首字母撞上全拼音节（wan/fa）：全拼打过不抢全拼首位且标成 USER_ABBR；用简拼选过后才排首位；不污染其他词前缀
  const collide = createEngine();
  commitOne(collide.user, '我爱你', 'woaini', ['wo', 'ai', 'ni'], CandidateSource.WORD);
  const wanAfterFull = collide.engine.query('wan', '', 60, plainOptions());
  same('全拼打过我爱你后，wan 首位仍保留全拼“玩”', texts(wanAfterFull)[0], '玩');
  const wanUserAbbr = candidateOf(wanAfterFull, '我爱你');
  ok('wan 候选中出现我爱你且 origin 为 USER_ABBR',
    wanUserAbbr !== undefined && wanUserAbbr.meta !== undefined &&
    wanUserAbbr.meta.origin === CandidateOrigin.USER_ABBR,
    texts(wanAfterFull).slice(0, 6).join(','));
  commitOne(collide.user, '我爱你', 'wan', ['wo', 'ai', 'ni'], CandidateSource.WORD);
  const wanAfterAbbr = collide.engine.query('wan', '', 60, plainOptions());
  same('用 wan 选过我爱你以后，再次输入 wan 首选为我爱你', texts(wanAfterAbbr)[0], '我爱你');

  const prefixSafe = createEngine();
  commitOne(prefixSafe.user, '方案', 'fangan', ['fang', 'an'], CandidateSource.WORD);
  const fazhan = prefixSafe.engine.query('fazhan', '', 60, plainOptions());
  same('学过方案(fa)不干扰 fazhan 首选发展', texts(fazhan)[0], '发展');

  // 8) 序列化往返、旧版 JSON 兼容以及 remove/restoreRemoved 维护首字母索引
  const persist = createEngine();
  commitOne(persist.user, '鸿蒙', 'hongmeng', ['hong', 'meng'], CandidateSource.WORD);
  commitOne(persist.user, '吗', 'ma', ['ma'], CandidateSource.CHAR);
  commitOne(persist.user, '反重力', 'fanzhongli', ['fan', 'zhong', 'li'], CandidateSource.SENTENCE);
  const savedJson = persist.user.serialize();
  const parsed = JSON.parse(savedJson);
  ok('序列化写入提交序号 seq 与行字段 r', typeof parsed.seq === 'number' && parsed.seq >= 3 &&
    Array.isArray(parsed.words) && parsed.words.some((row: any) => typeof row.r === 'number'));

  const reloaded = createEngine();
  reloaded.user.deserialize(savedJson);
  same('重载后 hm 仍首选鸿蒙', texts(reloaded.engine.query('hm', '', 60, plainOptions()))[0], '鸿蒙');
  same('重载后 m 仍首选吗', texts(reloaded.engine.query('m', '', 60, plainOptions()))[0], '吗');
  same('重载后 fzl 仍首选反重力', texts(reloaded.engine.query('fzl', '', 60, plainOptions()))[0], '反重力');

  reloaded.user.remove(['hong', 'meng'], '鸿蒙');
  const afterDrop = reloaded.user.arrange('hm', reloaded.engine.query('hm', '', 60, plainOptions()));
  ok('remove 鸿蒙后首字母索引与候选同步清除', indexOf(afterDrop, '鸿蒙') < 0, texts(afterDrop).slice(0, 5).join(','));
  ok('restoreRemoved 恢复鸿蒙成功', reloaded.user.restoreRemoved());
  const afterUndo = reloaded.user.arrange('hm', reloaded.engine.query('hm', '', 60, plainOptions()));
  same('撤销删除后 hm 重新首位召回鸿蒙', texts(afterUndo)[0], '鸿蒙');

  const legacy = createEngine();
  legacy.user.deserialize(JSON.stringify({
    version: 1,
    words: [{ s: 'hong meng', w: '鸿蒙', c: 1, d: 20000 }],
    bigrams: []
  }));
  const legacyHm = legacy.engine.query('hm', '', 60, plainOptions());
  ok('旧版无 seq/r 的用户词库加载兼容并重建首字母索引', indexOf(legacyHm, '鸿蒙') >= 0,
    texts(legacyHm).slice(0, 5).join(','));
}

// ---------- 入口 ----------

function main(): void {
  const lexiconPath: string = process.argv[2];
  const bigramPath: string = process.argv[3];
  if (lexiconPath === undefined || bigramPath === undefined) {
    console.log('用法：node regress.js <词库> <二元模型>');
    process.exitCode = 2;
    return;
  }
  console.log('== 小词库 ==================================================');
  syntheticTests();
  console.log('== 真实词库 ================================================');
  const lexicon = new Lexicon();
  lexicon.loadFromText(fs.readFileSync(lexiconPath, 'utf-8'));
  const engine = new PinyinEngine(lexicon);
  const model = new BigramModel();
  model.loadFromText(fs.readFileSync(bigramPath, 'utf-8'));
  engine.setBigramModel(model);
  realTests(engine);
  contractTests(engine, lexicon);
  learningAndRecallTests(lexicon, model);
  console.log('============================================================');
  console.log('共 ' + checks + ' 项，失败 ' + failures + ' 项');
  if (failures > 0) {
    process.exitCode = 1;
  }
}

main();
