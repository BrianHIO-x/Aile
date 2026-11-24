// 定向续接回归：两次相邻的明确确认 → 用户词库记下组合 → 候选栏补出外层候选 → 保存重载以后仍然可用。
// 全部走真实源码：真实词库、真实引擎、真实组词控制器、真实用户词库与真实 ContinuationTracker，
// 只把 ArkUI 的 CandidateView 与按键落点类型换成最小占位。运行：
//   powershell -ExecutionPolicy Bypass -File tools\continuation-regress\run.ps1
// 覆盖：continuableSegments 全有或全无、noteSelection 折叠选区边界、时间窗/会话/代次/序号/打断/失败、
//       shuru→输入 + fa→法 后补出输入法、已知组合一次、未知组合两次、仅整串逐字相等、分隔符、
//       固定/删除/撤销、保存重载（学习、删除、固定都随文件走）。
declare const require: (name: string) => any;
declare const process: { argv: string[]; exitCode: number };
declare const console: { log: (message: string) => void; error: (message: string) => void };
const fs = require('fs');

import { Candidate, CandidateOrigin, CandidateSource } from './engine/EngineTypes';
import { BigramModel } from './engine/BigramModel';
import { Lexicon } from './engine/Lexicon';
import { PinyinEngine } from './engine/PinyinEngine';
import { UNKNOWN_CONTINUATION_CONFIRMATIONS, UserLexicon } from './engine/UserLexicon';
import { CandidateView } from './ime/ImeState';
import { CommitResult, CommitSegment, CompositionController } from './ime/CompositionController';
import {
  continuableSegments,
  CONTINUATION_WINDOW_MS,
  ContinuationPair,
  ContinuationStart,
  ContinuationTracker
} from './ime/ContinuationTracker';

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

function section(title: string): void {
  console.log('');
  console.log('[' + title + ']');
}

// ---------- 片段与候选的小工具 ----------

function seg(text: string, code: string, syllables: string[], source: CandidateSource = CandidateSource.WORD,
  origin: CandidateOrigin = CandidateOrigin.LEXICON): CommitSegment {
  const value: CommitSegment = {
    text: text,
    code: code,
    syllables: syllables,
    source: source,
    alternatives: [],
    taps: []
  };
  if (origin !== CandidateOrigin.LEXICON) {
    value.origin = origin;
  }
  return value;
}

function segmentsText(list: CommitSegment[]): string[] {
  return list.map((item: CommitSegment) => item.text);
}

function findCandidate(pool: Candidate[], text: string, consumed: number = -1): Candidate | undefined {
  for (const candidate of pool) {
    if (candidate.text !== text) {
      continue;
    }
    if (consumed >= 0 && candidate.consumedCodeLength !== consumed) {
      continue;
    }
    return candidate;
  }
  return undefined;
}

function poolTexts(pool: Candidate[], limit: number = 8): string[] {
  const result: string[] = [];
  for (let i = 0; i < pool.length && i < limit; i++) {
    result.push(pool[i].text);
  }
  return result;
}

// ---------- 1. continuableSegments：全有或全无 ----------

