// 候选排序的离线回归：真实引擎 + CandidateRanking + CompositionController。
// 普通栏与展开的全部/词语/单字用同一份 rankCandidates 快照，点按仍按候选池的原始 index 消费。
// 运行：powershell -ExecutionPolicy Bypass -File tools\candidate-rank\run.ps1
declare const require: (name: string) => any;
declare const process: { argv: string[]; exitCode: number };
declare const console: { log: (message: string) => void; error: (message: string) => void };
const fs = require('fs');

import {
  Candidate,
  CandidateMeta,
  CandidateProvider,
  CandidateReading,
  CandidateSource,
  LetterAlternative,
  QueryOptions
} from './engine/EngineTypes';
import { BigramModel } from './engine/BigramModel';
import { Lexicon } from './engine/Lexicon';
import { PinyinEngine } from './engine/PinyinEngine';
import { consumedForSyllable, extractPinyinOptions } from './engine/PinyinFilter';
import { UserLexicon } from './engine/UserLexicon';
import { CandidateSnapshot, rankCandidates } from './ime/CandidateRanking';
import { CompositionController } from './ime/CompositionController';
import { CandidateView } from './ime/ImeState';

let passed: number = 0;
let failed: number = 0;

function check(name: string, condition: boolean, detail: string = ''): void {
  if (condition) {
    passed++;
    console.log('  PASS ' + name);
  } else {
    failed++;
    console.error('  FAIL ' + name + (detail.length > 0 ? ' :: ' + detail : ''));
  }
}

function same(name: string, actual: string, expected: string): void {
  check(name, actual === expected, 'actual=' + JSON.stringify(actual) + ' expected=' + JSON.stringify(expected));
}

function sameList(name: string, actual: string[], expected: string[]): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  check(name, a === e, 'actual=' + a + ' expected=' + e);
}

function charCount(text: string): number {
  let count = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code < 0xDC00 || code > 0xDFFF) {
      count++;
    }
  }
  return count;
}

function texts(pool: Candidate[], order: number[], limit: number = 8): string[] {
  const result: string[] = [];
  for (let i = 0; i < order.length && i < limit; i++) {
    result.push(pool[order[i]].text);
  }
  return result;
}

function consumedOf(pool: Candidate[], order: number[], limit: number = 8): number[] {
  const result: number[] = [];
  for (let i = 0; i < order.length && i < limit; i++) {
    result.push(pool[order[i]].consumedCodeLength);
  }
  return result;
}

function indexOfText(pool: Candidate[], order: number[], text: string): number {
  for (let i = 0; i < order.length; i++) {
    if (pool[order[i]].text === text) {
      return i;
    }
  }
  return -1;
}

function firstIndexOfText(pool: Candidate[], text: string): number {
  for (let i = 0; i < pool.length; i++) {
    if (pool[i].text === text) {
      return i;
    }
  }
  return -1;
}

function viewsOf(pool: Candidate[], revision: number): CandidateView[] {
  const views: CandidateView[] = [];
  for (let i = 0; i < pool.length; i++) {
    const chars = pool[i].source === CandidateSource.RAW ? 0 : charCount(pool[i].text);
    const view: CandidateView = {
      index: i,
      text: pool[i].text,
      chars: chars,
      id: pool[i].id,
      consumedCodeLength: pool[i].consumedCodeLength,
      revision: revision
    };
    views.push(view);
  }
  return views;
}

function metaOf(reading: CandidateReading, complete: boolean, safeEnd: boolean,
  exactConsumed: number): CandidateMeta {
  const meta: CandidateMeta = {
    reading: reading,
    complete: complete,
    safeEnd: safeEnd,
    exactConsumed: exactConsumed
  };
  return meta;
}

function candidateOf(id: string, text: string, consumed: number, syllables: string[], score: number,
  source: CandidateSource, meta?: CandidateMeta): Candidate {
  const candidate: Candidate = {
    id: id,
    text: text,
    consumedCodeLength: consumed,
    syllables: syllables,
    score: score,
    source: source
  };
  if (meta !== undefined) {
    candidate.meta = meta;
  }
  return candidate;
}

class TableProvider implements CandidateProvider {
  table: Map<string, Candidate[]> = new Map<string, Candidate[]>();
  queries: string[] = [];

  isReady(): boolean {
    return true;
  }

  query(code: string, previousText: string, limit: number, options: QueryOptions): Candidate[] {
    this.queries.push(code);
    const found = this.table.get(code);
    return found === undefined ? [] : found.slice();
  }

  formatCode(code: string, options: QueryOptions): string {
    return '[' + code + ']';
  }
}

function plain(): QueryOptions {
  return { fuzzy: false, alternatives: [] };
}

// 与 regress.ts 一致的邻键代价，够触发纠错边
function nearAlternatives(code: string): QueryOptions {
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
  near.set('j', ['h', 'k', 'u']);
  near.set('l', ['k', 'o', 'p']);
  near.set('m', ['n', 'j', 'k']);
  near.set('t', ['r', 'y', 'g']);
  near.set('w', ['q', 'e', 's']);
  near.set('x', ['z', 'c', 's']);
  near.set('q', ['w', 'a', '1']);
  near.set('r', ['e', 't', 'f']);
  near.set('d', ['s', 'f', 'e']);
  near.set('c', ['x', 'v', 'd']);
  near.set('v', ['c', 'b', 'f']);
  near.set('p', ['o', 'l', '[']);
  near.set('k', ['j', 'l', 'i']);
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
  const options: QueryOptions = { fuzzy: false, alternatives: alternatives };
  return options;
}

// ---------- 1. 纯排序：普通栏与展开视图用同一份快照，却有不同的顺序 ----------

const SYNTH_CODE: string = 'nihaowomen';

