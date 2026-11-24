import { Candidate, CandidateMeta, CandidateOrigin, CandidateReading, CandidateSource } from '../engine/EngineTypes';

/**
 * 候选排序：引擎给出候选池以后，这里按界面用途产出两份以上互相独立的显示顺序。
 *
 * 普通候选栏是快选：固定首位或引擎首选留在第一个，紧接几个代表项——覆盖整串的真实词、可靠的分段改选、
 * 紧贴起始音节的常用词与一个可靠首字；其余候选保持引擎原顺序，只把相近的整句、低覆盖纠错、没有在下标
 * 断开的切分与简拼补全挪到后面，原文始终在最后。
 * 展开的“全部”按找词、改字的意图重新分档：真实词与安全分段在前，当前首音节的常用字随后，弱补全与
 * 非首选整句靠后。
 * 两个视图都返回候选在引擎池里的序号，原候选的 id、消耗长度与索引不变，显示位置由返回值给出。
 * 规则只读候选自带的读音元数据（CandidateMeta），不靠文字长度猜音节切分，也不改分数。
 */
export enum CandidateLane {
  BAR = 'bar',
  ALL = 'all',
  WORDS = 'words',
  CHARS = 'chars'
}

// 一份候选池对应的四种显示顺序。数字是候选在池里的原始序号，原候选对象不变。
export interface CandidateSnapshot {
  code: string;
  // 普通候选栏的快选顺序
  bar: number[];
  // 展开以后“全部”的顺序
  all: number[];
  // 展开以后“词语”的顺序，只含真正的词，不含合成的整句
  words: number[];
  // 展开以后“单字”的顺序
  chars: number[];
}

interface RankFeature {
  candidate: Candidate;
  index: number;
  chars: number;
  isRaw: boolean;
  isSentence: boolean;
  isWord: boolean;
  isChar: boolean;
  complete: boolean;
  // 消耗停在原文可以安全断开的音节边界
  safe: boolean;
  // 消耗正好停在首选路径第一个自然音节的末尾
  atPreferredBoundary: boolean;
  // 消耗停在首选路径任意一个完整音节的末尾，简拼输入下没有这种位置
  atPreferredStop: boolean;
  // 候选读音的音节序列是首选读音的前缀，tian 与 ti-an 这种同末点不同切分要分开
  syllablePrefix: boolean;
  // 学到的组合续接，见 UserLexicon.suggestContinuations：补在首位之后的前几位，不进后段
  isContinuation: boolean;
  // 用户之前打过的词按首字母自动召回，输入串本身像全拼时补在首位之后，不抢全拼单字第一位
  isUserAbbr: boolean;
  reading: CandidateReading;
  syllables: number;
}

// 长输入才做代表项晋升：短全拼的同音字、同音词保持引擎给出的上下文顺序
const LONG_CODE_LENGTH: number = 10;
// 普通栏最多把几个代表项提到前列：分段、短前缀词、长前缀词与一个首字
const BAR_PROMOTION_CAP: number = 4;
// 普通栏最多保留几条纠错候选，其余留到后段
const BAR_CORRECTED_KEEP: number = 2;
// 普通栏只留一条完整的合成整句，相近的其余整句靠后
const BAR_WHOLE_SENTENCE_KEEP: number = 1;
// 普通栏最多把几条学到的组合续接紧跟在首位之后：组合候选要好点，但首位保持原来的默认首选
const BAR_CONTINUATION_KEEP: number = 2;
// 输入本身也是全拼音节时（如 wan、fa、de），普通栏紧随首位与续接之后展示的已学简拼词条数
const BAR_USER_ABBR_KEEP: number = 2;
// 截断成 150 条以后一个单字都没有时，按首音节补一页候选
const CHARS_SUPPLEMENT_LIMIT: number = 16;

function characterCount(text: string): number {
  let count = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    // 高位代理与后续低位代理计为一个字符
    if (code < 0xDC00 || code > 0xDFFF) {
      count++;
    }
  }
  return count;
}

export function isSingleCharacter(text: string): boolean {
  return characterCount(text) === 1;
}

function readingOf(candidate: Candidate): CandidateReading {
  const meta = candidate.meta;
  return meta !== undefined ? meta.reading : CandidateReading.FULL;
}