function segmentTests(): void {
  section('continuableSegments：任何一段不合格，整次提交都不参与');
  const input = seg('输入', 'shuru', ['shu', 'ru']);
  const fa = seg('法', 'fa', ['fa']);
  sameList('全部合格时按顺序完整返回',
    segmentsText(continuableSegments([input, fa], false)), ['输入', '法']);

  // 旧实现会把不合格段过滤掉再取首尾，于是“输入”和“法”被当成紧挨着的一对；
  // 中间其实还隔着一段标点/原文。
  const rawMiddle = seg('，', ',', [], CandidateSource.RAW);
  sameList('中间夹一段原文时整次不参与（不再过滤后合并首尾）',
    segmentsText(continuableSegments([input, rawMiddle, fa], false)), []);

  const sentence = seg('输入法', 'shuru', ['shu', 'ru'], CandidateSource.SENTENCE);
  sameList('第一段是合成整句时整次不参与',
    segmentsText(continuableSegments([sentence, fa], false)), []);

  const continuation = seg('输入法', 'shuru', ['shu', 'ru', 'fa'], CandidateSource.WORD,
    CandidateOrigin.CONTINUATION);
  sameList('第一段是学到的组合续接时整次不参与',
    segmentsText(continuableSegments([continuation, fa], false)), []);

  const mismatched = seg('输入法', 'shuru', ['shu', 'ru']);
  sameList('音节数与字数对不上时整次不参与',
    segmentsText(continuableSegments([input, mismatched], false)), []);

  sameList('结果标记为原文时整次不参与', segmentsText(continuableSegments([input, fa], true)), []);
  sameList('没有片段时返回空表', segmentsText(continuableSegments([], false)), []);
}

// ---------- 2. ContinuationTracker：相邻判定与选区边界 ----------

function startOf(commitId: number, session: number, generation: number, actionTime: number,
  segments: CommitSegment[]): ContinuationStart {
  const value: ContinuationStart = {
    commitId: commitId,
    session: session,
    generation: generation,
    actionTime: actionTime,
    segments: segments
  };
  return value;
}

function pairText(pair: ContinuationPair | undefined): string {
  if (pair === undefined) {
    return 'none';
  }
  return pair.previous.text + '->' + pair.next.text;
}

function trackerTests(): void {
  section('ContinuationTracker：相邻、时间窗、会话、代次与序号');
  const input = seg('输入', 'shuru', ['shu', 'ru']);
  const fa = seg('法', 'fa', ['fa']);

  const first = new ContinuationTracker();
  first.start(startOf(1, 1, 0, 1000, [input]));
  check('第一次成功提交没有前一段', first.verified(1) === undefined);

  first.start(startOf(2, 1, 1, 1400, [fa]));
  const linked = first.verified(2);
  same('相邻的两次成功提交连成一对', pairText(linked), '输入->法');
  check('连过一次以后仍然记着新的尾段', first.hasPrevious());

  const boundary = new ContinuationTracker();
  boundary.start(startOf(1, 1, 0, 1000, [input]));
  boundary.verified(1);
  boundary.start(startOf(2, 1, 1, 1000 + CONTINUATION_WINDOW_MS, [fa]));
  same('正好 ' + CONTINUATION_WINDOW_MS + 'ms 仍然相连', pairText(boundary.verified(2)), '输入->法');

  const late = new ContinuationTracker();
  late.start(startOf(1, 1, 0, 1000, [input]));
  late.verified(1);
  late.start(startOf(2, 1, 1, 1000 + CONTINUATION_WINDOW_MS + 1, [fa]));
  same('超过时间窗不再相连', pairText(late.verified(2)), 'none');

  const otherSession = new ContinuationTracker();
  otherSession.start(startOf(1, 1, 0, 1000, [input]));
  otherSession.verified(1);
  otherSession.start(startOf(2, 2, 1, 1400, [fa]));
  same('换编辑框以后不再相连', pairText(otherSession.verified(2)), 'none');

  const jumped = new ContinuationTracker();
  jumped.start(startOf(1, 1, 0, 1000, [input]));
  jumped.verified(1);
  jumped.start(startOf(2, 1, 2, 1400, [fa]));
  same('中间上下文前进了两代时不再相连', pairText(jumped.verified(2)), 'none');

  const gap = new ContinuationTracker();
  gap.start(startOf(1, 1, 0, 1000, [input]));
  gap.verified(1);
  gap.start(startOf(3, 1, 1, 1400, [fa]));
  same('序号中间缺一次提交时不再相连', pairText(gap.verified(3)), 'none');

  const broken = new ContinuationTracker();
  broken.start(startOf(1, 1, 0, 1000, [input]));
  broken.verified(1);
  broken.break();
  check('break 以后不再留着上一段', !broken.hasPrevious());
  broken.start(startOf(2, 1, 1, 1400, [fa]));
  same('插入标点打断以后不再相连', pairText(broken.verified(2)), 'none');

  const failedCommit = new ContinuationTracker();
  failedCommit.start(startOf(1, 1, 0, 1000, [input]));
  failedCommit.verified(1);
  failedCommit.start(startOf(2, 1, 1, 1400, [fa]));
  failedCommit.failed(2);
  failedCommit.start(startOf(3, 1, 2, 1500, [fa]));
  same('失败的回执不能成为后一段的前一段', pairText(failedCommit.verified(3)), 'none');

  const fake = new ContinuationTracker();
  fake.start(startOf(1, 1, 0, 1000, [input]));
  fake.verified(1);
  fake.start(startOf(2, 1, 1, 1400, [fa]));
  // 超时按已送达，但没有真正回执：不调用 verified(2)
  fake.start(startOf(3, 1, 2, 1500, [input]));
  same('假成功（没有真实回执）挡住了后面的提交', pairText(fake.verified(3)), 'none');

  const reset = new ContinuationTracker();
  reset.start(startOf(1, 1, 0, 1000, [input]));
  reset.verified(1);
  reset.reset();
  check('reset 以后清空所有组合线索', !reset.hasPrevious());
}