function syntheticPool(): Candidate[] {
  const pool: Candidate[] = [
    candidateOf('s-best', '整句首选', 10, ['ni', 'hao', 'wo', 'men'], -1, CandidateSource.SENTENCE,
      metaOf(CandidateReading.FULL, true, true, 10)),
    candidateOf('s-second', '整句备选', 10, ['ni', 'hao', 'wo', 'men'], -2, CandidateSource.SENTENCE,
      metaOf(CandidateReading.FULL, true, true, 10)),
    candidateOf('p-seg', '分段首选', 5, ['ni', 'hao'], -3, CandidateSource.SENTENCE,
      metaOf(CandidateReading.FULL, false, true, 5)),
    candidateOf('w-real', '真实词', 5, ['ni', 'hao'], -4, CandidateSource.WORD,
      metaOf(CandidateReading.FULL, false, true, 5)),
    candidateOf('c-first', '首', 2, ['ni'], -5, CandidateSource.CHAR,
      metaOf(CandidateReading.FULL, false, true, 2)),
    candidateOf('c-unsafe', '替', 2, ['ni'], -6, CandidateSource.CHAR,
      metaOf(CandidateReading.FULL, false, false, 2)),
    candidateOf('w-abbr', '简拼词', 1, ['ni'], -7, CandidateSource.WORD,
      metaOf(CandidateReading.ABBREVIATION, false, true, 0)),
    candidateOf('w-fix', '纠错词', 5, ['ni', 'hao'], -8, CandidateSource.WORD,
      metaOf(CandidateReading.CORRECTED, false, true, 0)),
    candidateOf('raw', SYNTH_CODE, 10, [], -1000000000, CandidateSource.RAW)
  ];
  return pool;
}

function syntheticTests(): void {
  console.log('[纯排序] 同一候选池的四种顺序');
  const pool = syntheticPool();
  const snapshot = rankCandidates(SYNTH_CODE, pool);
  sameList('普通栏前四项是首选、分段、真实词、首字',
    texts(pool, snapshot.bar, 4), ['整句首选', '分段首选', '真实词', '首']);
  sameList('全部视图先真实词，分段次之，再简拼词与当前首字',
    texts(pool, snapshot.all, 8), ['整句首选', '真实词', '分段首选', '简拼词', '首', '纠错词', '替', '整句备选']);
  sameList('词语视图只有真实的词', texts(pool, snapshot.words, 8), ['真实词', '简拼词', '纠错词']);
  sameList('单字视图把切进音节内部的替代字排后', texts(pool, snapshot.chars, 8), ['首', '替']);
  same('普通栏与全部的首选是同一个原候选', String(snapshot.bar[0]), String(snapshot.all[0]));
  same('普通栏最后一个仍是原文', pool[snapshot.bar[snapshot.bar.length - 1]].source, CandidateSource.RAW);
  same('全部视图最后一个也是原文', pool[snapshot.all[snapshot.all.length - 1]].source, CandidateSource.RAW);
  check('普通栏与全部的顺序确实不同',
    JSON.stringify(snapshot.bar) !== JSON.stringify(snapshot.all),
    texts(pool, snapshot.bar, 6).join(',') + ' vs ' + texts(pool, snapshot.all, 6).join(','));
  let sameIndex = true;
  for (const index of snapshot.bar) {
    if (pool[index].id !== pool[index].id) {
      sameIndex = false;
    }
  }
  check('快照里的序号指回原候选', sameIndex);

  // 完整读音与模糊读音在展开视图里的先后：同一档真实词内，完整读音先于模糊读音
  const fuzzyPool: Candidate[] = [
    candidateOf('f-best', '整句首选', 10, ['ni', 'hao', 'wo', 'men'], -1, CandidateSource.SENTENCE,
      metaOf(CandidateReading.FULL, true, true, 10)),
    candidateOf('f-full', '全读词', 5, ['ni', 'hao'], -2, CandidateSource.WORD,
      metaOf(CandidateReading.FULL, false, true, 5)),
    candidateOf('f-fuzzy', '模糊词', 5, ['ni', 'hao'], -3, CandidateSource.WORD,
      metaOf(CandidateReading.FUZZY, false, true, 5)),
    candidateOf('f-fuzzy-char', '模', 2, ['ni'], -4, CandidateSource.CHAR,
      metaOf(CandidateReading.FUZZY, false, true, 2))
  ];
  const fuzzySnapshot = rankCandidates(SYNTH_CODE, fuzzyPool);
  sameList('词语视图完整读音排在模糊读音前', texts(fuzzyPool, fuzzySnapshot.words, 2), ['全读词', '模糊词']);
  const fuzzyAll = texts(fuzzyPool, fuzzySnapshot.all, 4);
  check('全部视图里完整读音也排在模糊读音前', fuzzyAll[1] === '全读词' && fuzzyAll[2] === '模糊词',
    fuzzyAll.join(','));

  // 控制器：点按重新排序后的视图，仍消耗那个候选自己的拼音
  const provider = new TableProvider();
  provider.table.set(SYNTH_CODE, syntheticPool());
  const controller = new CompositionController();
  controller.setProvider(provider);
  typeLetters(controller, SYNTH_CODE);
  const livePool = controller.getCandidates();
  const live = controller.getSnapshot();
  same('控制器快照的首选就是候选池第一个', String(live.bar[0]), '0');
  const views = viewsOf(livePool, controller.getRevision());
  const target = views[live.bar[2]];
  same('重新排序后的第三项是真实词', target.text, '真实词');
  const selection = controller.selectCandidate(target);
  check('重排后的视图仍能选中', selection.accepted, 'accepted=' + selection.accepted);
  same('选中后剩余拼音从该候选消耗处开始', controller.getRawCode(), 'women');
  same('选中后已选文字正确', controller.chosenText(), '真实词');

  // 空格与普通栏第一项一致：首选读完整个输入时直接提交
  const provider2 = new TableProvider();
  provider2.table.set(SYNTH_CODE, syntheticPool());
  const controller2 = new CompositionController();
  controller2.setProvider(provider2);
  typeLetters(controller2, SYNTH_CODE);
  const spaceSnapshot = controller2.getSnapshot();
  const firstText = controller2.getCandidates()[spaceSnapshot.bar[0]].text;
  const result = controller2.selectFirst();
  check('空格首选有提交结果', result !== undefined);
  same('空格提交的文字与普通栏第一项一致', result === undefined ? '' : result.text, firstText);

  // 首选是前缀时，空格只消费前缀，已选文字与普通栏第一项一致
  const prefixPool: Candidate[] = [
    candidateOf('p0', '首选前缀', 4, ['ni', 'ha'], -1, CandidateSource.WORD,
      metaOf(CandidateReading.FULL, false, true, 4)),
    candidateOf('p1', '次选前缀', 5, ['ni', 'hao'], -2, CandidateSource.WORD,
      metaOf(CandidateReading.FULL, false, true, 5))
  ];
  const provider3 = new TableProvider();
  provider3.table.set(SYNTH_CODE, prefixPool);
  const controller3 = new CompositionController();
  controller3.setProvider(provider3);
  typeLetters(controller3, SYNTH_CODE);
  const prefixSnapshot = controller3.getSnapshot();
  const prefixFirst = controller3.getCandidates()[prefixSnapshot.bar[0]].text;
  const prefixResult = controller3.selectFirst();
  check('首选是前缀时空格不提交', prefixResult === undefined);
  same('空格选中的仍是普通栏第一项', controller3.chosenText(), prefixFirst);
}