// 消耗位置去掉末尾的显式音节分隔符，'xi\'an' 里读完 xi 的位置因此和 xi 之后的撇号算同一个边界
function boundaryPosition(code: string, consumed: number): number {
  let end = consumed;
  while (end > 0 && code.charAt(end - 1) === '\'') {
    end--;
  }
  return end;
}

// 首选路径每个完整音节在键入串里的结束位置：逐个确认键入串与首选读音的音节对得上，
// 记下不带撇号的字母末尾，再跳过音节之间的撇号继续。tian'anmen 的停止点是 4 与 7，不是 4 与 5。
function preferredStops(code: string, first: Candidate | undefined): number[] {
  const stops: number[] = [];
  if (first === undefined) {
    return stops;
  }
  let cursor = 0;
  for (const syllable of first.syllables) {
    if (cursor + syllable.length > code.length ||
      code.substring(cursor, cursor + syllable.length) !== syllable) {
      // 简拼或模糊音键入的字母与首选读音不再逐字对应，后面的位置不能拿来比较
      break;
    }
    cursor += syllable.length;
    if (cursor < code.length) {
      stops.push(cursor);
    }
    while (cursor < code.length && code.charAt(cursor) === '\'') {
      cursor++;
    }
  }
  return stops;
}

// 首选路径第一个自然音节的结束位置：首选候选读音的第一个音节原样出现在输入开头时才有值
function preferredFirstEnd(code: string, candidates: Candidate[]): number {
  if (candidates.length === 0) {
    return 0;
  }
  const syllables = candidates[0].syllables;
  if (syllables.length === 0) {
    return 0;
  }
  const syllable = syllables[0];
  if (syllable.length > 0 && code.substring(0, syllable.length) === syllable) {
    return syllable.length;
  }
  return 0;
}

function syllablePrefixOf(candidate: Candidate, first: Candidate | undefined): boolean {
  if (first === undefined || first.syllables.length === 0 || candidate.syllables.length === 0) {
    return false;
  }
  if (candidate.syllables.length > first.syllables.length) {
    return false;
  }
  for (let i = 0; i < candidate.syllables.length; i++) {
    if (candidate.syllables[i] !== first.syllables[i]) {
      return false;
    }
  }
  return true;
}

function featureOf(index: number, candidate: Candidate, code: string, firstEnd: number,
  stops: number[], first: Candidate | undefined): RankFeature {
  const isRaw = candidate.source === CandidateSource.RAW;
  const chars = characterCount(candidate.text);
  const isSentence = !isRaw && candidate.source === CandidateSource.SENTENCE;
  const complete = !isRaw && candidate.consumedCodeLength === code.length;
  const meta: CandidateMeta | undefined = candidate.meta;
  const safe = isRaw ? false : (meta !== undefined ? meta.safeEnd : true);
  const feature: RankFeature = {
    candidate: candidate,
    index: index,
    chars: chars,
    isRaw: isRaw,
    isSentence: isSentence,
    isWord: !isRaw && !isSentence && chars >= 2,
    isChar: !isRaw && chars === 1,
    complete: complete,
    safe: safe,
    atPreferredBoundary: !isRaw && safe && firstEnd > 0 &&
      boundaryPosition(code, candidate.consumedCodeLength) === firstEnd,
    atPreferredStop: !isRaw && safe && stops.indexOf(boundaryPosition(code, candidate.consumedCodeLength)) >= 0,
    syllablePrefix: !isRaw && syllablePrefixOf(candidate, first),
    isContinuation: !isRaw && meta !== undefined && meta.origin === CandidateOrigin.CONTINUATION,
    isUserAbbr: !isRaw && meta !== undefined && meta.origin === CandidateOrigin.USER_ABBR,
    reading: isRaw ? CandidateReading.FULL : readingOf(candidate),
    syllables: candidate.syllables.length
  };
  return feature;
}

function codeHasVowel(code: string): boolean {
  for (let i = 0; i < code.length; i++) {
    const c = code.charAt(i);
    if (c === 'a' || c === 'e' || c === 'i' || c === 'o' || c === 'u' || c === 'v') {
      return true;
    }
  }
  return false;
}