function seededTracker(): ContinuationTracker {
  const tracker = new ContinuationTracker();
  tracker.start(startOf(1, 7, 3, 1000, [seg('输入', 'shuru', ['shu', 'ru'])]));
  tracker.verified(1);
  return tracker;
}

function selectionTests(): void {
  section('noteSelection：前后都必须是折叠的光标（已审查边界）');
  const still = seededTracker();
  still.noteOwnInsert(2);
  check('光标原地不动不算打断', still.noteSelection(5, 5, 5, 5) === false && still.hasPrevious());

  const appeared = seededTracker();
  appeared.noteOwnInsert(2);
  // 新选区覆盖 1 个字：旧实现在 ownCaret 足够时会把这种变化当成自己的插入
  check('新选区不是光标（begin<end）时打断', appeared.noteSelection(5, 5, 6, 7) === true);
  check('新选区不是光标时清掉上一段', !appeared.hasPrevious());

  const oldSelected = seededTracker();
  oldSelected.noteOwnInsert(2);
  check('原本就有选区时打断', oldSelected.noteSelection(5, 7, 7, 7) === true && !oldSelected.hasPrevious());

  const reversed = seededTracker();
  reversed.noteOwnInsert(2);
  check('新范围反过来（begin>end）时打断', reversed.noteSelection(5, 5, 7, 6) === true && !reversed.hasPrevious());

  const forward = seededTracker();
  forward.noteOwnInsert(2);
  check('自己的插入让光标往后走不算打断', forward.noteSelection(5, 5, 7, 7) === false && forward.hasPrevious());
  check('待核对字数已经被这次移动核销', forward.noteSelection(7, 7, 7, 7) === false);

  const tooFar = seededTracker();
  tooFar.noteOwnInsert(1);
  check('光标位移超过自己插入的字数时打断', tooFar.noteSelection(5, 5, 9, 9) === true && !tooFar.hasPrevious());

  const negative = seededTracker();
  check('负数下标按异常处理', negative.noteSelection(-1, -1, 0, 0) === true && !negative.hasPrevious());
}

function textLengthTests(): void {
  section('noteTextLength：只按长度核对自己有没有在别处被改动');
  const tracker = new ContinuationTracker();
  check('第一次推送只当基准', tracker.noteTextLength(10) === false);
  tracker.noteOwnInsert(2);
  check('自己插入后的长度对得上', tracker.noteTextLength(12) === false);
  check('多出来的长度说明别处改了文字', tracker.noteTextLength(13) === true);
}

// ---------- 3. 真实流程：组词控制器 + 用户词库 + 跟踪器 ----------