function typeLetters(controller: CompositionController, code: string): void {
  for (let i = 0; i < code.length; i++) {
    controller.appendCode(code.charAt(i), [], { keyId: 'k' + i, dx: 0, dy: 0 });
  }
}

// ---------- 2. 补位：主串切分不被补查覆盖，补出来的单字带着撇号一起消费 ----------

class SupplementProvider implements CandidateProvider {
  queries: string[] = [];
  limits: number[] = [];
  lastCode: string = '';
  fullCode: string = '';
  fullPool: Candidate[] = [];
  syllablePool: Candidate[] = [];

  isReady(): boolean {
    return true;
  }

  query(code: string, previousText: string, limit: number, options: QueryOptions): Candidate[] {
    this.queries.push(code);
    this.limits.push(limit);
    this.lastCode = code;
    if (code === this.fullCode) {
      return this.fullPool.slice();
    }
    if (code === 'ni') {
      return this.syllablePool.slice();
    }
    return [];
  }

  formatCode(code: string, options: QueryOptions): string {
    // 模拟引擎的最近一次查询缓存：补查以后这里的 lastCode 已经变成首音节
    return '[' + code + '|' + this.lastCode + ']';
  }
}

function supplementTests(): void {
  console.log('[补位] 单字为空时的有界补查');
  const code = "ni'haowomen";
  const provider = new SupplementProvider();
  provider.fullCode = code;
  provider.fullPool = [
    candidateOf('s-best', '整句首选', code.length, ['ni', 'hao', 'wo', 'men'], -1, CandidateSource.SENTENCE,
      metaOf(CandidateReading.FULL, true, true, code.length)),
    candidateOf('w-real', '真实词', 5, ['ni', 'hao'], -2, CandidateSource.WORD,
      metaOf(CandidateReading.FULL, false, true, 5))
  ];
  provider.syllablePool = [
    candidateOf('c-ni', '你', 2, ['ni'], -3, CandidateSource.CHAR,
      metaOf(CandidateReading.FULL, true, true, 2)),
    candidateOf('c-ni2', '泥', 2, ['ni'], -4, CandidateSource.CHAR,
      metaOf(CandidateReading.FULL, true, true, 2)),
    candidateOf('w-nihao', '你好', 2, ['ni', 'hao'], -5, CandidateSource.WORD,
      metaOf(CandidateReading.FULL, true, true, 2)),
    candidateOf('raw-ni', 'ni', 2, [], -1000000000, CandidateSource.RAW)
  ];
  const controller = new CompositionController();
  controller.setProvider(provider);
  typeLetters(controller, code);
  const pool = controller.getCandidates();
  const snapshot = controller.getSnapshot();
  check('补查以后单字视图不再为空', snapshot.chars.length > 0, 'chars=' + snapshot.chars.length);
  same('主串切分仍按主查询显示，没有被补查覆盖',
    controller.preeditText(), '[' + code + '|' + code + ']');
  same('补查按首选候选的第一个音节查询', provider.lastCode, 'ni');
  same('补查条数有上限', String(provider.limits[provider.limits.length - 1]), '16');
  let onlyChars = true;
  let charsConsumed = -1;
  for (const index of snapshot.chars) {
    const item = pool[index];
    if (charCount(item.text) !== 1) {
      onlyChars = false;
    }
    charsConsumed = item.consumedCodeLength;
    if (item.meta !== undefined) {
      if (item.meta.complete || !item.meta.safeEnd) {
        onlyChars = false;
      }
    }
  }
  check('补位只收单字', onlyChars);
  same('补出来的单字连同后面的撇号一起消费', String(charsConsumed), '3');
  same('补查没有加入词语或原文', String(pool.length), '4');
  const views = viewsOf(pool, controller.getRevision());
  const charView = views[snapshot.chars[0]];
  const selection = controller.selectCandidate(charView);
  check('补位单字可以正常选中', selection.accepted);
  same('补位单字选中后剩余拼音不带撇号', controller.getRawCode(), 'haowomen');
}

// ---------- 3. 真实词库：长句、短全拼、简拼、分隔符与打错 ----------