// 整串本来就是简拼：一个元音都没有，或者没有完整读音的整串候选、却有简拼读完整串的候选
function looksAbbreviated(code: string, features: RankFeature[]): boolean {
  if (!codeHasVowel(code)) {
    return true;
  }
  let fullComplete = false;
  let abbreviationComplete = false;
  for (const feature of features) {
    if (feature.isRaw || !feature.complete) {
      continue;
    }
    if (feature.reading === CandidateReading.FULL) {
      fullComplete = true;
    } else if (feature.reading === CandidateReading.ABBREVIATION) {
      abbreviationComplete = true;
    }
  }
  return !fullComplete && abbreviationComplete;
}

function isFullReading(feature: RankFeature): boolean {
  return feature.reading === CandidateReading.FULL || feature.reading === CandidateReading.FUZZY;
}

// ---------- 代表项：普通栏只把这几类各提一个 ----------

function isFullCompleteWord(feature: RankFeature): boolean {
  return feature.isWord && feature.reading === CandidateReading.FULL && feature.complete;
}

function isSafeSegmentPrefix(feature: RankFeature): boolean {
  return feature.isSentence && isFullReading(feature) && !feature.complete && feature.safe;
}

// 前缀词要停在首选路径的完整音节末尾，而且读音就是首选读音的前缀；
// 简拼、模糊拼法或 ti-an 与 tian 这种同末点不同切分都算不可靠前缀
function isFullPrefixWord(feature: RankFeature): boolean {
  return feature.isWord && feature.reading === CandidateReading.FULL && !feature.complete &&
    feature.atPreferredStop && feature.syllablePrefix;
}

function isPreferredChar(feature: RankFeature): boolean {
  return feature.isChar && isFullReading(feature) && feature.atPreferredBoundary;
}

function isReliableChar(feature: RankFeature): boolean {
  return feature.isChar && isFullReading(feature) && feature.safe;
}

function isAbbreviationCompleteWord(feature: RankFeature): boolean {
  return feature.isWord && feature.reading === CandidateReading.ABBREVIATION && feature.complete;
}

// 输入正好一个完整音节、首选却是扩写到别的读音的补全（例如 ji 的首选“就”读 jiu），
// 而候选里有同读音的完整单字：把排在最前的那个完整读音单字提到首位。
// 用户显式固定的首位不动。返回该单字在候选池里的序号，没有这种情况时返回 -1。
function completionGuard(features: RankFeature[], code: string, pinnedFirst: boolean): number {
  if (pinnedFirst || features.length === 0 || code.length === 0 || !codeHasVowel(code)) {
    return -1;
  }
  const first = features[0];
  if (first.isRaw || first.reading !== CandidateReading.ABBREVIATION || !first.complete ||
    first.candidate.syllables.length !== 1) {
    return -1;
  }
  const syllable = first.candidate.syllables[0];
  // 首选读音必须是把输入扩写成的另一个音节，ji → jiu；读音本身就是输入时不属于这一类
  if (syllable.length <= code.length || syllable.substring(0, code.length) !== code) {
    return -1;
  }
  for (let i = 1; i < features.length; i++) {
    const feature = features[i];
    if (feature.isChar && feature.complete && feature.reading === CandidateReading.FULL &&
      feature.candidate.syllables.length === 1 && feature.candidate.syllables[0] === code) {
      return i;
    }
  }
  return -1;
}

// 把某一类里排在最前、还没有被占用的候选提到普通栏前列；一类只提一个
function firstPromotion(features: RankFeature[], taken: boolean[],
  accept: (feature: RankFeature) => boolean): number {
  for (let i = 1; i < features.length; i++) {
    if (!taken[i] && accept(features[i])) {
      return i;
    }
  }
  return -1;
}