interface Pipeline {
  base: Lexicon;
  engine: PinyinEngine;
  user: UserLexicon;
  comp: CompositionController;
  tracker: ContinuationTracker;
  session: number;
  generation: number;
  commitId: number;
  hostLength: number;
  previousText: string;
  time: number;
}

interface CommitOptions {
  verified?: boolean;
  at?: number;
  explicit?: boolean;
  breakBefore?: boolean;
}

function pipelineFor(base: Lexicon, bigram: BigramModel | undefined, user: UserLexicon): Pipeline {
  const engine = new PinyinEngine(base);
  if (bigram !== undefined) {
    engine.setBigramModel(bigram);
  }
  engine.setUserModel(user);
  const comp = new CompositionController();
  comp.setProvider(engine);
  comp.setRules(user);
  const tracker = new ContinuationTracker();
  // 编辑框一开始就把全文长度推给输入法，之后的推送才能按长度核对
  tracker.noteTextLength(0);
  const pipeline: Pipeline = {
    base: base,
    engine: engine,
    user: user,
    comp: comp,
    tracker: tracker,
    session: 1,
    generation: 0,
    commitId: 0,
    hostLength: 0,
    previousText: '',
    time: 1000
  };
  return pipeline;
}

function newPipeline(base: Lexicon, bigram: BigramModel | undefined): Pipeline {
  const user = new UserLexicon(() => 100);
  user.attachBase(base);
  return pipelineFor(base, bigram, user);
}

function loadUser(base: Lexicon, text: string): UserLexicon {
  const user = new UserLexicon(() => 100);
  user.attachBase(base);
  user.deserialize(text);
  return user;
}

function typeCode(pipeline: Pipeline, code: string): void {
  for (let i = 0; i < code.length; i++) {
    const ch = code.charAt(i);
    if (ch === '\'') {
      pipeline.comp.appendSeparator();
    } else {
      pipeline.comp.appendCode(ch);
    }
  }
}

function retype(pipeline: Pipeline, code: string): void {
  pipeline.comp.reset();
  pipeline.comp.setPreviousText(pipeline.previousText);
  typeCode(pipeline, code);
}

function poolOf(pipeline: Pipeline): Candidate[] {
  return pipeline.comp.getCandidates();
}

// 按 ImeController.finishCommit 的顺序复刻一次确认：先发起，再按编辑框回执核对。
// explicit=false 对应自动提交（标点前确认首选），整次不参与学习。
function commitText(pipeline: Pipeline, text: string, options: CommitOptions = {}): CommitResult | undefined {
  const verified = options.verified !== false;
  const explicit = options.explicit !== false;
  if (options.breakBefore === true) {
    pipeline.tracker.break();
  }
  const raw = pipeline.comp.getRawCode();
  const pool = poolOf(pipeline);
  let index = -1;
  for (let i = 0; i < pool.length; i++) {
    if (pool[i].text === text && pool[i].consumedCodeLength === raw.length) {
      index = i;
      break;
    }
  }
  if (index < 0) {
    return undefined;
  }
  const target = pool[index];
  const view: CandidateView = {
    index: index,
    text: target.text,
    chars: target.text.length,
    id: target.id,
    consumedCodeLength: target.consumedCodeLength,
    revision: pipeline.comp.getRevision()
  };
  const selection = pipeline.comp.selectCandidate(view);
  if (!selection.accepted || selection.result === undefined) {
    return undefined;
  }
  const result = selection.result;
  const at = options.at !== undefined ? options.at : pipeline.time;
  pipeline.time = at;
  const commitId = ++pipeline.commitId;
  if (explicit) {
    pipeline.tracker.start(startOf(commitId, pipeline.session, pipeline.generation, at,
      continuableSegments(result.segments, result.raw)));
  } else {
    pipeline.tracker.break();
  }
  pipeline.tracker.noteOwnInsert(result.text.length);
  const inserted = pipeline.hostLength + result.text.length;
  if (verified) {
    pipeline.user.learn(result, pipeline.previousText);
    pipeline.tracker.noteTextLength(inserted);
    pipeline.tracker.noteSelection(pipeline.hostLength, pipeline.hostLength, inserted, inserted);
    const pair = pipeline.tracker.verified(commitId);
    if (pair !== undefined) {
      pipeline.user.learnContinuation(pair.previous, pair.next);
    }
  } else {
    // 超时按已送达：字频照学，但没有真正回执，组合线索不能往前走
    pipeline.user.learn(result, pipeline.previousText);
    pipeline.tracker.noteTextLength(inserted);
    pipeline.tracker.noteSelection(pipeline.hostLength, pipeline.hostLength, inserted, inserted);
  }
  pipeline.hostLength = inserted;
  pipeline.generation = pipeline.generation + 1;
  pipeline.previousText = result.text.length > 8 ? result.text.substring(result.text.length - 8) : result.text;
  pipeline.comp.setPreviousText(pipeline.previousText);
  return result;
}