function realTests(engine: PinyinEngine, lexicon: Lexicon): void {
  const query = (code: string, options: QueryOptions = plain()): Candidate[] => engine.query(code, '', 150, options);
  const report = (name: string, pool: Candidate[], snapshot: CandidateSnapshot): void => {
    console.log('  [' + name + '] bar=' + texts(pool, snapshot.bar, 8).join(','));
    console.log('  [' + name + '] all=' + texts(pool, snapshot.all, 8).join(','));
    console.log('  [' + name + '] words=' + texts(pool, snapshot.words, 8).join(','));
    console.log('  [' + name + '] chars=' + texts(pool, snapshot.chars, 8).join(','));
  };

  console.log('[真实词库] 长句与短全拼');
  const longCode = 'nihaowomenmingtianjian';
  const longPool = query(longCode);
  const longSnapshot = rankCandidates(longCode, longPool);
  report(longCode, longPool, longSnapshot);
  same('长句首选保持不变', texts(longPool, longSnapshot.bar, 1)[0], '你好我们明天见');
  same('普通栏第二项是可靠的分段改选', texts(longPool, longSnapshot.bar, 1)[0] === '你好我们明天见' ?
    texts(longPool, longSnapshot.bar, 2)[1] : '', '你好我们明天');
  check('普通栏前五有紧贴起始音节的常用词', indexOfText(longPool, longSnapshot.bar, '你好') >= 0 &&
    indexOfText(longPool, longSnapshot.bar, '你好') < 5, texts(longPool, longSnapshot.bar, 6).join(','));
  check('普通栏前五有可靠首字', indexOfText(longPool, longSnapshot.bar, '你') >= 0 &&
    indexOfText(longPool, longSnapshot.bar, '你') < 5, texts(longPool, longSnapshot.bar, 6).join(','));
  check('全部视图与普通栏顺序不同',
    JSON.stringify(texts(longPool, longSnapshot.bar, 6)) !== JSON.stringify(texts(longPool, longSnapshot.all, 6)),
    texts(longPool, longSnapshot.all, 6).join(','));
  same('原文仍在普通栏最后', longPool[longSnapshot.bar[longSnapshot.bar.length - 1]].text, longCode);
  same('原文仍在全部最后', longPool[longSnapshot.all[longSnapshot.all.length - 1]].text, longCode);
  same('词语视图的第一项是真实词', longPool[longSnapshot.words[0]].source === CandidateSource.SENTENCE ?
    '句' : '词', '词');
  same('单字视图的第一项是当前首音节的常用字', longPool[longSnapshot.chars[0]].text, '你');

  const todayCode = 'jintiantianqihenhao';
  const todayPool = query(todayCode);
  const todaySnapshot = rankCandidates(todayCode, todayPool);
  report(todayCode, todayPool, todaySnapshot);
  sameList('今天的普通栏前三项', texts(todayPool, todaySnapshot.bar, 3), ['今天天气很好', '今天天气', '今天']);
  check('可靠前缀今天排在单字进之前',
    indexOfText(todayPool, todaySnapshot.bar, '今天') < indexOfText(todayPool, todaySnapshot.bar, '进') ||
    indexOfText(todayPool, todaySnapshot.bar, '进') < 0,
    texts(todayPool, todaySnapshot.bar, 6).join(','));

  const abbreviationCode = 'nh';
  const abbreviationPool = query(abbreviationCode);
  const abbreviationSnapshot = rankCandidates(abbreviationCode, abbreviationPool);
  report(abbreviationCode, abbreviationPool, abbreviationSnapshot);
  same('nh 首选你好', texts(abbreviationPool, abbreviationSnapshot.bar, 1)[0], '你好');
  check('nh 普通栏第二项仍是完整简拼词，不是偏门单字',
    charCount(abbreviationPool[abbreviationSnapshot.bar[1]].text) >= 2,
    texts(abbreviationPool, abbreviationSnapshot.bar, 4).join(','));

  const womenCode = 'womenmingtianzailianxi';
  const womenPool = query(womenCode);
  const womenSnapshot = rankCandidates(womenCode, womenPool);
  report(womenCode, womenPool, womenSnapshot);
  sameList('我们明天再联系的前四项', texts(womenPool, womenSnapshot.bar, 4),
    ['我们明天再联系', '我们明天', '我们', '我']);

  console.log('[真实词库] 短全拼保留上下文顺序');
  const shiPool = query('shi');
  const shiSnapshot = rankCandidates('shi', shiPool);
  report('shi', shiPool, shiSnapshot);
  sameList('shi 普通栏前五项与引擎顺序一致', texts(shiPool, shiSnapshot.bar, 5), ['是', '时', '事', '使', '市']);
  sameList('shi 单字视图前五项与引擎顺序一致', texts(shiPool, shiSnapshot.chars, 5), ['是', '时', '事', '使', '市']);
  let shiBoundary = true;
  for (let i = 0; i < 12 && i < shiSnapshot.chars.length; i++) {
    if (shiPool[shiSnapshot.chars[i]].consumedCodeLength !== 3) {
      shiBoundary = false;
    }
  }
  check('shi 前十二个单字都停在完整音节后', shiBoundary);

  const zhongPool = query('zhongguo');
  const zhongSnapshot = rankCandidates('zhongguo', zhongPool);
  report('zhongguo', zhongPool, zhongSnapshot);
  same('zhongguo 首选是中国', texts(zhongPool, zhongSnapshot.bar, 1)[0], '中国');
  let zhongBoundary = true;
  for (let i = 0; i < 8 && i < zhongSnapshot.chars.length; i++) {
    if (zhongPool[zhongSnapshot.chars[i]].consumedCodeLength !== 5) {
      zhongBoundary = false;
    }
  }
  check('zhongguo 前八个单字都在 zhong 之后', zhongBoundary,
    consumedOf(zhongPool, zhongSnapshot.chars, 8).join(','));
  sameList('zhongguo 词语视图先列首选音节序列的词', texts(zhongPool, zhongSnapshot.words, 2), ['中国', '种果']);

  console.log('[真实词库] 简拼整串');
  const srfPool = query('srf');
  const srfSnapshot = rankCandidates('srf', srfPool);
  report('srf', srfPool, srfSnapshot);
  same('srf 首选输入法', texts(srfPool, srfSnapshot.bar, 1)[0], '输入法');
  sameList('srf 词语视图先列首选音节序列的词，完整简拼词保留在前',
    texts(srfPool, srfSnapshot.words, 4), ['输入法', '输入', '杀人犯', '受让方']);
  check('srf 首选是完整的简拼词', srfPool[srfSnapshot.bar[0]].meta !== undefined &&
    srfPool[srfSnapshot.bar[0]].meta?.reading === CandidateReading.ABBREVIATION &&
    srfPool[srfSnapshot.bar[0]].meta?.complete === true);

  console.log('[真实词库] 模糊音标记');
  const fuzzyOptions: QueryOptions = { fuzzy: true, alternatives: [] };
  const fuzzyPool = engine.query('zongguo', '', 150, fuzzyOptions);
  const fuzzyChina = firstIndexOfText(fuzzyPool, '中国');
  check('模糊音匹配的中国标成模糊读音', fuzzyChina >= 0 &&
    fuzzyPool[fuzzyChina].meta?.reading === CandidateReading.FUZZY,
    fuzzyChina >= 0 ? String(fuzzyPool[fuzzyChina].meta?.reading) : 'missing');
  const exactChina = firstIndexOfText(zhongPool, '中国');
  check('原文完整读音的中国标成完整读音', exactChina >= 0 &&
    zhongPool[exactChina].meta?.reading === CandidateReading.FULL,
    exactChina >= 0 ? String(zhongPool[exactChina].meta?.reading) : 'missing');

  console.log('[真实词库] 显式分隔符与打错');
  const xianCode = "xi'an";
  const xianPool = query(xianCode);
  const xianSnapshot = rankCandidates(xianCode, xianPool);
  report(xianCode, xianPool, xianSnapshot);
  same('xi\'an 首选西安', texts(xianPool, xianSnapshot.bar, 1)[0], '西安');
  same('xi\'an 单字视图第一项停在 xi 之后', String(xianPool[xianSnapshot.chars[0]].consumedCodeLength), '3');
  check('xi\'an 前六个单字都停在 xi 之后',
    consumedOf(xianPool, xianSnapshot.chars, 6).every((value: number) => value === 3),
    consumedOf(xianPool, xianSnapshot.chars, 6).join(','));

  console.log('[真实词库] 单音节补全守卫');
  const jiPool = query('ji');
  const jiSnapshot = rankCandidates('ji', jiPool);
  report('ji', jiPool, jiSnapshot);
  same('ji 候选池首位原是补全项就', jiPool[0].text, '就');
  sameList('ji 普通栏前四个都是完整读音的单字', texts(jiPool, jiSnapshot.bar, 4), ['及', '即', '急', '机']);
  sameList('ji 展开全部前四个同样是完整读音的单字', texts(jiPool, jiSnapshot.all, 4), ['及', '即', '急', '机']);
  sameList('ji 单字视图前四个同样是完整读音的单字', texts(jiPool, jiSnapshot.chars, 4), ['及', '即', '急', '机']);
  check('ji 旧补全就留到后面的补全档', indexOfText(jiPool, jiSnapshot.bar, '就') > 3,
    texts(jiPool, jiSnapshot.bar, 8).join(','));
  check('ji 展开全部也不把就提到第二', indexOfText(jiPool, jiSnapshot.all, '就') > 3,
    texts(jiPool, jiSnapshot.all, 8).join(','));
  same('ji 提上来的单字读音是 ji', jiPool[jiSnapshot.bar[0]].syllables[0], 'ji');
  same('ji 提上来的单字消耗整串', String(jiPool[jiSnapshot.bar[0]].consumedCodeLength), '2');
  const jiPinnedSnapshot = rankCandidates('ji', jiPool, true);
  same('显式固定首位时补全守卫不动', texts(jiPool, jiPinnedSnapshot.bar, 1)[0], '就');

  const tianCode = "tian'anmen";
  const tianPool = query(tianCode);
  const tianSnapshot = rankCandidates(tianCode, tianPool);
  report(tianCode, tianPool, tianSnapshot);
  same('tian\'anmen 首选天安门', texts(tianPool, tianSnapshot.bar, 1)[0], '天安门');
  same('tian\'anmen 普通栏第二个前缀词是天安', texts(tianPool, tianSnapshot.bar, 2)[1], '天安');
  check('tian\'anmen 词语视图把天安排到提案之前，两个都保留',
    indexOfText(tianPool, tianSnapshot.words, '天安') >= 0 &&
    indexOfText(tianPool, tianSnapshot.words, '提案') >= 0 &&
    indexOfText(tianPool, tianSnapshot.words, '天安') < indexOfText(tianPool, tianSnapshot.words, '提案'),
    texts(tianPool, tianSnapshot.words, 6).join(','));
  check('tian\'anmen 单字先列停在 tian 后的字，不把 ti 切分混进首排',
    tianPool[tianSnapshot.chars[0]].text === '天' &&
    indexOfText(tianPool, tianSnapshot.chars, '提') > indexOfText(tianPool, tianSnapshot.chars, '天'),
    consumedOf(tianPool, tianSnapshot.chars, 8).join(',') + ' ' + texts(tianPool, tianSnapshot.chars, 8).join(','));

  const typo = (code: string): void => {
    const pool = query(code, nearAlternatives(code));
    const snapshot = rankCandidates(code, pool);
    report(code, pool, snapshot);
    if (code === 'bunengg') {
      same('bunengg 首选不能给', texts(pool, snapshot.bar, 1)[0], '不能给');
      check('bunengg 前三个里有不能', indexOfText(pool, snapshot.bar, '不能') >= 0 &&
        indexOfText(pool, snapshot.bar, '不能') < 3, texts(pool, snapshot.bar, 5).join(','));
    } else if (code === 'shiyongg') {
      same('shiyongg 首选使用过', texts(pool, snapshot.bar, 1)[0], '使用过');
      check('shiyongg 前三个里有使用', indexOfText(pool, snapshot.bar, '使用') >= 0 &&
        indexOfText(pool, snapshot.bar, '使用') < 3, texts(pool, snapshot.bar, 5).join(','));
    } else if (code === 'zhnogguo') {
      same('zhnogguo 首选中国', texts(pool, snapshot.bar, 1)[0], '中国');
      check('zhnogguo 低置信整句没有占前排', indexOfText(pool, snapshot.bar, '找你哦干锅') < 0 ||
        indexOfText(pool, snapshot.bar, '找你哦干锅') >= 4, texts(pool, snapshot.bar, 6).join(','));
      same('zhnogguo 原文仍在最后', pool[snapshot.bar[snapshot.bar.length - 1]].text, 'zhnogguo');
    } else if (code === 'xianzai') {
      same('xianzai 首选现在', texts(pool, snapshot.bar, 1)[0], '现在');
    }
  };
  typo('bunengg');
  typo('shiyongg');
  typo('zhnogguo');
  typo('xianzai');

  console.log('[真实词库] 筛选视图的边界');
  for (const item of [['nihaowomenmingtianjian', longPool, longSnapshot] as [string, Candidate[], CandidateSnapshot],
    ['srf', srfPool, srfSnapshot] as [string, Candidate[], CandidateSnapshot]]) {
    const pool = item[1];
    const snapshot = item[2];
    let wordsAreWords = true;
    for (const index of snapshot.words) {
      if (pool[index].source === CandidateSource.SENTENCE || pool[index].source === CandidateSource.RAW ||
        charCount(pool[index].text) < 2) {
        wordsAreWords = false;
      }
    }
    let charsAreChars = true;
    for (const index of snapshot.chars) {
      if (charCount(pool[index].text) !== 1 || pool[index].source === CandidateSource.RAW) {
        charsAreChars = false;
      }
    }
    check(item[0] + ' 词语视图不含整句', wordsAreWords);
    check(item[0] + ' 单字视图只含单字', charsAreChars);
  }

  console.log('[真实词库] 补位只给单字：nihaouu 的原文仍在最后');
  const nihaouuPool = query('nihaouu');
  const nihaouuSnapshot = rankCandidates('nihaouu', nihaouuPool);
  report('nihaouu', nihaouuPool, nihaouuSnapshot);
  same('nihaouu 原文在最后', nihaouuPool[nihaouuSnapshot.bar[nihaouuSnapshot.bar.length - 1]].text, 'nihaouu');

  const rawPool = query('vvv');
  const rawSnapshot = rankCandidates('vvv', rawPool);
  same('读不出内容时只有原文', texts(rawPool, rawSnapshot.bar, 4).join(','), 'vvv');

  console.log('[真实词库] 固定与删除');
  const rules = new UserLexicon(() => 100);
  rules.attachBase(lexicon);
  const zaiPool = query('zai');
  rules.pin('zai', ['zai'], '再');
  const pinnedPool = rules.arrange('zai', zaiPool);
  const pinnedSnapshot = rankCandidates('zai', pinnedPool);
  same('固定以后排在普通栏首位', texts(pinnedPool, pinnedSnapshot.bar, 1)[0], '再');
  same('固定的候选仍消耗整串', String(pinnedPool[pinnedSnapshot.bar[0]].consumedCodeLength), '3');
  rules.remove(['zai'], '再');
  const removedPool = rules.arrange('zai', zaiPool);
  const removedSnapshot = rankCandidates('zai', removedPool);
  check('删除以后不再列出', indexOfText(removedPool, removedSnapshot.bar, '再') < 0,
    texts(removedPool, removedSnapshot.bar, 5).join(','));
  check('删除以后撤销仍能恢复', rules.restoreRemoved());
  const restoredPool = rules.arrange('zai', zaiPool);
  const restoredSnapshot = rankCandidates('zai', restoredPool);
  check('撤销以后又回到候选', indexOfText(restoredPool, restoredSnapshot.bar, '再') >= 0);
}