// 可靠前缀词按覆盖挑一个：短的贴近起始音节，长的覆盖更多输入。只认停在首选路径完整音节末尾的词
function prefixWordPromotion(features: RankFeature[], taken: boolean[], longest: boolean,
  minConsumed: number): number {
  let best = -1;
  let bestConsumed = -1;
  for (let i = 1; i < features.length; i++) {
    if (taken[i] || !isFullPrefixWord(features[i])) {
      continue;
    }
    const consumed = features[i].candidate.consumedCodeLength;
    if (consumed <= minConsumed) {
      continue;
    }
    if (best < 0 || (longest ? consumed > bestConsumed : consumed < bestConsumed) ||
      (consumed === bestConsumed && i < best)) {
      best = i;
      bestConsumed = consumed;
    }
  }
  return best;
}

/**
 * 普通栏：第一个是固定首位或引擎首选，随后最多四个代表项，其余保持引擎顺序。
 * 相近的合成整句、没有落在音节边界的切分、简拼补全与低覆盖纠错挪到后段，原文最后。
 */
function buildBar(code: string, features: RankFeature[], guard: number): number[] {
  const order: number[] = [];
  const taken: boolean[] = new Array<boolean>(features.length).fill(false);
  if (features.length === 0) {
    return order;
  }
  if (guard >= 0) {
    // 完整读音的单字先上，空格跟着这份顺序走；旧补全项按简拼档照常排到后面
    order.push(guard);
    taken[guard] = true;
  } else {
    order.push(0);
    taken[0] = true;
  }
  // 学到的组合续接紧跟首位：它们是用户自己刚确认过的搭配，比其它代表项更该好点。
  // 首位仍然是固定项或引擎首选，续接不抢首位
  const continuations: number[] = [];
  for (let i = 0; i < features.length; i++) {
    if (!taken[i] && features[i].isContinuation && continuations.length < BAR_CONTINUATION_KEEP) {
      taken[i] = true;
      continuations.push(i);
    }
  }
  for (const index of continuations) {
    order.push(index);
  }
  const abbreviationInput = looksAbbreviated(code, features);
  // 输入本身也是全拼音节时，用户之前用全拼打过的同首字母词紧随首位展示（不抢全拼单字首位）
  if (!abbreviationInput) {
    const userAbbrs: number[] = [];
    for (let i = 0; i < features.length; i++) {
      if (!taken[i] && features[i].isUserAbbr && features[i].complete &&
        userAbbrs.length < BAR_USER_ABBR_KEEP) {
        taken[i] = true;
        userAbbrs.push(i);
      }
    }
    for (const index of userAbbrs) {
      order.push(index);
    }
  }
  const longInput = code.length >= LONG_CODE_LENGTH || features[0].syllables >= 4;
  if (longInput || abbreviationInput) {
    const reps: number[] = [];
    const take = (index: number): void => {
      if (index >= 0 && !taken[index] && reps.length < BAR_PROMOTION_CAP) {
        taken[index] = true;
        reps.push(index);
      }
    };
    take(firstPromotion(features, taken, isFullCompleteWord));
    // 纯声母简拼只把完整的简拼词提到前列；整句、前缀与单字都可能只是声母拼出来的近似结果
    if (!abbreviationInput) {
      take(firstPromotion(features, taken, isSafeSegmentPrefix));
      const earliest = prefixWordPromotion(features, taken, false, -1);
      take(earliest);
      if (earliest >= 0) {
        take(prefixWordPromotion(features, taken, true,
          features[earliest].candidate.consumedCodeLength));
      }
      let charIndex = firstPromotion(features, taken, isPreferredChar);
      if (charIndex < 0) {
        charIndex = firstPromotion(features, taken, isReliableChar);
      }
      take(charIndex);
    } else {
      take(firstPromotion(features, taken, isAbbreviationCompleteWord));
    }
    // 代表项之间仍按引擎顺序排列，避免把更长的前缀词排到短词后面
    reps.sort((a: number, b: number) => a - b);
    for (const index of reps) {
      order.push(index);
    }
  }
  const deferred: number[] = [];
  const raw: number[] = [];
  let correctedSeen = !features[0].isRaw && features[0].reading === CandidateReading.CORRECTED ? 1 : 0;
  let wholeKept = features[0].isSentence && features[0].complete && isFullReading(features[0]) ? 1 : 0;
  for (let i = guard >= 0 ? 0 : 1; i < features.length; i++) {
    if (taken[i]) {
      continue;
    }
    const feature = features[i];
    if (feature.isRaw) {
      raw.push(i);
      continue;
    }
    // 相近的合成整句：只留第一条可靠读法的整句，其余靠后；纠错与简拼整句一律靠后
    if (feature.isSentence && feature.complete) {
      if (!isFullReading(feature) || wholeKept >= BAR_WHOLE_SENTENCE_KEEP) {
        deferred.push(i);
        continue;
      }
      wholeKept++;
      order.push(i);
      continue;
    }
    // 切进音节内部的替代切分靠后
    if (!feature.safe) {
      deferred.push(i);
      continue;
    }
    // 不是简拼输入时，简拼补全留到可靠候选之后
    if (feature.reading === CandidateReading.ABBREVIATION && !abbreviationInput) {
      deferred.push(i);
      continue;
    }
    // 纠错只保留前两条有足够覆盖的，其余靠后
    if (feature.reading === CandidateReading.CORRECTED) {
      if (correctedSeen >= BAR_CORRECTED_KEEP || feature.candidate.consumedCodeLength * 2 < code.length) {
        deferred.push(i);
        continue;
      }
      correctedSeen++;
    }
    order.push(i);
  }
  for (const index of deferred) {
    order.push(index);
  }
  for (const index of raw) {
    order.push(index);
  }
  return order;
}