function barIndexOf(pipeline: Pipeline, text: string): number {
  const pool = poolOf(pipeline);
  const order = pipeline.comp.getSnapshot().bar;
  for (let row = 0; row < order.length; row++) {
    const index = order[row];
    if (index >= 0 && index < pool.length && pool[index].text === text) {
      return row;
    }
  }
  return -1;
}

function wordRowOf(text: string, fileText: string, word: string): any {
  const file = JSON.parse(fileText);
  if (!Array.isArray(file.words)) {
    return undefined;
  }
  for (const row of file.words) {
    if (row.w === word) {
      return row;
    }
  }
  return undefined;
}

// ---------- 3.1 真实词库：shuru→输入 + fa→法 → 输入法 ----------

function knownCombinationTests(base: Lexicon, bigram: BigramModel | undefined): void {
  section('真实词库：shuru→输入 + fa→法 之后出现外层候选“输入法”');
  check('词库里本来就有“输入法”（所以确认一次就该提示）',
    base.find(['shu', 'ru', 'fa'], '输入法') !== undefined);

  const pipeline = newPipeline(base, bigram);
  typeCode(pipeline, 'shuru');
  const before = poolOf(pipeline);
  same('shuru 的首选是输入', before.length > 0 ? before[0].text : '', '输入');
  check('还没学的时候没有“输入法”', findCandidate(before, '输入法') === undefined);
  const first = commitText(pipeline, '输入');
  check('点按“输入”得到一次提交', first !== undefined && first.text === '输入');
  check('提交片段记录的是整串 shuru',
    first !== undefined && first.segments.length === 1 && first.segments[0].code === 'shuru');

  typeCode(pipeline, 'fa');
  const faPool = poolOf(pipeline);
  // 上一步已经把“输入”交给引擎当上文，二元模型会把“发”排在“法”前面；
  // 用户是明确点按“法”，这里只要求它确实在候选里并且消耗整串。
  check('fa 的候选里有“法”并消耗整串', findCandidate(faPool, '法', 2) !== undefined,
    'top=' + poolTexts(faPool, 4).join(','));
  const second = commitText(pipeline, '法');
  check('点按“法”得到第二次提交', second !== undefined && second.text === '法');

  retype(pipeline, 'shuru');
  const after = poolOf(pipeline);
  const outer = findCandidate(after, '输入法', 5);
  check('再次输入 shuru 时补出“输入法”外层候选', outer !== undefined);
  check('“输入法”消耗整串 shuru', outer !== undefined && outer.consumedCodeLength === 5);
  check('“输入法”来源标成组合续接',
    outer !== undefined && outer.meta !== undefined && outer.meta.origin === CandidateOrigin.CONTINUATION);
  check('“输入法”的读音是前词与后段拼接',
    outer !== undefined && outer.syllables.join(' ') === 'shu ru fa');
  same('默认首选仍然是输入', after.length > 0 ? after[0].text : '', '输入');
  const row = barIndexOf(pipeline, '输入法');
  check('“输入法”就在普通候选栏前几位（row<=3）', row >= 0 && row <= 3, 'row=' + row);

  section('真实词库：保存重载以后学习结果还在');
  const saved = pipeline.user.serialize();
  const rowOfInput = wordRowOf('输入', saved, '输入');
  check('保存文件按词写入续接字段 x', rowOfInput !== undefined && Array.isArray(rowOfInput.x) &&
    rowOfInput.x.length === 1);
  check('续接码是整串 shuru', rowOfInput !== undefined && rowOfInput.x[0].k === 'shuru');
  check('续接后段是法', rowOfInput !== undefined && rowOfInput.x[0].w === '法' && rowOfInput.x[0].s === 'fa');
  const reloaded = loadUser(base, saved);
  check('重载以后词数一致', reloaded.wordCount() === pipeline.user.wordCount(),
    reloaded.wordCount() + ' vs ' + pipeline.user.wordCount());
  check('重载以后二元关联数一致', reloaded.bigramCount() === pipeline.user.bigramCount(),
    reloaded.bigramCount() + ' vs ' + pipeline.user.bigramCount());
  const reloadedPipeline = pipelineFor(base, bigram, reloaded);
  typeCode(reloadedPipeline, 'shuru');
  const afterReload = poolOf(reloadedPipeline);
  check('重载以后“输入法”仍然补得出来（续接索引一并重建）',
    findCandidate(afterReload, '输入法', 5) !== undefined);
  same('重载以后默认首选仍然是输入', afterReload.length > 0 ? afterReload[0].text : '', '输入');
}