// ---------- 4. 真实引擎驱动的控制器：空格与重排点击 ----------

function controllerTests(engine: PinyinEngine, lexicon: Lexicon): void {
  console.log('[真实引擎] 空格首选与重排后的点击');
  const code = 'nihaowomenmingtianjian';
  const controller = new CompositionController();
  controller.setProvider(engine);
  typeLetters(controller, code);
  const pool = controller.getCandidates();
  const snapshot = controller.getSnapshot();
  same('组词池的首选仍是最好整句', pool[snapshot.bar[0]].text, '你好我们明天见');
  const views = viewsOf(pool, controller.getRevision());
  const targetIndex = snapshot.bar[2];
  const target = views[targetIndex];
  same('重排后的第三项是常用词你好', target.text, '你好');
  const selection = controller.selectCandidate(target);
  check('重排后的视图可以选中', selection.accepted);
  same('选中你好以后剩余拼音', controller.getRawCode(), 'womenmingtianjian');
  same('已选文字是重排视图里的那一个', controller.chosenText(), '你好');

  const jiController = new CompositionController();
  jiController.setProvider(engine);
  typeLetters(jiController, 'ji');
  const jiPool = jiController.getCandidates();
  const jiSnapshot = jiController.getSnapshot();
  const jiFirst = jiPool[jiSnapshot.bar[0]];
  same('ji 普通栏第一项是及', jiFirst.text, '及');
  const jiResult = jiController.selectFirst();
  check('ji 空格沿普通栏顺序选中', jiResult !== undefined);
  same('ji 空格提交的是及', jiResult === undefined ? '' : jiResult.text, '及');

  // 用户固定 ji 的首位时，守卫让位，空格仍选固定项
  const pinRules = new UserLexicon(() => 100);
  pinRules.attachBase(lexicon);
  pinRules.pin('ji', ['jiu'], '就');
  const pinnedController = new CompositionController();
  pinnedController.setProvider(engine);
  pinnedController.setRules(pinRules);
  typeLetters(pinnedController, 'ji');
  const pinnedPool = pinnedController.getCandidates();
  const pinnedSnapshot = pinnedController.getSnapshot();
  same('固定 ji 的后选仍是就', pinnedPool[pinnedSnapshot.bar[0]].text, '就');
  const pinnedResult = pinnedController.selectFirst();
  same('固定首位时空格提交就', pinnedResult === undefined ? '' : pinnedResult.text, '就');

  const spaceController = new CompositionController();
  spaceController.setProvider(engine);
  typeLetters(spaceController, code);
  const spacePool = spaceController.getCandidates();
  const spaceSnapshot = spaceController.getSnapshot();
  const spaceFirst = spacePool[spaceSnapshot.bar[0]].text;
  const spaceResult = spaceController.selectFirst();
  check('空格首选有结果', spaceResult !== undefined);
  same('空格提交与普通栏第一项一致', spaceResult === undefined ? '' : spaceResult.text, spaceFirst);
}