// ---------- 展开的“全部”与两个筛选 ----------

// 单字组内的边界档：第 0 档停在首选第一音节末尾，第 1 档停在其他安全音节边界，第 2 档切进音节内部。
// 同一读音的字先看这个，再看引擎顺序，替代切分才不会混进首排
function boundaryRank(feature: RankFeature): number {
  if (feature.atPreferredBoundary) {
    return 0;
  }
  if (feature.safe) {
    return 1;
  }
  return 2;
}

function readingRank(feature: RankFeature): number {
  if (feature.reading === CandidateReading.FULL) {
    return 0;
  }
  if (feature.reading === CandidateReading.FUZZY) {
    return 1;
  }
  if (feature.reading === CandidateReading.ABBREVIATION) {
    return 2;
  }
  return 3;
}

// 全部：真实词（同一读音内保持引擎顺序）→ 安全分段 → 当前首音节的常用字 → 简拼词 → 纠错与替代切分
function allTier(feature: RankFeature): number {
  if (feature.isRaw) {
    return 30;
  }
  // 学到的组合续接紧跟首位，展开“全部”时也在最前几条
  if (feature.isContinuation) {
    return 0;
  }
  if (feature.isUserAbbr && feature.complete) {
    return 1;
  }
  if (feature.isWord) {
    if (feature.reading === CandidateReading.FULL) {
      return feature.safe ? 1 : 15;
    }
    if (feature.reading === CandidateReading.FUZZY) {
      return feature.safe ? 2 : 15;
    }
    if (feature.reading === CandidateReading.ABBREVIATION) {
      return feature.safe ? 4 : 16;
    }
    return feature.safe ? 13 : 17;
  }
  if (isSafeSegmentPrefix(feature)) {
    return 3;
  }
  if (feature.isSentence) {
    if (feature.reading === CandidateReading.CORRECTED) {
      return 19;
    }
    return feature.complete ? 17 : 18;
  }
  if (feature.isChar) {
    if (feature.reading === CandidateReading.FULL) {
      return feature.atPreferredBoundary ? 5 : (feature.safe ? 6 : 15);
    }
    if (feature.reading === CandidateReading.FUZZY) {
      return feature.atPreferredBoundary || feature.safe ? 7 : 15;
    }
    if (feature.reading === CandidateReading.ABBREVIATION) {
      return feature.atPreferredBoundary || feature.safe ? 8 : 16;
    }
    return feature.safe ? 14 : 17;
  }
  return 20;
}

// 词语：完整读音、模糊音、简拼、纠错依次往后；同一读音内保持引擎顺序。
// 安全边界同档时先列读音就是首选音节序列的词，替代切分（如 ti-an 对 tian）排在后面，但都保留
function wordsTier(feature: RankFeature): number {
  // 组合续接与首选读音的前缀词同档，靠候选池里的先后排在词表最前几条
  if (feature.isContinuation) {
    return 0;
  }
  if (feature.isUserAbbr && feature.complete) {
    return 1;
  }
  const base = readingRank(feature) * 4;
  if (!feature.safe) {
    return base + 3;
  }
  return base + (feature.syllablePrefix ? 0 : 1);
}