// ---------- 3.2 只有整串逐字相等才触发 ----------

function exactCodeTests(base: Lexicon, bigram: BigramModel | undefined): void {
  section('只按整串拼音逐字相等触发');
  const pipeline = newPipeline(base, bigram);
  typeCode(pipeline, 'shuru');
  commitText(pipeline, '输入');
  typeCode(pipeline, 'fa');
  commitText(pipeline, '法');

  retype(pipeline, 'shur');
  check('少一个字母的 shur 不提示', findCandidate(poolOf(pipeline), '输入法') === undefined);
  retype(pipeline, 'shurun');
  check('多一个字母的 shurun 不提示', findCandidate(poolOf(pipeline), '输入法') === undefined);
  retype(pipeline, 'shuru ');
  check('后面多一个空格的输入不提示', findCandidate(poolOf(pipeline), '输入法') === undefined);

  section('分隔符：记下的码带撇号时只认带撇号的整串');
  const separated = newPipeline(base, bigram);
  typeCode(separated, 'shu\'ru');
  const separatedPool = poolOf(separated);
  const separatedInput = findCandidate(separatedPool, '输入', 6);
  check('shu\'ru 读得出输入并消耗整串（含撇号）', separatedInput !== undefined);
  commitText(separated, '输入');
  typeCode(separated, 'fa');
  commitText(separated, '法');
  retype(separated, 'shu\'ru');
  check('带撇号的 shu\'ru 补出输入法', findCandidate(poolOf(separated), '输入法', 6) !== undefined);
  retype(separated, 'shuru');
  check('去掉撇号的 shuru 不补输入法', findCandidate(poolOf(separated), '输入法') === undefined);
}

// ---------- 3.3 未知组合：确认两次才提示 ----------