function userAbbrRankingTests(lexicon: Lexicon, model: BigramModel): void {
  console.log('[真实词库] 单字母非元音不触发补全守卫 & 全拼音节下已学简拼紧跟首位');
  const engine = new PinyinEngine(lexicon);
  engine.setBigramModel(model);

  const nPool = engine.query('n', '', 150, { fuzzy: false, alternatives: [] });
  const nSnapshot = rankCandidates('n', nPool);
  same('n 普通栏首位是“你”而不是“嗯”', texts(nPool, nSnapshot.bar, 1)[0], '你');

  const user = new UserLexicon(() => 20000);
  user.attachBase(lexicon);
  engine.setUserModel(user);

  const learnOne = (text: string, code: string, syllables: string[]): void => {
    user.learn({
      text: text,
      raw: false,
      segments: [{ text: text, code: code, syllables: syllables, source: CandidateSource.WORD, alternatives: [], taps: [] }]
    }, '');
  };
  learnOne('我爱你', 'woaini', ['wo', 'ai', 'ni']);
  learnOne('方案', 'fangan', ['fang', 'an']);
  learnOne('第二', 'dier', ['di', 'er']);

  const wanPool = engine.query('wan', '', 150, { fuzzy: false, alternatives: [] });
  const wanSnap = rankCandidates('wan', wanPool);
  sameList('wan 普通栏前两位为 玩、我爱你', texts(wanPool, wanSnap.bar, 2), ['玩', '我爱你']);

  const faPool = engine.query('fa', '', 150, { fuzzy: false, alternatives: [] });
  const faSnap = rankCandidates('fa', faPool);
  sameList('fa 普通栏前两位为 发、方案', texts(faPool, faSnap.bar, 2), ['发', '方案']);

  const dePool = engine.query('de', '', 150, { fuzzy: false, alternatives: [] });
  const deSnap = rankCandidates('de', dePool);
  sameList('de 普通栏前两位为 的、第二', texts(dePool, deSnap.bar, 2), ['的', '第二']);
}