function charsTier(feature: RankFeature): number {
  return readingRank(feature) * 3 + boundaryRank(feature);
}

// 稳定分档：先按档，再按引擎池里的原顺序；同一档内保留词频与上下文顺序。
// 候选池的第一个是固定首位或引擎首选，分档前先摘出来，其余候选按档排。
function sortByTier(order: number[], features: RankFeature[], tierOf: (feature: RankFeature) => number,
  forceFirst: number = 0): number[] {
  const first: number[] = [];
  const rest: number[] = [];
  for (const index of order) {
    if (index === forceFirst) {
      first.push(index);
    } else {
      rest.push(index);
    }
  }
  const tiers: number[] = new Array<number>(rest.length).fill(0);
  for (let i = 0; i < rest.length; i++) {
    tiers[i] = tierOf(features[rest[i]]);
  }
  const indexed: number[] = [];
  for (let i = 0; i < rest.length; i++) {
    indexed.push(i);
  }
  indexed.sort((a: number, b: number) => {
    if (tiers[a] !== tiers[b]) {
      return tiers[a] - tiers[b];
    }
    return rest[a] - rest[b];
  });
  const result: number[] = [];
  for (const index of first) {
    result.push(index);
  }
  for (const position of indexed) {
    result.push(rest[position]);
  }
  return result;
}

function buildAll(features: RankFeature[], guard: number): number[] {
  const order: number[] = [];
  for (let i = 0; i < features.length; i++) {
    if (i !== guard) {
      order.push(i);
    }
  }
  // 补全守卫生效时不再强行把候选池第一个排在第二，旧补全项按自己的简拼档排
  const sorted = sortByTier(order, features, allTier, guard >= 0 ? -1 : 0);
  if (guard < 0) {
    return sorted;
  }
  // 完整读音单字提到第一，其余仍按分档排
  const result: number[] = [guard];
  for (const index of sorted) {
    result.push(index);
  }
  return result;
}

function buildWords(features: RankFeature[]): number[] {
  const order: number[] = [];
  for (let i = 0; i < features.length; i++) {
    if (features[i].isWord) {
      order.push(i);
    }
  }
  return sortByTier(order, features, wordsTier);
}

function buildChars(features: RankFeature[], guard: number): number[] {
  const order: number[] = [];
  for (let i = 0; i < features.length; i++) {
    if (features[i].isChar && i !== guard) {
      order.push(i);
    }
  }
  // 补全守卫生效时，完整读音的单字先列，切分补全项按自己的读音档排
  const sorted = sortByTier(order, features, charsTier, guard >= 0 ? -1 : 0);
  if (guard < 0) {
    return sorted;
  }
  const result: number[] = [guard];
  for (const index of sorted) {
    result.push(index);
  }
  return result;
}

export function emptyCandidateSnapshot(): CandidateSnapshot {
  const snapshot: CandidateSnapshot = { code: '', bar: [], all: [], words: [], chars: [] };
  return snapshot;
}

export function rankCandidates(code: string, candidates: Candidate[],
  pinnedFirst: boolean = false): CandidateSnapshot {
  const features: RankFeature[] = [];
  const firstEnd = preferredFirstEnd(code, candidates);
  const first = candidates.length > 0 ? candidates[0] : undefined;
  const stops = preferredStops(code, first);
  for (let i = 0; i < candidates.length; i++) {
    features.push(featureOf(i, candidates[i], code, firstEnd, stops, first));
  }
  const guard = completionGuard(features, code, pinnedFirst);
  const snapshot: CandidateSnapshot = {
    code: code,
    bar: buildBar(code, features, guard),
    all: buildAll(features, guard),
    words: buildWords(features),
    chars: buildChars(features, guard)
  };
  return snapshot;
}

// 单字筛选为空时补一页候选的条数上限，组词控制器只在截断后一个单字都没有时用它
export function charsSupplementLimit(): number {
  return CHARS_SUPPLEMENT_LIMIT;
}