function unknownCombinationTests(base: Lexicon, bigram: BigramModel | undefined): void {
  section('未知组合（词库里没有）：第一次不提示，再确认一次才提示');
  check('词库里确实没有“法输入”这个组合', base.find(['fa', 'shu', 'ru'], '法输入') === undefined);
  check('未知组合的门槛大于一次确认', UNKNOWN_CONTINUATION_CONFIRMATIONS > 1);

  const pipeline = newPipeline(base, bigram);
  typeCode(pipeline, 'fa');
  commitText(pipeline, '法');
  typeCode(pipeline, 'shuru');
  commitText(pipeline, '输入');
  retype(pipeline, 'fa');
  check('第一次确认以后不提示“法输入”', findCandidate(poolOf(pipeline), '法输入') === undefined);

  retype(pipeline, 'fa');
  commitText(pipeline, '法');
  typeCode(pipeline, 'shuru');
  commitText(pipeline, '输入');
  retype(pipeline, 'fa');
  const unknown = findCandidate(poolOf(pipeline), '法输入', 2);
  check('再确认一次以后提示“法输入”', unknown !== undefined);
  check('“法输入”消耗整串 fa', unknown !== undefined && unknown.consumedCodeLength === 2);
  check('“法输入”的读音是拼接的三段',
    unknown !== undefined && unknown.syllables.join(' ') === 'fa shu ru');

  const saved = pipeline.user.serialize();
  const reloadedPipeline = pipelineFor(base, bigram, loadUser(base, saved));
  typeCode(reloadedPipeline, 'fa');
  check('重载以后未知组合的确认次数还在，仍然提示',
    findCandidate(poolOf(reloadedPipeline), '法输入', 2) !== undefined);
}

// ---------- 3.4 固定、删除与撤销 ----------

function pinAndRemoveTests(base: Lexicon, bigram: BigramModel | undefined): void {
  section('固定、删除与撤销仍然按原规则作用在组合候选上');
  const pipeline = newPipeline(base, bigram);
  typeCode(pipeline, 'shuru');
  commitText(pipeline, '输入');
  typeCode(pipeline, 'fa');
  commitText(pipeline, '法');

  pipeline.user.pin('shuru', ['shu', 'ru', 'fa'], '输入法');
  retype(pipeline, 'shuru');
  same('固定“输入法”以后排在首位', poolOf(pipeline)[0].text, '输入法');
  check('固定项消耗整串', poolOf(pipeline)[0].consumedCodeLength === 5);

  pipeline.user.unpin('shuru');
  retype(pipeline, 'shuru');
  same('取消固定以后默认首选回到输入', poolOf(pipeline)[0].text, '输入');

  pipeline.user.remove(['shu', 'ru', 'fa'], '输入法');
  retype(pipeline, 'shuru');
  check('删除组合候选以后不再提示', findCandidate(poolOf(pipeline), '输入法') === undefined);

  const removedPipeline = pipelineFor(base, bigram, loadUser(base, pipeline.user.serialize()));
  typeCode(removedPipeline, 'shuru');
  check('删除记录随文件保存，重载以后仍然不提示',
    findCandidate(poolOf(removedPipeline), '输入法') === undefined);

  check('删除可以撤销', pipeline.user.restoreRemoved());
  retype(pipeline, 'shuru');
  check('撤销以后“输入法”回到列表', findCandidate(poolOf(pipeline), '输入法', 5) !== undefined);

  pipeline.user.pin('shuru', ['shu', 'ru', 'fa'], '输入法');
  const pinnedPipeline = pipelineFor(base, bigram, loadUser(base, pipeline.user.serialize()));
  typeCode(pinnedPipeline, 'shuru');
  same('固定也随文件保存，重载以后仍在首位', poolOf(pinnedPipeline)[0].text, '输入法');
}

// ---------- 3.5 打断、超时与假成功 ----------