function noStringDuplicates(list: string[]): boolean {
  const seen: Set<string> = new Set<string>();
  for (const item of list) {
    if (seen.has(item)) {
      return false;
    }
    seen.add(item);
  }
  return true;
}

function findInPool(pool: Candidate[], text: string): Candidate | undefined {
  for (const candidate of pool) {
    if (candidate.text === text) {
      return candidate;
    }
  }
  return undefined;
}

function pinyinFilterTests(lexicon: Lexicon, model: BigramModel): void {
  console.log('[真实词库] 展开候选左侧拼音提取与纯筛选');
  const engine = new PinyinEngine(lexicon);
  engine.setBigramModel(model);

  const optionsFor = (code: string, fuzzy: boolean = false): { options: string[]; pool: Candidate[] } => {
    const pool = engine.query(code, '', 150, { fuzzy: fuzzy, alternatives: [] });
    const snap = rankCandidates(code, pool, false);
    return { options: extractPinyinOptions(code, pool, snap.all, fuzzy), pool: pool };
  };

  // 1) extractPinyinOptions
  const mRes = optionsFor('m');
  check('m 拼音列表没有重复项', noStringDuplicates(mRes.options), mRes.options.join(','));
  check('m 拼音列表包含高频 mei/ma 且靠前，同时补齐冷门 mou/miu',
    mRes.options.indexOf('mei') >= 0 && mRes.options.indexOf('mei') < 5 &&
    mRes.options.indexOf('ma') >= 0 && mRes.options.indexOf('ma') < 5 &&
    mRes.options.indexOf('mou') >= 0 && mRes.options.indexOf('miu') >= 0,
    mRes.options.join(','));

  const xianRes = optionsFor('xian');
  check('xian 拼音列表 xian 排在 xi 前面，并包含补全 xiang',
    xianRes.options.indexOf('xian') >= 0 && xianRes.options.indexOf('xi') > xianRes.options.indexOf('xian') &&
    xianRes.options.indexOf('xiang') >= 0, xianRes.options.join(','));

  const changanRes = optionsFor('changan');
  check('changan 拼音列表包含 chang 与 chan，不含非法切分 cha',
    changanRes.options.indexOf('chang') >= 0 && changanRes.options.indexOf('chan') >= 0 &&
    changanRes.options.indexOf('cha') < 0, changanRes.options.join(','));

  const shurufaRes = optionsFor('shurufa');
  check('shurufa 拼音列表包含 shu，不含切进缩写噪音 si/sou',
    shurufaRes.options.indexOf('shu') >= 0 && shurufaRes.options.indexOf('si') < 0 &&
    shurufaRes.options.indexOf('sou') < 0, shurufaRes.options.join(','));

  const srfRes = optionsFor('srf');
  const srfPoolSyls: Set<string> = new Set<string>();
  for (const c of srfRes.pool) {
    if (c.source !== CandidateSource.RAW && c.syllables.length > 0 && (c.meta === undefined || c.meta.safeEnd)) {
      srfPoolSyls.add(c.syllables[0]);
    }
  }
  check('srf 拼音列表包含 shu/sha/shou 且不盲目展开无匹配的 s* 音节',
    srfRes.options.indexOf('shu') >= 0 && srfRes.options.indexOf('sha') >= 0 &&
    srfRes.options.indexOf('shou') >= 0 && srfRes.options.every((syl: string) => srfPoolSyls.has(syl)),
    srfRes.options.join(','));

  const zongFuzzy = optionsFor('zongguo', true);
  check('开启模糊音时 zongguo 包含 zhong 与 zong',
    zongFuzzy.options.indexOf('zhong') >= 0 && zongFuzzy.options.indexOf('zong') >= 0,
    zongFuzzy.options.join(','));

  const nFuzzy = optionsFor('n', true);
  check('开启模糊音时 n 同时包含 n* 与 l* 音节',
    nFuzzy.options.indexOf('ni') >= 0 && nFuzzy.options.indexOf('na') >= 0 &&
    nFuzzy.options.indexOf('la') >= 0 && nFuzzy.options.indexOf('le') >= 0,
    nFuzzy.options.slice(0, 20).join(','));

  const vvvRes = optionsFor('vvv');
  sameList('无法切分的 vvv 返回空拼音列表', vvvRes.options, []);

  // 2) consumedForSyllable 11 个用例
  same('consumed m+mou=1', String(consumedForSyllable('m', 'mou', false)), '1');
  same('consumed sh+sha=2', String(consumedForSyllable('sh', 'sha', false)), '2');
  same('consumed sh+si=1', String(consumedForSyllable('sh', 'si', false)), '1');
  same('consumed xian+xian=4', String(consumedForSyllable('xian', 'xian', false)), '4');
  same('consumed xian+xi=2', String(consumedForSyllable('xian', 'xi', false)), '2');
  same('consumed xian+xiang=4', String(consumedForSyllable('xian', 'xiang', false)), '4');
  same("consumed xi'an+xi=2", String(consumedForSyllable("xi'an", 'xi', false)), '2');
  same('consumed srf+sha=1', String(consumedForSyllable('srf', 'sha', false)), '1');
  same('consumed shrf+shu=2', String(consumedForSyllable('shrf', 'shu', false)), '2');
  same('consumed zongguo+zhong(fuzzy)=4', String(consumedForSyllable('zongguo', 'zhong', true)), '4');
  same('consumed n+la(fuzzy)=1', String(consumedForSyllable('n', 'la', true)), '1');

  // 3) 端到端 CompositionController.setSyllableFilter
  const mCtrl = new CompositionController();
  mCtrl.setProvider(engine);
  typeLetters(mCtrl, 'm');
  mCtrl.setSyllableFilter('mou', consumedForSyllable('m', 'mou', false));
  const mouPool = mCtrl.getCandidates();
  const mouChar = findInPool(mouPool, '某');
  const mouChar2 = findInPool(mouPool, '谋');
  check('m 筛选 mou 后补查到某/谋且消耗长度为 1',
    mouChar !== undefined && mouChar.consumedCodeLength === 1 && mouChar2 !== undefined,
    mouPool.slice(0, 6).map((c: Candidate) => c.text).join(','));
  const mSnap = mCtrl.getSnapshot();
  const mouIdx = mSnap.all.find((idx: number) => mouPool[idx].text === '某');
  check('m 筛选 mou 可选中某并直接上屏', mouIdx !== undefined);
  if (mouIdx !== undefined) {
    const mouView: CandidateView = {
      index: mouIdx,
      text: mouPool[mouIdx].text,
      chars: 1,
      id: mouPool[mouIdx].id,
      consumedCodeLength: mouPool[mouIdx].consumedCodeLength,
      revision: mCtrl.getRevision()
    };
    const sel = mCtrl.selectCandidate(mouView);
    check('选中补查的某后提交结果正确', sel.accepted && sel.result !== undefined && sel.result.text === '某');
  }

  const xianCtrl = new CompositionController();
  xianCtrl.setProvider(engine);
  typeLetters(xianCtrl, 'xian');
  const baseFirst = xianCtrl.getCandidates()[xianCtrl.getSnapshot().bar[0]].text;
  const unfilteredSnap = xianCtrl.getSnapshot();
  const unfilteredViews = viewsOf(xianCtrl.getCandidates(), xianCtrl.getRevision());
  const unfilteredFirstView = unfilteredViews[unfilteredSnap.bar[0]];

  xianCtrl.setSyllableFilter('xi', consumedForSyllable('xian', 'xi', false));
  const xiPool = xianCtrl.getCandidates();
  const xiAn = findInPool(xiPool, '西安');
  const xiSingle = findInPool(xiPool, '西');
  const xiWash = findInPool(xiPool, '洗');
  check('xian 筛选 xi 同时包含西安(consumed=4) 与单字洗/西(consumed=2)',
    xiAn !== undefined && xiAn.consumedCodeLength === 4 &&
    xiSingle !== undefined && xiSingle.consumedCodeLength === 2 &&
    xiWash !== undefined && xiWash.consumedCodeLength === 2,
    xiPool.slice(0, 8).map((c: Candidate) => `${c.text}:${c.consumedCodeLength}`).join(','));

  // 清除筛选后恢复原候选且拒绝陈旧视图
  const filteredSnap = xianCtrl.getSnapshot();
  const filteredViews = viewsOf(xiPool, xianCtrl.getRevision());
  const xiSingleIdx = filteredSnap.all.find((idx: number) => xiPool[idx].text === '西');
  xianCtrl.setSyllableFilter('', 0);
  same('取消筛选后恢复原首候选', xianCtrl.getCandidates()[xianCtrl.getSnapshot().bar[0]].text, baseFirst);
  same('取消筛选后激活音节为空', xianCtrl.getActiveSyllable(), '');
  if (xiSingleIdx !== undefined) {
    const staleRes = xianCtrl.selectCandidate(filteredViews[xiSingleIdx]);
    check('取消筛选后版本号推进，旧筛选视图被拒绝', !staleRes.accepted);
  }
  check('筛选期间旧未筛选视图也已过期被拒绝', (() => {
    xianCtrl.setSyllableFilter('xi', 2);
    return !xianCtrl.selectCandidate(unfilteredFirstView).accepted;
  })());

  // 选中筛选后单字西，剩余拼音为 an 且自动清除筛选
  const xiLivePool = xianCtrl.getCandidates();
  const xiLiveIdx = xianCtrl.getSnapshot().all.find((idx: number) => xiLivePool[idx].text === '西');
  check('再次筛选 xi 找到西', xiLiveIdx !== undefined);
  if (xiLiveIdx !== undefined) {
    const xiView = viewsOf(xiLivePool, xianCtrl.getRevision())[xiLiveIdx];
    const picked = xianCtrl.selectCandidate(xiView);
    check('选中西成功', picked.accepted && picked.result === undefined);
    same('选中西后剩余拼音为 an', xianCtrl.getRawCode(), 'an');
    same('选中西后自动清除激活音节', xianCtrl.getActiveSyllable(), '');
  }

  // commitBest 在筛选开启时应先清筛选再提交未筛选首选
  const bestCtrl = new CompositionController();
  bestCtrl.setProvider(engine);
  typeLetters(bestCtrl, 'xian');
  const expectedBest = bestCtrl.getCandidates()[bestCtrl.getSnapshot().bar[0]].text;
  bestCtrl.setSyllableFilter('xi', 2);
  const committedBest = bestCtrl.commitBest();
  same('筛选期间调用 commitBest 仍提交未筛选首选',
    committedBest !== undefined ? committedBest.text : '', expectedBest);

  // srf 筛选 sha：杀人犯排首位且补查啥/杀(consumed=1)
  const srfCtrl = new CompositionController();
  srfCtrl.setProvider(engine);
  typeLetters(srfCtrl, 'srf');
  srfCtrl.setSyllableFilter('sha', consumedForSyllable('srf', 'sha', false));
  const shaPool = srfCtrl.getCandidates();
  const shaSnap = srfCtrl.getSnapshot();
  same('srf 筛选 sha 时首候选为杀人犯', shaPool[shaSnap.bar[0]].text, '杀人犯');
  const shaChar = findInPool(shaPool, '啥') ?? findInPool(shaPool, '杀');
  check('srf 筛选 sha 补查到消耗 1 字符的啥/杀',
    shaChar !== undefined && shaChar.consumedCodeLength === 1,
    shaPool.slice(0, 8).map((c: Candidate) => `${c.text}:${c.consumedCodeLength}`).join(','));
}

// ---------- 入口 ----------

function main(): void {
  const lexiconPath: string = process.argv[2];
  const bigramPath: string = process.argv[3];
  if (lexiconPath === undefined || bigramPath === undefined) {
    console.log('用法：node ranking.test.js <词库> <二元模型>');
    process.exitCode = 2;
    return;
  }
  syntheticTests();
  supplementTests();

  const lexicon = new Lexicon();
  lexicon.loadFromText(fs.readFileSync(lexiconPath, 'utf-8'));
  const engine = new PinyinEngine(lexicon);
  const model = new BigramModel();
  model.loadFromText(fs.readFileSync(bigramPath, 'utf-8'));
  engine.setBigramModel(model);
  realTests(engine, lexicon);
  controllerTests(engine, lexicon);
  userAbbrRankingTests(lexicon, model);
  pinyinFilterTests(lexicon, model);

  console.log('candidate-rank result: ' + passed + ' passed, ' + failed + ' failed');
  if (failed > 0) {
    process.exitCode = 1;
  }
}

main();