function interruptionTests(base: Lexicon, bigram: BigramModel | undefined): void {
  section('打断、超时与假成功都不该学出组合');
  const broken = newPipeline(base, bigram);
  typeCode(broken, 'shuru');
  commitText(broken, '输入');
  // 插入标点：ImeController.insert 先 break，再更新上下文
  broken.tracker.break();
  broken.generation = broken.generation + 1;
  typeCode(broken, 'fa');
  commitText(broken, '法');
  retype(broken, 'shuru');
  check('两次确认中间插入标点时不学组合', findCandidate(poolOf(broken), '输入法') === undefined);

  const late = newPipeline(base, bigram);
  typeCode(late, 'shuru');
  commitText(late, '输入');
  typeCode(late, 'fa');
  commitText(late, '法', { at: late.time + CONTINUATION_WINDOW_MS + 1 });
  retype(late, 'shuru');
  check('超过时间窗不学组合', findCandidate(poolOf(late), '输入法') === undefined);

  const boundary = newPipeline(base, bigram);
  typeCode(boundary, 'shuru');
  commitText(boundary, '输入');
  typeCode(boundary, 'fa');
  commitText(boundary, '法', { at: boundary.time + CONTINUATION_WINDOW_MS });
  retype(boundary, 'shuru');
  check('正好卡在时间窗上仍然学', findCandidate(poolOf(boundary), '输入法', 5) !== undefined);

  const fake = newPipeline(base, bigram);
  typeCode(fake, 'shuru');
  commitText(fake, '输入');
  typeCode(fake, 'fa');
  commitText(fake, '法', { verified: false });
  retype(fake, 'shuru');
  check('没有真实回执（超时假成功）不学组合', findCandidate(poolOf(fake), '输入法') === undefined);
  retype(fake, 'fa');
  commitText(fake, '法');
  retype(fake, 'shuru');
  check('假成功之后的成功提交不能越过它连到更早一次',
    findCandidate(poolOf(fake), '输入法') === undefined);
}

// ---------- 3.6 引擎层兜底 ----------

function engineGuardTests(base: Lexicon, bigram: BigramModel | undefined): void {
  section('引擎层兜底：不合格的片段直接不记');
  const pipeline = newPipeline(base, bigram);
  typeCode(pipeline, 'shuru');
  const result = commitText(pipeline, '输入');
  check('先建立“输入”的学习记录', result !== undefined);
  if (result !== undefined) {
    pipeline.user.learnContinuation(result.segments[0],
      seg('shuru', 'shuru', [], CandidateSource.RAW));
    retype(pipeline, 'shuru');
    check('后一段是原文时不记组合', findCandidate(poolOf(pipeline), '输入法') === undefined);

    pipeline.user.learnContinuation(result.segments[0],
      seg('法', 'fa', ['fa'], CandidateSource.SENTENCE));
    retype(pipeline, 'shuru');
    check('后一段是合成整句时不记组合', findCandidate(poolOf(pipeline), '输入法') === undefined);

    pipeline.user.learnContinuation(result.segments[0],
      seg('法', 'fa', ['fa'], CandidateSource.WORD, CandidateOrigin.CONTINUATION));
    retype(pipeline, 'shuru');
    check('后一段本身是学到的组合时不记组合', findCandidate(poolOf(pipeline), '输入法') === undefined);
  }
}

// ---------- 入口 ----------

function main(): void {
  const lexiconPath: string = process.argv[2];
  const bigramPath: string = process.argv[3];
  if (lexiconPath === undefined || bigramPath === undefined) {
    console.log('用法：node continuation.test.js <词库> <二元模型>');
    process.exitCode = 2;
    return;
  }
  const base = new Lexicon();
  const loaded = base.loadFromText(fs.readFileSync(lexiconPath, 'utf-8'));
  const bigram = new BigramModel();
  bigram.loadFromText(fs.readFileSync(bigramPath, 'utf-8'));
  console.log('词库 ' + loaded.entries + ' 条：' + lexiconPath);

  segmentTests();
  trackerTests();
  selectionTests();
  textLengthTests();
  knownCombinationTests(base, bigram);
  exactCodeTests(base, bigram);
  unknownCombinationTests(base, bigram);
  pinAndRemoveTests(base, bigram);
  interruptionTests(base, bigram);
  engineGuardTests(base, bigram);

  console.log('');
  console.log('共 ' + (passed + failed) + ' 项，通过 ' + passed + '，失败 ' + failed);
  if (failed > 0) {
    process.exitCode = 1;
  }
}

main();
