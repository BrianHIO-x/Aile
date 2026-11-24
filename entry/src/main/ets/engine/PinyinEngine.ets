import {
  Candidate,
  CandidateMeta,
  CandidateOrigin,
  CandidateProvider,
  CandidateReading,
  CandidateSource,
  CommitProposal,
  DEFAULT_QUERY_OPTIONS,
  EngineAdapter,
  EngineSnapshot,
  QueryOptions,
  rawCandidate
} from './EngineTypes';
import { keyLetter, Lexicon, LexiconEntry, SyllableGroup } from './Lexicon';
import {
  buildLattice,
  EdgeKind,
  PENALTY_ABBREVIATION,
  SegmentLattice,
  SEPARATOR,
  SyllableEdge,
  syllableCost
} from './PinyinSegmenter';

// 每条词边的查询上限，桶内已按概率排序
const MATCHES_PER_PATH: number = 150;
const MAX_PATHS_PER_START: number = 400;
// 一条音节组合累计的切分与纠错扣分超过这个值时不再展开。新词库的首字母前缀很密，
// 带着两三条高扣分简拼边的组合数量很多，几乎都排不到前面。engine-bench 上取 10 时展开的组合减少六成，
// 各项准确率不变；取 7.5 时，当时还在使用的漏打纠正前三比例会掉十几个百分点
const MAX_PATH_PENALTY: number = 10;
// 多音节词相对单字的加分，让“西安”这类完整词排在低频单字之前
export const WORD_BONUS_PER_SYLLABLE: number = 1.0;
// 整句之外，候选列表最多补充几个纠错得到的词
const MAX_CORRECTED_WORDS: number = 3;
// 纠错词不必压过同样长度的原文最佳词，只要落后不超过这个分数，也作为候选列出。
// yife 的首选仍是一份，但一个会紧随其后，而不是从候选里消失
const CORRECTED_LIST_MARGIN: number = 3.0;
// 整句搜索时，每段拼音按 unigram 保留几个最可能的词。
// 二元模型在同音词之间挑选时，只按 unigram 截断会让后面的词永远补不回来，见 HOMOPHONE_EXTRA
const WORDS_PER_SPAN: number = 3;
// 有二元模型时，同读音、都未经纠错的词弧在截断之前额外保留几条，交给上下文重排。
// 例如 shi 的一组同音词，“事、是、时”按 unigram 只留三条时，适合当前上文的那个可能已经被丢掉
const HOMOPHONE_EXTRA: number = 2;
// 每个位置最多保留几条历史继续往后搜索
const BEAM_WIDTH: number = 8;
// 其中最多几种“上一个词”：先按组各给一条主路径，剩下的名额留给近分的副路径。
// 候选密集的位置因此既有足够的末词，也不会把整个 beam 交给同末词的几种写法
const BEAM_GROUPS: number = 6;
// 同一个“上一个词”（连同跨音节打反挂起状态）最多保留几条不同文本的历史。
// 两组同音异议因此都能走到串尾，例如在说与再说，而不是只留下得分最高的那一条
const GROUP_KEEP: number = 2;
// 整句方案最多列几条近分的（含最好的一条），按文本去重
const SENTENCE_LIMIT: number = 3;
const EMPTY_ENTRIES: LexiconEntry[] = [];
const EMPTY_GROUPS: SyllableGroup[] = [];
// 次好整句与最好整句的得分差在这个范围之内时，作为第二个整句候选列出
const SECOND_SENTENCE_MARGIN: number = 2.5;
// 同一个字母连按这么多次时，多半是想打叠字，例如 hhhh 的哈哈哈哈，叠字候选排在整句之前
const REPEAT_MIN_LETTERS: number = 3;
// 各个字的叠字按连按三到六个字母时的得分之和排序，与实际按了几个字母无关，
// 多按或少按一个字母时，首选不会在宝宝宝宝与抱抱抱抱之间来回换。只看某一个长度时，
// 恰好有这个长度叠词的字占便宜，例如只看六个字母时，别别别能拼成两段，别别别别别别会排到宝宝宝宝宝宝前面
const REPEAT_REFERENCE_MIN: number = 3;
const REPEAT_REFERENCE_MAX: number = 6;
// 整句搜索把一串叠字当作一个词，并加上这么多分：连按同一个声母多半是想打叠字。
// 不加时，“别别别宝宝委屈了”这种半路换字的拆法总比“别别别别别委屈了”划算
const REPEAT_RUN_BONUS: number = 8.0;
const REPEAT_CANDIDATES: number = 3;
// 把拼音整串读完的词语排在其他词前面，前提是得分不比读完整串的最好词低这么多。
// 例如 zhongguo 的“种果”比“中国”低十分，就和其他词一起按下面的规则排
const WHOLE_MARGIN: number = 8.0;
// 其余词语与单字按得分加上每个音节的这么多分排序，常用的短词可以排到生僻的长词前面。
// 例如 gggggg 的“哥哥”比“桂公公”高七分半，多一个音节只补回这么多分。
// 加分要有上限：音节数再多也只补 MAX_LIST_BONUS，长词不会只靠长度一直往前提
const LIST_BONUS_PER_SYLLABLE: number = 5.0;
const MAX_LIST_BONUS: number = 20.0;
// 最好整句至少有三个词时，再列出它去掉末尾一两个词的前半段，例如“我们明天见”之后列出“我们明天”
const MAX_SENTENCE_PREFIXES: number = 2;

/**
 * 词间搭配：前一个词后面接这个词时，在后词自身概率之外的修正量，前词没有记录时为 0。
 */
export interface TransitionModel {
  bonus(previous: string, next: string): number;
  // 把已经上屏的上文换成第一个词的前词，上文为空时为一段话的开头，找不到时为空串
  contextOf(previousText: string): string;
}

/**
 * 用户模型：提供学习得到的词条，并为词条计算个性化加分。
 */
export interface UserModel {
  lookup(initialsKey: string): LexiconEntry[];
  hasKeyPrefix(prefix: string): boolean;
  boost(entry: LexiconEntry, previousText: string, abbreviated?: boolean): number;
  hasRecord(entry: LexiconEntry): boolean;
  isUserEntry(entry: LexiconEntry): boolean;
  maxSyllables(): number;
  // 用户打出某个词时实际按过的一串字母（不含分隔符）对应的词条，见 UserLexicon.touchTyped
  typedLookup(letters: string): LexiconEntry[];
  maxTypedLetters(): number;
  // 用户确认过的多音节词按音节真实首字母建的索引，见 UserLexicon.initialsLookup
  initialsLookup(letters: string): LexiconEntry[];
  maxInitialsLetters(): number;
  // 学习记录每变化一次加一，引擎据此判断缓存的词弧是否还能用
  revision(): number;
}

// 上一次查询在某个起点算出的词弧，以及当时读到的最远位置
interface ArcCacheEntry {
  arcs: StartArcs;
  readUpTo: number;
}

/**
 * 词格每个位置上全部边的特征串。两次查询在同一位置的特征串相同，说明从这里出发能走的音节边完全一样。
 */
function edgeSignatures(lattice: SegmentLattice): string[] {
  const signatures: string[] = [];
  for (const edges of lattice.edges) {
    let signature = '';
    for (const edge of edges) {
      const pair = edge.swapNext !== undefined ? `${edge.swapNext.end}:${edge.swapNext.text}` :
        (edge.swapTail === true ? 'tail' : '') + (edge.tapOnly === true ? 'tap' : '');
      signature += `${edge.end},${edge.kind},${edge.text},${edge.typed},${edge.penalty},${edge.corrected ? 1 : 0},` +
        `${edge.variants.length},${pair};`;
    }
    signatures.push(signature);
  }
  return signatures;
}

export interface WordArc {
  start: number;
  end: number;
  entry: LexiconEntry;
  score: number;
  typed: string[];
  exact: boolean;
  // 音节匹配时的模糊音代价，0 表示读音与键入完全一致。exact 只表示音节类型都是完整音节，
  // 开启模糊音时完整音节也可能由等价读音匹配，排序要另行区分的正是这一档
  fuzzyCost: number;
  // 至少一个音节由相邻按键替换得到
  corrected: boolean;
  // 纠错音节只由放宽档的邻键替换得到，手指其实按在自己的键中间，见 PinyinSegmenter 的 tapOnly
  tapped?: boolean;
  // 跨音节打反的两个字母分属两个词时，前一个词停在左半边上，下一个词必须从这条右半边开始
  openTail?: SyllableEdge;
  // 这个词从跨音节打反的右半边开始，只能接在停在对应左半边上的词后面
  closeTail?: SyllableEdge;
  // 叠字合成的词弧计算前后搭配时，开头按第一段叠字词、结尾按最后一段叠字词计算，见 joinRepeat
  head?: string;
  tail?: string;
  // 词弧得分里计入的用户词频与近期加分，计算 WHOLE_MARGIN 基准时剔除以免挤压其他正常词
  userBoost?: number;
  // 由用户简拼记忆整串命中的候选，当输入本身是合法全拼时用于排序层紧随全拼首位展示
  userAbbr?: boolean;
  // 来自用户记忆简拼通道的词弧，不参与全拼词弧的 WHOLE_MARGIN 基准拉高
  fromTyped?: boolean;
}

// 音节组合用链表表示，展开时不复制整串边；只有桶里有词条要核对时才拼出数组
interface PathState {
  edge: SyllableEdge;
  previous: PathState | undefined;
  depth: number;
  end: number;
  key: string;
  penalty: number;
  corrected: boolean;
  tapped: boolean;
  // 全部为完整音节
  exact: boolean;
}

function edgesOf(path: PathState): SyllableEdge[] {
  const edges: SyllableEdge[] = new Array<SyllableEdge>(path.depth);
  let cursor: PathState | undefined = path;
  for (let i = path.depth - 1; i >= 0 && cursor !== undefined; i--) {
    edges[i] = cursor.edge;
    cursor = cursor.previous;
  }
  return edges;
}

// 整句搜索的状态：到某个位置为止的最好得分，以及最后一个词。分隔符不产生新状态，原样传到分隔符之后
interface SearchState {
  score: number;
  arc: WordArc | undefined;
  previous: SearchState | undefined;
  // 这条历史拼出的文本，只在同一组里争名额时生成一次并缓存，见 pathText
  text?: string;
}

interface ScoredEntry {
  entry: LexiconEntry;
  cost: number;
  score: number;
}

// 词语排候选时用到的几个量，一次算好再排序，见 PinyinEngine.query
interface RankedArc {
  arc: WordArc;
  // 消耗到的拼音位置
  consumed: number;
  // 0：停在可以安全断开的位置；1：切进原文音节内部
  safe: number;
  // 0：读完整串且得分接近最好的这类词；1：其余
  whole: number;
  // 计入有上限的覆盖奖励后的得分
  score: number;
}

export interface SentencePath {
  arcs: WordArc[];
  score: number;
  corrected: boolean;
}

// 一个起点上按终点保留的最好词弧；exact 只含未经纠错的词弧，用于计算原文的最好整句
interface StartArcs {
  all: WordArc[];
  exact: WordArc[];
}

type StartArcsProvider = (position: number) => StartArcs;

/**
 * 一组读音与一串音节边逐个比对，全部满足时返回模糊音代价之和，否则返回 -1。
 */
function readingCost(syllables: string[], edges: SyllableEdge[]): number {
  if (syllables.length !== edges.length) {
    return -1;
  }
  let cost = 0;
  for (let i = 0; i < edges.length; i++) {
    const syllableCostValue = syllableCost(syllables[i], edges[i]);
    if (syllableCostValue < 0) {
      return -1;
    }
    cost += syllableCostValue;
  }
  return cost;
}

/**
 * 一条词弧的读音可靠度：纠错最先，其次是简拼或没打完的音节，再是完整音节但用了模糊等价读法，
 * 最后才是与键入完全一致的完整读音。exact 只说明音节都是完整音节，模糊音在 makeArc 里另记代价。
 */
function readingOfArc(arc: WordArc): CandidateReading {
  if (arc.corrected) {
    return CandidateReading.CORRECTED;
  }
  if (!arc.exact) {
    return CandidateReading.ABBREVIATION;
  }
  return arc.fuzzyCost > 0 ? CandidateReading.FUZZY : CandidateReading.FULL;
}

// 整串由多条词弧组成时取最弱的一档：有纠错就是纠错，其次简拼，再次模糊音
function readingOfArcs(arcs: WordArc[]): CandidateReading {
  let reading = CandidateReading.FULL;
  for (const arc of arcs) {
    const value = readingOfArc(arc);
    if (value === CandidateReading.CORRECTED) {
      return CandidateReading.CORRECTED;
    }
    if (value === CandidateReading.ABBREVIATION) {
      reading = CandidateReading.ABBREVIATION;
    } else if (value === CandidateReading.FUZZY && reading === CandidateReading.FULL) {
      reading = CandidateReading.FUZZY;
    }
  }
  return reading;
}

/**
 * 全是不带模糊读音的完整音节时，词条读音必须与音节逐个相同，返回以空格连接的音节，否则返回 undefined。
 */
function exactReading(edges: SyllableEdge[]): string | undefined {
  let key = '';
  for (let i = 0; i < edges.length; i++) {
    const edge = edges[i];
    if (edge.kind !== EdgeKind.FULL || edge.variants.length > 0) {
      return undefined;
    }
    key += i === 0 ? edge.text : ' ' + edge.text;
  }
  return key;
}

// 按得分插入前几名，名单保持从高到低
function offerTop(top: ScoredEntry[], scored: ScoredEntry, cap: number): void {
  if (top.length >= cap) {
    if (scored.score <= top[top.length - 1].score) {
      return;
    }
    top.pop();
  }
  let i = top.length;
  while (i > 0 && top[i - 1].score < scored.score) {
    i--;
  }
  top.splice(i, 0, scored);
}

// 两条跨音节打反的右半边位置与读音都相同时，可以互相代替
function sameTail(a: SyllableEdge | undefined, b: SyllableEdge | undefined): boolean {
  if (a === undefined || b === undefined) {
    return a === b;
  }
  return a.start === b.start && a.end === b.end && a.text === b.text;
}

function tailKey(tail: SyllableEdge | undefined): string {
  return tail === undefined ? '' : `|${tail.start}:${tail.end}:${tail.text}`;
}

// 两条词弧读音完全相同：同一个音节组里的同音词，词条共用同一个音节数组
function sameReading(a: WordArc, b: WordArc): boolean {
  return !a.corrected && !b.corrected && a.entry.syllables === b.entry.syllables;
}

/**
 * 同一终点保留得分最高的几个词，同一个词只留得分最高的一条。跨音节打反留下或接上的右半边不同，算作不同的词。
 * 有二元模型时，已经保留的同音词旁边再多留 HOMOPHONE_EXTRA 条：截断之前先让上下文排一次，
 * 例如 shi 的一组同音词按 unigram 只留三条时，适合当前上文的那个可能是第四条。
 * matchPath 取词时按同一个上限放宽，见 matchPool，否则这里看不到第四条。
 */
function keepTop(map: Map<number, WordArc[]>, arc: WordArc, allowHomophones: boolean): void {
  let list = map.get(arc.end);
  if (list === undefined) {
    map.set(arc.end, [arc]);
    return;
  }
  for (let i = 0; i < list.length; i++) {
    if (list[i].entry.word === arc.entry.word && sameTail(list[i].openTail, arc.openTail) &&
      sameTail(list[i].closeTail, arc.closeTail)) {
      if (arc.score > list[i].score) {
        list[i] = arc;
        list.sort((a: WordArc, b: WordArc) => b.score - a.score);
      }
      return;
    }
  }
  let cap = WORDS_PER_SPAN;
  if (allowHomophones) {
    for (const kept of list) {
      if (sameReading(kept, arc)) {
        cap += HOMOPHONE_EXTRA;
        break;
      }
    }
  }
  if (list.length < cap) {
    list.push(arc);
  } else if (arc.score > list[list.length - 1].score) {
    list[list.length - 1] = arc;
  } else {
    return;
  }
  list.sort((a: WordArc, b: WordArc) => b.score - a.score);
}

function flatten(map: Map<number, WordArc[]>): WordArc[] {
  let result: WordArc[] = [];
  map.forEach((list: WordArc[]) => {
    result = result.concat(list);
  });
  return result;
}

/**
 * 一条历史拼出的文本，递归取上一段的结果并缓存到状态上。
 * 只在同一组里争名额时调用，不是每条新状态都要拼一遍字符串。
 */
function pathText(state: SearchState): string {
  const cached = state.text;
  if (cached !== undefined) {
    return cached;
  }
  const prefix = state.previous !== undefined ? pathText(state.previous) : '';
  const word = state.arc !== undefined ? state.arc.entry.word : '';
  const text = prefix + word;
  state.text = text;
  return text;
}

// 后续的词只看这两样：接在哪个词后面（叠字词弧看实际末尾），以及有没有跨音节打反的右半边等着接。
// 两样都相同的状态，往后的走法完全一样，可以放在同一组里比较
function stateGroupKey(state: SearchState): string {
  const arc = state.arc;
  if (arc === undefined) {
    return '';
  }
  const word = arc.tail !== undefined ? arc.tail : arc.entry.word;
  return word + tailKey(arc.openTail);
}

/**
 * 同一组里按渲染文本去重：两种分词拼出同一个词串时只留得分最高的一条，不重复占组内名额。
 * 文本不同才继续保留，组内最多 GROUP_KEEP 条，同末词的同音分歧因此仍能往下走。
 */
function offerState(map: Map<string, SearchState[]>, state: SearchState): void {
  const key = stateGroupKey(state);
  const list = map.get(key);
  if (list === undefined) {
    map.set(key, [state]);
    return;
  }
  // 组已经满了、分数又进不了前几名时，文本相同与否都换不进来，先省掉拼文本
  if (list.length >= GROUP_KEEP && state.score <= list[list.length - 1].score) {
    return;
  }
  const text = pathText(state);
  for (let i = 0; i < list.length; i++) {
    if (pathText(list[i]) === text) {
      if (state.score > list[i].score) {
        list[i] = state;
        list.sort((a: SearchState, b: SearchState) => b.score - a.score);
      }
      return;
    }
  }
  if (list.length < GROUP_KEEP) {
    list.push(state);
    list.sort((a: SearchState, b: SearchState) => b.score - a.score);
    return;
  }
  if (state.score <= list[list.length - 1].score) {
    return;
  }
  list[list.length - 1] = state;
  list.sort((a: SearchState, b: SearchState) => b.score - a.score);
}

function groupsOf(map: Map<string, SearchState[]>): SearchState[][] {
  const groups: SearchState[][] = [];
  map.forEach((list: SearchState[]) => {
    if (list.length > 0) {
      groups.push(list);
    }
  });
  return groups;
}

/**
 * 往后扩展时每个位置最多带走 BEAM_WIDTH 条历史：先让每个“上一个词”各出最好的那一条，
 * 还有余量时再补第二组内的第二条。同末词的几种写法不会占满整个 beam。
 */
function selectBeam(map: Map<string, SearchState[]>): SearchState[] {
  const groups = groupsOf(map);
  groups.sort((a: SearchState[], b: SearchState[]) => b[0].score - a[0].score);
  const picked: SearchState[] = [];
  const leaders = Math.min(groups.length, BEAM_GROUPS);
  for (let i = 0; i < leaders && picked.length < BEAM_WIDTH; i++) {
    picked.push(groups[i][0]);
  }
  for (let round = 1; round < GROUP_KEEP && picked.length < BEAM_WIDTH; round++) {
    for (const list of groups) {
      if (round >= list.length) {
        continue;
      }
      picked.push(list[round]);
      if (picked.length >= BEAM_WIDTH) {
        return picked;
      }
    }
  }
  return picked;
}

// 走到串尾的全部历史，按得分从高到低，列整句方案时用
function allStates(map: Map<string, SearchState[]>): SearchState[] {
  const list: SearchState[] = [];
  map.forEach((states: SearchState[]) => {
    for (const state of states) {
      list.push(state);
    }
  });
  list.sort((a: SearchState, b: SearchState) => b.score - a.score);
  return list;
}

// 某个位置得分最高的那条历史，列整句前半段时用
function bestState(map: Map<string, SearchState[]>): SearchState | undefined {
  let best: SearchState | undefined = undefined;
  map.forEach((states: SearchState[]) => {
    if (states.length > 0 && (best === undefined || states[0].score > best.score)) {
      best = states[0];
    }
  });
  return best;
}

/**
 * 从每个位置出发，能否把剩下的拼音读完，纠错边也算在内。跨音节打反的右半边不能单独起头，左半边连着右半边一起算。
 */
function finishablePositions(lattice: SegmentLattice): boolean[] {
  const length = lattice.code.length;
  const result: boolean[] = new Array<boolean>(length + 1).fill(false);
  result[length] = true;
  for (let position = length - 1; position >= 0; position--) {
    for (const edge of lattice.edges[position]) {
      if (edge.swapTail === true) {
        continue;
      }
      const end = edge.swapNext !== undefined ? edge.swapNext.end : edge.end;
      if (result[end]) {
        result[position] = true;
        break;
      }
    }
  }
  return result;
}

// 一条整句里每个音节结束的位置，音节之间的分隔符不计在内
function syllableStops(path: SentencePath, code: string): Set<number> {
  const stops: Set<number> = new Set<number>();
  for (const arc of path.arcs) {
    let position = arc.start;
    for (const typed of arc.typed) {
      while (position < code.length && code.charAt(position) === SEPARATOR) {
        position++;
      }
      position += typed.length;
      stops.add(position);
    }
  }
  return stops;
}

function pathOf(state: SearchState): SentencePath {
  const arcs: WordArc[] = [];
  let corrected = false;
  let cursor: SearchState | undefined = state;
  while (cursor !== undefined) {
    if (cursor.arc !== undefined) {
      arcs.unshift(cursor.arc);
      corrected = corrected || cursor.arc.corrected;
    }
    cursor = cursor.previous;
  }
  const path: SentencePath = { arcs: arcs, score: state.score, corrected: corrected };
  return path;
}

// 叠字的一种拆法：依次用到的叠字词与总得分
interface RepeatPath {
  arcs: WordArc[];
  score: number;
}

// 一个字可用的各种长度的叠字词弧，pieces[k] 是 k 个字的那一个；rank 是排序用的得分
interface RepeatChoice {
  pieces: (WordArc | undefined)[];
  rank: number;
}

// 按字排好先后的叠字，common 是这个字母最常用的单字所在的位置，没有时为 -1
interface RepeatRanking {
  choices: RepeatChoice[];
  common: number;
}

// 从 start 开始同一个字母连按了几次，不是字母时为 0
function letterRunAt(code: string, start: number): number {
  const letter = code.charAt(start);
  if (letter < 'a' || letter > 'z') {
    return 0;
  }
  let end = start + 1;
  while (end < code.length && code.charAt(end) === letter) {
    end++;
  }
  return end - start;
}

/**
 * 整句搜索在 position 处补上叠字词弧的条件：这里是一串同一个声母的开头，至少连按 REPEAT_MIN_LETTERS 次。
 * a、e、o 自身就是音节，常常是前一个音节的末尾，例如 jiaaa 里的第一个 a，不在这里处理
 */
function startsConsonantRun(code: string, position: number): boolean {
  const letter = code.charAt(position);
  if (letter === 'a' || letter === 'e' || letter === 'o' || (position > 0 && code.charAt(position - 1) === letter)) {
    return false;
  }
  return letterRunAt(code, position) >= REPEAT_MIN_LETTERS;
}

// 词语由同一个字重复组成时返回这个字，否则返回空串。代理对组成的字不参与叠字
function repeatedChar(word: string): string {
  const first = word.charAt(0);
  const code = word.charCodeAt(0);
  if (word.length === 0 || (code >= 0xD800 && code <= 0xDFFF)) {
    return '';
  }
  for (let i = 1; i < word.length; i++) {
    if (word.charAt(i) !== first) {
      return '';
    }
  }
  return first;
}

/**
 * 本地全拼引擎：音节词格、Viterbi 整句、按长度与分数排列候选。
 */
export class PinyinEngine implements CandidateProvider, EngineAdapter {
  private lexicon: Lexicon;
  private userModel: UserModel | undefined = undefined;
  private transitions: TransitionModel | undefined = undefined;
  // 当前词格上各位置起始的音节边，见 syllableEdgesAt
  private edgeTableLattice: SegmentLattice | undefined = undefined;
  private edgeTable: (SyllableEdge[] | undefined)[] = [];
  // edgeTable 每一项读到的最远位置，跨越分隔符时大于起点
  private edgeReach: number[] = [];
  // 跨查询沿用的各起点词弧，见 startArcsProvider
  private arcCache: Map<number, ArcCacheEntry> = new Map<number, ArcCacheEntry>();
  private arcCacheSignatures: string[] = [];
  private arcCacheKey: string = '';
  // 当前这次搜索读到的最远位置
  private readUpTo: number = 0;
  // 整句第一个词的前词，由上文得出，见 TransitionModel.contextOf
  private contextWord: string = '';
  private hasPreviousContext: boolean = false;
  private sessionId: number = 0;
  private lastSnapshot: EngineSnapshot | undefined = undefined;
  private lastCandidates: Candidate[] = [];
  // 候选栏显示拼音切分时复用最近一次查询的整句，同一输入串不再重复计算
  private cachedValid: boolean = false;
  private cachedCode: string = '';
  private cachedOptions: QueryOptions | undefined = undefined;
  private cachedPath: SentencePath | undefined = undefined;
  // 最近一次整句搜索在每个位置留下的状态，列整句的前半段时直接取用，不再另外搜索
  private searchStates: Map<string, SearchState[]>[] = [];

  constructor(lexicon: Lexicon) {
    this.lexicon = lexicon;
  }

  setUserModel(model: UserModel | undefined): void {
    this.userModel = model;
    this.cachedValid = false;
    // 词弧池与学习加分都取决于模型，旧缓存不能接着用
    this.invalidateArcs();
  }

  setBigramModel(model: TransitionModel | undefined): void {
    this.transitions = model;
    this.cachedValid = false;
    // 同音词弧池的大小取决于有没有二元模型，换模型以后旧词弧不能沿用
    this.invalidateArcs();
  }

  private invalidateArcs(): void {
    this.arcCache = new Map<number, ArcCacheEntry>();
    this.arcCacheKey = '';
    this.arcCacheSignatures = [];
  }

  isReady(): boolean {
    return this.lexicon.size() > 0;
  }

  // ---------- 词格 ----------

  private hasKeyPrefix(key: string): boolean {
    if (this.lexicon.hasKeyPrefix(key)) {
      return true;
    }
    const model = this.userModel;
    return model !== undefined && model.hasKeyPrefix(key);
  }

  /**
   * 从起点出发枚举音节组合并查词。没有任何词以当前索引键开头时不再往下展开，
   * 一个词最多含一个纠错音节，未经纠错的组合先展开。
   */
  collectArcs(lattice: SegmentLattice, start: number, previousText: string, allMatches: boolean): WordArc[] {
    const arcs: WordArc[] = [];
    const edgesAtStart = lattice.edges[start];
    if (edgesAtStart === undefined) {
      return arcs;
    }
    const userMax = this.userModel !== undefined ? this.userModel.maxSyllables() : 0;
    const maxDepth = Math.max(this.lexicon.maxSyllables(), userMax);
    const stack: PathState[] = [];
    const pushPath = (previous: PathState | undefined, edge: SyllableEdge): void => {
      const penalty = (previous !== undefined ? previous.penalty : 0) + edge.penalty;
      if (penalty > MAX_PATH_PENALTY) {
        return;
      }
      const key = (previous !== undefined ? previous.key : '') + keyLetter(edge.text);
      if (!this.hasKeyPrefix(key)) {
        return;
      }
      const path: PathState = {
        edge: edge,
        previous: previous,
        depth: previous !== undefined ? previous.depth + 1 : 1,
        end: edge.end,
        key: key,
        penalty: penalty,
        corrected: (previous !== undefined && previous.corrected) || edge.corrected,
        tapped: (previous !== undefined && previous.tapped) || (edge.corrected && edge.tapOnly === true),
        exact: (previous === undefined || previous.exact) && edge.kind === EdgeKind.FULL
      };
      stack.push(path);
    };
    // 栈顶先出，纠错边先入栈，原文的组合先展开。跨音节打反的左半边后面只能接自己的右半边，
    // 右半边不能单独使用，见 PinyinSegmenter.addCrossSwaps
    const pushAll = (previous: PathState | undefined, edges: SyllableEdge[]): void => {
      const pairedTail = previous !== undefined ? previous.edge.swapNext : undefined;
      if (pairedTail !== undefined) {
        pushPath(previous, pairedTail);
        return;
      }
      for (const edge of edges) {
        if (edge.corrected && edge.swapTail !== true && (previous === undefined || !previous.corrected)) {
          pushPath(previous, edge);
        }
      }
      for (const edge of edges) {
        if (!edge.corrected && edge.kind !== EdgeKind.SEPARATOR) {
          pushPath(previous, edge);
        }
      }
    };
    // 整句搜索里，词也可以从跨音节打反的右半边开始，前一个词停在对应的左半边上。
    // 这些组合先入栈、最后展开，不挤占原文组合的展开次数
    if (!allMatches) {
      for (const edge of edgesAtStart) {
        if (edge.swapTail === true) {
          pushPath(undefined, edge);
        }
      }
    }
    pushAll(undefined, edgesAtStart);
    let visited = 0;
    while (stack.length > 0 && visited < MAX_PATHS_PER_START) {
      const path = stack.pop() as PathState;
      visited++;
      // 列候选时，词不能停在跨音节打反的左半边上，整句搜索里可以，下一个词从右半边开始
      if (path.edge.swapNext === undefined || !allMatches) {
        this.matchPath(path, start, previousText, allMatches, arcs);
      }
      if (path.depth < maxDepth) {
        pushAll(path, this.syllableEdgesAt(lattice, path.end));
      }
    }
    this.addTypedArcs(lattice, start, previousText, allMatches, arcs);
    return arcs;
  }

  /**
   * 用户按过的简拼与已学多字词首字母索引：从 start 起逐个取字母（跳过分隔符），与学习记录比对。
   * 1) typedLookup：用户实际用简拼或分隔符打出过的词，全串及局部均可参与组词，仅扣一次简拼惩罚。
   * 2) initialsLookup：用户用全拼打过的多字词自动建的首字母索引：
   *    - 输入本身不能只用带元音的完整音节切开时（如 srf、hm、pb、dn、fzl），全位置参与组词与简拼召回；
   *    - 输入恰好能被完整元音音节切开时（如 wan、fa、de），只在整串列候选时作为 USER_ABBR 紧随全拼首位列出，不干扰正常全拼切分。
   */
  private addTypedArcs(lattice: SegmentLattice, start: number, previousText: string, allMatches: boolean,
    out: WordArc[]): void {
    const model = this.userModel;
    const code = lattice.code;
    const maxTyped = model !== undefined ? model.maxTypedLetters() : 0;
    const maxInitials = model !== undefined ? model.maxInitialsLetters() : 0;
    const limit = Math.max(maxTyped, maxInitials);
    if (model === undefined || limit === 0 || code.charAt(start) === SEPARATOR) {
      return;
    }
    const letters: string[] = [];
    let position = start;
    while (position < code.length && letters.length < limit) {
      const c = code.charAt(position);
      position++;
      if (c === SEPARATOR) {
        continue;
      }
      letters.push(c);
      const key = letters.join('');
      let emitted: Set<LexiconEntry> | undefined = undefined;
      if (letters.length <= maxTyped) {
        for (const entry of model.typedLookup(key)) {
          out.push(this.typedArc(start, position, entry, letters, previousText, PENALTY_ABBREVIATION,
            start === 0 && position === code.length, true));
          if (emitted === undefined) {
            emitted = new Set<LexiconEntry>();
          }
          emitted.add(entry);
        }
      }
      const allowInitials = !lattice.strictVowelCovered ||
        (allMatches && start === 0 && position === code.length);
      if (allowInitials && letters.length <= maxInitials) {
        const userAbbr = lattice.strictVowelCovered;
        const fromTyped = lattice.strictVowelCovered;
        for (const entry of model.initialsLookup(key)) {
          if (emitted !== undefined && emitted.has(entry)) {
            continue;
          }
          const penalty = PENALTY_ABBREVIATION * Math.min(entry.syllables.length, 4);
          out.push(this.typedArc(start, position, entry, letters, previousText, penalty, userAbbr, fromTyped));
        }
      }
    }
    // 多按一个字母可能凑成另一串记过的简拼，读到的位置计入缓存判断
    this.readUpTo = Math.max(this.readUpTo, position);
  }

  private typedArc(start: number, end: number, entry: LexiconEntry, letters: string[],
    previousText: string, penalty: number, userAbbr: boolean, fromTyped: boolean): WordArc {
    const boost = this.userModel !== undefined ? this.userModel.boost(entry, previousText, true) : 0;
    const wordBonus = WORD_BONUS_PER_SYLLABLE * (entry.syllables.length - 1);
    // 一个字母对应一个音节时按字母切开显示，否则整串作为一段
    const typed = letters.length === entry.syllables.length ? letters.slice() : [letters.join('')];
    const arc: WordArc = {
      start: start,
      end: end,
      entry: entry,
      score: entry.logProb - penalty + boost + wordBonus,
      typed: typed,
      exact: false,
      fuzzyCost: 0,
      corrected: false,
      userBoost: boost,
      userAbbr: userAbbr,
      fromTyped: fromTyped
    };
    return arc;
  }

  /**
   * 某个位置起始的音节边，词条可以跨越分隔符，例如 xi'an 对应“西安”。
   * 同一个词格在各个起点反复用到同一位置，结果按词格缓存。
   */
  private syllableEdgesAt(lattice: SegmentLattice, position: number): SyllableEdge[] {
    if (this.edgeTableLattice !== lattice) {
      this.edgeTableLattice = lattice;
      this.edgeTable = new Array<SyllableEdge[] | undefined>(lattice.edges.length);
      this.edgeReach = new Array<number>(lattice.edges.length).fill(0);
    }
    const cached = position < this.edgeTable.length ? this.edgeTable[position] : undefined;
    if (cached !== undefined) {
      this.readUpTo = Math.max(this.readUpTo, this.edgeReach[position]);
      return cached;
    }
    const result: SyllableEdge[] = [];
    let cursor = position;
    let reach = position;
    while (cursor < lattice.edges.length) {
      reach = cursor;
      let separatorEnd = -1;
      for (const edge of lattice.edges[cursor]) {
        if (edge.kind === EdgeKind.SEPARATOR) {
          separatorEnd = edge.end;
        } else {
          result.push(edge);
        }
      }
      if (separatorEnd < 0) {
        break;
      }
      cursor = separatorEnd;
    }
    this.readUpTo = Math.max(this.readUpTo, reach);
    if (position < this.edgeTable.length) {
      this.edgeTable[position] = result;
      this.edgeReach[position] = reach;
    }
    return result;
  }

  /**
   * 一段拼音取几条词弧。列候选时取满 MATCHES_PER_PATH，整句搜索只要前几名；
   * 有二元模型时多取 HOMOPHONE_EXTRA 条，好让 keepTop 看到第四条同音词，再由上下文重排。
   */
  private matchPool(allMatches: boolean): number {
    if (allMatches) {
      return MATCHES_PER_PATH;
    }
    return this.transitions !== undefined ? WORDS_PER_SPAN + HOMOPHONE_EXTRA : WORDS_PER_SPAN;
  }

  private matchPath(path: PathState, start: number, previousText: string, allMatches: boolean,
    out: WordArc[]): void {
    const model = this.userModel;
    const userBucket = model !== undefined ? model.lookup(path.key) : EMPTY_ENTRIES;
    const groups = path.depth <= this.lexicon.maxSyllables() ? this.lexicon.groups(path.key) : EMPTY_GROUPS;
    if (userBucket.length === 0 && groups.length === 0) {
      return;
    }
    const edges = edgesOf(path);
    for (const entry of userBucket) {
      const cost = readingCost(entry.syllables, edges);
      if (cost >= 0) {
        out.push(this.makeArc(start, path, edges, entry, cost, previousText));
      }
    }
    if (groups.length === 0) {
      return;
    }
    const pool = this.matchPool(allMatches);
    // 全是完整音节时只有读音相同的一组能匹配，直接取出，组内已按概率排好
    const exactKey = exactReading(edges);
    if (exactKey !== undefined) {
      const group = this.lexicon.group(path.key, exactKey);
      if (group !== undefined) {
        for (let i = 0; i < group.entries.length && i < pool; i++) {
          out.push(this.makeArc(start, path, edges, group.entries[i], 0, previousText));
        }
      }
      return;
    }
    // 含有简拼、没打完的音节或模糊读音时逐组核对。组按组内最高概率排列，代价不为负；
    // 组内最高概率已不高于第 pool 名的得分时，后面的组不会更好
    const top: ScoredEntry[] = [];
    for (const group of groups) {
      if (!allMatches && top.length >= pool && group.entries[0].logProb <= top[top.length - 1].score) {
        break;
      }
      const cost = readingCost(group.syllables, edges);
      if (cost < 0) {
        continue;
      }
      for (const entry of group.entries) {
        if (!allMatches && top.length >= pool && entry.logProb - cost <= top[top.length - 1].score) {
          break;
        }
        const scored: ScoredEntry = { entry: entry, cost: cost, score: entry.logProb - cost };
        if (allMatches) {
          top.push(scored);
        } else {
          offerTop(top, scored, pool);
        }
      }
    }
    // 列出全部匹配时与原来逐条扫描一致，按词条概率取前 MATCHES_PER_PATH 个
    if (allMatches) {
      top.sort((a: ScoredEntry, b: ScoredEntry) => b.entry.logProb - a.entry.logProb);
    }
    for (let i = 0; i < top.length && i < pool; i++) {
      out.push(this.makeArc(start, path, edges, top[i].entry, top[i].cost, previousText));
    }
  }

  private makeArc(start: number, path: PathState, edges: SyllableEdge[], entry: LexiconEntry, cost: number,
    previousText: string): WordArc {
    const boost = this.userModel !== undefined ? this.userModel.boost(entry, previousText, !path.exact) : 0;
    const wordBonus = WORD_BONUS_PER_SYLLABLE * (entry.syllables.length - 1);
    const typed: string[] = new Array<string>(edges.length);
    for (let i = 0; i < edges.length; i++) {
      typed[i] = edges[i].typed;
    }
    const arc: WordArc = {
      start: start,
      end: path.end,
      entry: entry,
      score: entry.logProb - path.penalty - cost + boost + wordBonus,
      typed: typed,
      exact: path.exact,
      fuzzyCost: cost,
      corrected: path.corrected,
      tapped: path.tapped,
      userBoost: boost
    };
    if (path.edge.swapNext !== undefined) {
      arc.openTail = path.edge.swapNext;
    }
    if (edges.length > 0 && edges[0].swapTail === true) {
      arc.closeTail = edges[0];
    }
    return arc;
  }

  // ---------- 整句 ----------

  private startArcs(lattice: SegmentLattice, position: number, context: string): StartArcs {
    const all: Map<number, WordArc[]> = new Map<number, WordArc[]>();
    const exact: Map<number, WordArc[]> = new Map<number, WordArc[]>();
    // 跨音节打反分属两个词的词弧单独保留前几名，不与普通词弧争名额
    const paired: Map<number, WordArc[]> = new Map<number, WordArc[]>();
    // 有二元模型时，同音词保留得宽一些，交给上下文在整句搜索里重排
    const homophones = this.transitions !== undefined;
    for (const arc of this.collectArcs(lattice, position, context, false)) {
      if (arc.openTail !== undefined || arc.closeTail !== undefined) {
        keepTop(paired, arc, false);
        continue;
      }
      keepTop(all, arc, homophones);
      if (!arc.corrected) {
        keepTop(exact, arc, homophones);
      }
    }
    for (const arc of this.repeatArcs(lattice, position, context)) {
      keepTop(all, arc, false);
      keepTop(exact, arc, false);
    }
    const result: StartArcs = { all: flatten(all).concat(flatten(paired)), exact: flatten(exact) };
    return result;
  }

  private transition(state: SearchState, arc: WordArc): number {
    const model = this.transitions;
    if (model === undefined) {
      return 0;
    }
    const next = arc.head !== undefined ? arc.head : arc.entry.word;
    if (state.arc === undefined) {
      if (this.contextWord.length === 0) {
        return 0;
      }
      const bonus = model.bonus(this.contextWord, next);
      // 空上文（句首）且非完整全拼时，用户已经确认过的字词不受 <s> 回退负分压制
      if (bonus < 0 && !arc.exact && !this.hasPreviousContext &&
        this.userModel !== undefined && this.userModel.hasRecord(arc.entry)) {
        return 0;
      }
      return bonus;
    }
    return model.bonus(state.arc.tail !== undefined ? state.arc.tail : state.arc.entry.word, next);
  }

  private setContext(previousText: string): void {
    this.hasPreviousContext = previousText.length > 0;
    this.contextWord = this.transitions !== undefined ? this.transitions.contextOf(previousText) : '';
  }

  // 各起点的词弧只计算一次，含纠错与不含纠错的两次整句搜索共用
  /**
   * 连续打字时，每加一个字母，只有靠近末尾的几个位置会多出或少掉音节边。
   * 某个起点上次搜索读过的位置，如果这次的边特征串都没变，词弧原样沿用，不再重新搜索。
   * 上文或学习记录变了，缓存整体作废。
   */
  private startArcsProvider(lattice: SegmentLattice, previousText: string): StartArcsProvider {
    const signatures = edgeSignatures(lattice);
    const cacheKey = `${previousText}\t${this.userModel !== undefined ? this.userModel.revision() : -1}` +
      `\t${lattice.strictVowelCovered ? 1 : 0}`;
    const previous = cacheKey === this.arcCacheKey ? this.arcCache : new Map<number, ArcCacheEntry>();
    const previousSignatures = this.arcCacheSignatures;
    const current: Map<number, ArcCacheEntry> = new Map<number, ArcCacheEntry>();
    this.arcCacheKey = cacheKey;
    this.arcCache = current;
    this.arcCacheSignatures = signatures;
    const unchanged = (from: number, to: number): boolean => {
      if (to >= signatures.length || to >= previousSignatures.length) {
        return false;
      }
      for (let q = from; q <= to; q++) {
        if (signatures[q] !== previousSignatures[q]) {
          return false;
        }
      }
      return true;
    };
    return (position: number): StartArcs => {
      let entry = current.get(position);
      if (entry === undefined) {
        const old = previous.get(position);
        if (old !== undefined && unchanged(position, old.readUpTo)) {
          entry = old;
        } else {
          this.readUpTo = position;
          const arcs = this.startArcs(lattice, position, position === 0 ? previousText : '');
          const created: ArcCacheEntry = { arcs: arcs, readUpTo: this.readUpTo };
          entry = created;
        }
        current.set(position, entry);
      }
      return entry.arcs;
    };
  }

  /**
   * 整句搜索。每个位置按“上一个词”分别记录最好得分，接下一个词时加上二元模型的修正量，
   * 第一个词的前词由上文得出。每个位置只保留得分最高的 BEAM_WIDTH 种状态，
   * 没有二元模型时，结果与只记最好得分的动态规划相同。
   */
  private viterbi(lattice: SegmentLattice, arcsAt: StartArcsProvider, allowCorrection: boolean):
    SentencePath | undefined {
    const finals = this.search(lattice, arcsAt, allowCorrection);
    return finals.length > 0 ? pathOf(finals[0]) : undefined;
  }

  /**
   * 走到串尾的全部历史，按得分从高到低排列。同一组里是不同文本的几条，列整句方案时再按文本去重。
   * 每个位置按“上一个词 + 跨音节打反挂起状态”分组，组内留 GROUP_KEEP 条不同文本的历史，
   * 向后扩展时按组分配 beam，见 selectBeam。
   */
  private search(lattice: SegmentLattice, arcsAt: StartArcsProvider, allowCorrection: boolean,
    keepStates: boolean = false): SearchState[] {
    const length = lattice.code.length;
    if (keepStates) {
      this.searchStates = [];
    }
    if (length === 0 || !lattice.covered) {
      return [];
    }
    const states: Map<string, SearchState[]>[] = [];
    for (let i = 0; i <= length; i++) {
      states.push(new Map<string, SearchState[]>());
    }
    if (keepStates) {
      this.searchStates = states;
    }
    const origin: SearchState = { score: 0, arc: undefined, previous: undefined };
    offerState(states[0], origin);
    for (let position = 0; position < length; position++) {
      const current = selectBeam(states[position]);
      if (current.length === 0) {
        continue;
      }
      for (const edge of lattice.edges[position]) {
        if (edge.kind === EdgeKind.SEPARATOR) {
          for (const state of current) {
            offerState(states[edge.end], state);
          }
        }
      }
      const starts = arcsAt(position);
      for (const arc of allowCorrection ? starts.all : starts.exact) {
        for (const state of current) {
          // 跨音节打反分属两个词时，后一个词必须从前一个词留下的右半边开始
          if (!sameTail(state.arc !== undefined ? state.arc.openTail : undefined, arc.closeTail)) {
            continue;
          }
          const next: SearchState = {
            score: state.score + arc.score + this.transition(state, arc),
            arc: arc,
            previous: state
          };
          offerState(states[arc.end], next);
        }
      }
    }
    return allStates(states[length]);
  }

  // ---------- 叠字 ----------

  /**
   * 用一个字的各种长度的叠字词拼出 letters 个字，pieces[k] 是 k 个字的叠字词弧，得分是各段词弧的得分之和。
   * 这里不计相邻两词的搭配修正量：聊天语料里的刷屏让一些罕见叠词接自己时的修正量高达八九分，
   * 计入以后“农农农农”会排到“奶奶奶奶”前面。拼不出来时返回 undefined。
   */
  private repeatPath(pieces: (WordArc | undefined)[], letters: number): RepeatPath | undefined {
    // best[i]：拼出前 i 个字的最好得分，last[i] 是这种拼法最后一段的字数
    const best: number[] = new Array<number>(letters + 1).fill(-Infinity);
    const last: number[] = new Array<number>(letters + 1).fill(0);
    best[0] = 0;
    for (let i = 1; i <= letters; i++) {
      for (let k = 1; k < pieces.length && k <= i; k++) {
        const arc = pieces[k];
        if (arc !== undefined && best[i - k] > -Infinity && best[i - k] + arc.score > best[i]) {
          best[i] = best[i - k] + arc.score;
          last[i] = k;
        }
      }
    }
    if (best[letters] === -Infinity) {
      return undefined;
    }
    const arcs: WordArc[] = [];
    for (let position = letters; position > 0; position -= last[position]) {
      arcs.unshift(pieces[last[position]] as WordArc);
    }
    const path: RepeatPath = { arcs: arcs, score: best[letters] };
    return path;
  }

  /**
   * 从 start 起一串同一个字母上可用的叠字，按字排好先后。arcs 是从 start 出发的全部词弧，叠字词就从中挑出。
   * 词库里有叠词的字参与比较，这个字母最常用的单字也参与，例如 b 的不。
   * 各个字按连按三到六个字母时的得分之和排序，与实际按了几个字母无关。
   */
  private repeatChoices(arcs: WordArc[], start: number): RepeatRanking {
    const piecesByChar: Map<string, (WordArc | undefined)[]> = new Map<string, (WordArc | undefined)[]>();
    let topChar = '';
    let topCharScore = -Infinity;
    for (const arc of arcs) {
      const length = arc.entry.syllables.length;
      const ch = repeatedChar(arc.entry.word);
      if (arc.corrected || ch.length === 0 || arc.start !== start || arc.end - start !== length ||
        arc.entry.word.length !== length) {
        continue;
      }
      let pieces = piecesByChar.get(ch);
      if (pieces === undefined) {
        pieces = [];
        piecesByChar.set(ch, pieces);
      }
      while (pieces.length <= length) {
        pieces.push(undefined);
      }
      const known = pieces[length];
      if (known === undefined || arc.score > known.score) {
        pieces[length] = arc;
      }
      if (length === 1 && arc.score > topCharScore) {
        topChar = ch;
        topCharScore = arc.score;
      }
    }
    const choices: RepeatChoice[] = [];
    const chars: string[] = [];
    piecesByChar.forEach((pieces: (WordArc | undefined)[], ch: string) => {
      if (pieces.length <= 2 && ch !== topChar) {
        return;
      }
      let rank = 0;
      for (let letters = REPEAT_REFERENCE_MIN; letters <= REPEAT_REFERENCE_MAX; letters++) {
        const reference = this.repeatPath(pieces, letters);
        rank += reference !== undefined ? reference.score : -Infinity;
      }
      if (rank === -Infinity) {
        return;
      }
      let i = choices.length;
      while (i > 0 && choices[i - 1].rank < rank) {
        i--;
      }
      const choice: RepeatChoice = { pieces: pieces, rank: rank };
      choices.splice(i, 0, choice);
      chars.splice(i, 0, ch);
    });
    const ranking: RepeatRanking = { choices: choices, common: chars.indexOf(topChar) };
    return ranking;
  }

  // 把一种叠字拆法合成一条词弧，整句搜索与候选列表都把它当作一个词，bonus 加在得分上
  private joinRepeat(path: RepeatPath, bonus: number): WordArc {
    let word = '';
    let syllables: string[] = [];
    let typed: string[] = [];
    let exact = true;
    let fuzzyCost = 0;
    for (const arc of path.arcs) {
      word += arc.entry.word;
      syllables = syllables.concat(arc.entry.syllables);
      typed = typed.concat(arc.typed);
      exact = exact && arc.exact;
      fuzzyCost += arc.fuzzyCost;
    }
    const start = path.arcs[0].start;
    const entry: LexiconEntry = { syllables: syllables, word: word, logProb: path.score };
    const arc: WordArc = {
      start: start,
      end: start + syllables.length,
      entry: entry,
      score: path.score + bonus,
      typed: typed,
      exact: exact,
      fuzzyCost: fuzzyCost,
      corrected: false,
      head: path.arcs[0].entry.word,
      tail: path.arcs[path.arcs.length - 1].entry.word
    };
    return arc;
  }

  /**
   * 一串同一个声母连按 REPEAT_MIN_LETTERS 次以上时，把排在最前的叠字当作一个词放进整句搜索，
   * 例如 bbbbbwql 里的五个 b。叠字覆盖整串字母；后面紧跟韵母时也可以少一个，
   * 因为最后一个字母可能是下一个音节的声母，例如 hhhhhhao 的最后一个 h。
   * 只覆盖前面几个字母的叠字不放进来，否则“别别别”接“宝宝”这种半路换字的拆法也能拿到加分。
   */
  private repeatArcs(lattice: SegmentLattice, position: number, context: string): WordArc[] {
    const result: WordArc[] = [];
    const code = lattice.code;
    if (!startsConsonantRun(code, position)) {
      return result;
    }
    const run = letterRunAt(code, position);
    const choices = this.repeatChoices(this.collectArcs(lattice, position, context, true), position).choices;
    // 多按一个同样的字母时，这里的叠字词弧要跟着变，所以把这串字母之后的位置也算作读过
    this.readUpTo = Math.max(this.readUpTo, position + run);
    if (choices.length === 0) {
      return result;
    }
    const after = code.charAt(position + run);
    const vowelAfter = after === 'a' || after === 'e' || after === 'i' || after === 'o' || after === 'u' ||
      after === 'v';
    const shortest = vowelAfter ? Math.max(REPEAT_MIN_LETTERS, run - 1) : run;
    for (let letters = shortest; letters <= run; letters++) {
      const path = this.repeatPath(choices[0].pieces, letters);
      if (path !== undefined) {
        result.push(this.joinRepeat(path, REPEAT_RUN_BONUS));
      }
    }
    return result;
  }

  /**
   * 输入串从 start 起是一串同一个字母时的叠字候选，例如 bbbbb 的宝宝宝宝宝与不不不不不。
   * 取排在前面的 REPEAT_CANDIDATES 个字，这个字母最常用的单字排名靠后时补在最后。
   * 候选消耗整串同样的字母，后面还有别的拼音时留在输入框里继续组词。
   */
  private repeatCandidates(code: string, arcs: WordArc[], start: number,
    boundaries: boolean[] | undefined): Candidate[] {
    const result: Candidate[] = [];
    const run = letterRunAt(code, start);
    if (run < REPEAT_MIN_LETTERS) {
      return result;
    }
    const ranking = this.repeatChoices(arcs, start);
    const choices: RepeatChoice[] = ranking.choices.slice(0, REPEAT_CANDIDATES);
    if (ranking.common >= REPEAT_CANDIDATES) {
      choices.push(ranking.choices[ranking.common]);
    }
    for (const choice of choices) {
      const path = this.repeatPath(choice.pieces, run);
      if (path === undefined) {
        continue;
      }
      const arc = path.arcs.length === 1 ? path.arcs[0] : this.joinRepeat(path, 0);
      const candidate = this.arcCandidate(arc, code, boundaries);
      if (path.arcs.length > 1) {
        candidate.source = CandidateSource.SENTENCE;
      }
      result.push(candidate);
    }
    return result;
  }

  bestPath(lattice: SegmentLattice, previousText: string): SentencePath | undefined {
    this.setContext(previousText);
    return this.viterbi(lattice, this.startArcsProvider(lattice, previousText), true);
  }

  // ---------- 候选 ----------

  /**
   * 候选顺序：同一个字母连按多次时，叠字候选排在最前，见 repeatCandidates。
   * 然后是最好的整句与得分相近的少量整句方案，按文本去重；最好整句用到了纠错时，原文的最好整句紧随其后。
   * 再是最好整句的前半段，最后是从首字开始的词与单字：读完整串、又不比最好的这类词差太多的排在最前，
   * 其余按“停在可以安全断开的位置”优先、再按得分加有上限的覆盖奖励排。
   * 纠错得到的词要么比同样长度的原文最佳词更可能，要么落后不超过 CORRECTED_LIST_MARGIN，数量也有限。
   * 原文读得通时，纠错得到的词还必须停在原文的音节边界上，同一个词有原文读法时只列原文读法。
   * 选了以后剩下的拼音连纠错也读不完的词不列出；一个词都列不出时，退而保留能确认的合法开头。
   * 原文候选始终排在最后，文字原样包括分隔符，选择它不参与学习。
   * 返回的条数严格不超过 limit，limit 为 1 时只给出最好的一条（无可读内容时就是原文）。
   */
  query(code: string, previousText: string, limit: number,
    options: QueryOptions = DEFAULT_QUERY_OPTIONS): Candidate[] {
    const candidates: Candidate[] = [];
    if (code.length === 0 || limit <= 0) {
      return candidates;
    }
    const lattice = buildLattice(code, options);
    const arcsAt = this.startArcsProvider(lattice, previousText);
    this.setContext(previousText);
    const finals = this.search(lattice, arcsAt, true, true);
    const best = finals.length > 0 ? pathOf(finals[0]) : undefined;
    this.cachedValid = true;
    this.cachedCode = code;
    this.cachedOptions = options;
    this.cachedPath = best;
    const seen: Set<string> = new Set<string>();
    let firstStart = 0;
    while (firstStart < code.length && code.charAt(firstStart) === SEPARATOR) {
      firstStart++;
    }
    const arcs = this.collectArcs(lattice, firstStart, previousText, true);
    // 整串都是同一个字母时叠字候选排在整句之前，后面还有别的拼音时排在整句之后
    const repeats = this.repeatCandidates(code, arcs, firstStart, lattice.boundaries);
    const repeatsFirst = firstStart + letterRunAt(code, firstStart) === code.length;
    if (repeatsFirst) {
      this.pushUnique(candidates, seen, repeats);
    }
    const boundaries = lattice.boundaries;
    for (const sentence of this.sentenceChoices(finals, best, lattice, arcsAt, boundaries)) {
      const candidate = this.sentenceCandidate(sentence, code, boundaries);
      if (candidate !== undefined && !seen.has(candidate.text)) {
        seen.add(candidate.text);
        candidates.push(candidate);
      }
    }
    const finishable = finishablePositions(lattice);
    if (best !== undefined && !best.corrected) {
      this.pushUnique(candidates, seen, this.sentencePrefixes(code, best, finishable));
    }
    if (!repeatsFirst) {
      this.pushUnique(candidates, seen, repeats);
    }
    const bestExactByEnd: Map<number, number> = new Map<number, number>();
    // 有原文读法的词不再列纠错读法，见下面的说明
    const exactWords: Set<string> = new Set<string>();
    for (const arc of arcs) {
      if (arc.corrected) {
        continue;
      }
      const known = bestExactByEnd.get(arc.end);
      if (known === undefined || arc.score > known) {
        bestExactByEnd.set(arc.end, arc.score);
      }
      // 整个词都由完整音节读出来时，无论原文能否读通，同一个词都不再列纠错读法。
      // 例如 zhegewentiwmoen 里的“这个问题”，纠错读法会把后面 wo 的 w 当成多打的字母吞掉
      if (arc.exact || (boundaries !== undefined && boundaries[arc.end])) {
        exactWords.add(arc.entry.word);
      }
    }
    let bestWhole = Number.NEGATIVE_INFINITY;
    for (const arc of arcs) {
      if (!arc.fromTyped && this.consumedAfter(arc, code) === code.length) {
        bestWhole = Math.max(bestWhole, arc.score - (arc.userBoost ?? 0));
      }
    }
    if (bestWhole === Number.NEGATIVE_INFINITY) {
      for (const arc of arcs) {
        if (this.consumedAfter(arc, code) === code.length) {
          bestWhole = Math.max(bestWhole, arc.score - (arc.userBoost ?? 0));
        }
      }
    }
    // 排序用的几个量一次算好：一条词弧消耗到哪、是否停在安全位置、是否读完整串、按覆盖奖励后的得分。
    // 桶里动辄上百条词弧，比较函数里不再逐条扫字符串
    const ranked: RankedArc[] = [];
    // 每个词未经纠错的完整音节读法：最长消耗到哪里，以及得分最高的那一条。
    // 简拼只切到半路的弱读法让位时，用这两样把可靠的读法补到同一个位置，见 listWordArcs
    const exactConsumed: Map<string, number> = new Map<string, number>();
    const exactArcs: Map<string, RankedArc> = new Map<string, RankedArc>();
    for (const arc of arcs) {
      const consumed = this.consumedAfter(arc, code);
      if (!arc.corrected && arc.exact) {
        const known = exactConsumed.get(arc.entry.word);
        if (known === undefined || consumed > known) {
          exactConsumed.set(arc.entry.word, consumed);
        }
      }
      // 读完整串、又不比最好的这类词差太多的词语排在最前，按得分排；用户记忆召回词也留在整串档
      const baseArcScore = arc.score - (arc.userBoost ?? 0);
      const whole = consumed === code.length &&
        (arc.userAbbr === true || arc.score >= bestWhole - WHOLE_MARGIN || baseArcScore >= bestWhole - WHOLE_MARGIN) ?
        0 : 1;
      // 停在可以安全断开的位置：整串读完，或者停在原文完整切分的音节边界上。
      // 切进原文音节内部的词排在后面，例如 huadoukaile 里的“花都”按 hua du 读，只消耗 huad
      let safe = 0;
      if (consumed !== code.length && boundaries !== undefined && !boundaries[consumed]) {
        safe = 1;
      }
      // 覆盖奖励有上限：音节再多也只补 MAX_LIST_BONUS，长词不会只靠长度一直往前提
      const bonus = Math.min(LIST_BONUS_PER_SYLLABLE * arc.entry.syllables.length, MAX_LIST_BONUS);
      const rank: RankedArc = {
        arc: arc,
        consumed: consumed,
        safe: safe,
        whole: whole,
        score: whole === 0 ? arc.score : arc.score + bonus
      };
      ranked.push(rank);
      if (!arc.corrected && arc.exact) {
        const best = exactArcs.get(arc.entry.word);
        if (best === undefined || rank.score > best.score) {
          exactArcs.set(arc.entry.word, rank);
        }
      }
    }
    ranked.sort((a: RankedArc, b: RankedArc) => {
      if (a.safe !== b.safe) {
        return a.safe - b.safe;
      }
      if (a.whole !== b.whole) {
        return a.whole - b.whole;
      }
      return b.score - a.score;
    });
    // 原文兜底：只要有输入就留一个位置。limit 只有 1 时不预留，先把唯一的名额给可确认的候选，
    // 一个正常候选都没有时才退回原文
    const hasRaw = code.length > 0;
    const wordLimit = limit <= 1 ? limit : Math.max(0, limit - (hasRaw ? 1 : 0));
    this.listWordArcs(candidates, seen, ranked, code, wordLimit, boundaries, finishable, exactWords, bestExactByEnd,
      exactConsumed, exactArcs);
    if (hasRaw && !seen.has(code) && candidates.length < limit) {
      candidates.push(rawCandidate(code));
    }
    if (candidates.length > limit) {
      candidates.length = limit;
    }
    this.lastCandidates = candidates;
    return candidates;
  }

  // 追加尚未列出的候选，同一文本只留排在前面的那条
  private pushUnique(candidates: Candidate[], seen: Set<string>, list: Candidate[]): void {
    for (const candidate of list) {
      if (!seen.has(candidate.text)) {
        seen.add(candidate.text);
        candidates.push(candidate);
      }
    }
  }

  /**
   * 整句方案：最好的整句，用到了纠错时再补原文的最好整句；
   * 至少由两个词组成时，把组内其余不同文本、得分在 SECOND_SENTENCE_MARGIN 以内的近分方案也列出来。
   * 同末词的两条路径都保留，例如“在说”与“再说”，短的多词句同样适用。总数不超过 SENTENCE_LIMIT。
   */
  private sentenceChoices(finals: SearchState[], best: SentencePath | undefined,
    lattice: SegmentLattice, arcsAt: StartArcsProvider, boundaries: boolean[] | undefined): SentencePath[] {
    const result: SentencePath[] = [];
    if (best === undefined) {
      return result;
    }
    const texts: Set<string> = new Set<string>();
    texts.add(this.sentenceText(best));
    result.push(best);
    if (best.corrected) {
      const exactBest = this.viterbi(lattice, arcsAt, false);
      if (exactBest !== undefined) {
        const text = this.sentenceText(exactBest);
        if (!texts.has(text)) {
          texts.add(text);
          result.push(exactBest);
        }
      }
    }
    // 纠错占了首选时只补一条原文的最好整句，其余近分方案不再占位：打错的时候首屏不该全是纠错整句。
    // 只打了一个词时，后面的词语候选已经覆盖同音词，整句备选同样不占位
    if (best.corrected || best.arcs.length < 2) {
      return result;
    }
    const bestLast = this.lastWordOf(best);
    for (let i = 1; i < finals.length && result.length < SENTENCE_LIMIT; i++) {
      if (finals[i].score < finals[0].score - SECOND_SENTENCE_MARGIN) {
        break;
      }
      const path = pathOf(finals[i]);
      // 不到两个词的走词语候选；原文读得通、最好整句也没用到纠错时，次好整句同样只取原文读法，
      // 以免选它时吞掉用户按的字母
      if (path.arcs.length < 2 || (path.corrected && !best.corrected && boundaries !== undefined)) {
        continue;
      }
      // 同一个末词的备选是这次新增的重点：在线说与再说这种短的多词句里，两种读法都要能选。
      // 末词不同时沿用原来的口径，最好整句至少三个词才列次好整句，免得只打了两个词时
      // 近分的另一种整句把词候选挤到后面
      if (this.lastWordOf(path) !== bestLast && best.arcs.length < 3) {
        continue;
      }
      const text = this.sentenceText(path);
      if (texts.has(text)) {
        continue;
      }
      texts.add(text);
      result.push(path);
    }
    return result;
  }

  // 整句的最后一个词，判断两条整句是否同末词时用
  private lastWordOf(path: SentencePath): string {
    return path.arcs.length > 0 ? path.arcs[path.arcs.length - 1].entry.word : '';
  }

  private sentenceText(path: SentencePath): string {
    let text = '';
    for (const arc of path.arcs) {
      text += arc.entry.word;
    }
    return text;
  }

  /**
   * 词语与单字：停在安全位置、整串读完的排在最前，其余按得分加有上限的覆盖奖励排。
   * 一个也列不出时（剩下的拼音连纠错也读不完），退而保留能确认的合法开头，用户仍可逐字改选或走原文。
   */
  private listWordArcs(candidates: Candidate[], seen: Set<string>, ranked: RankedArc[], code: string, limit: number,
    boundaries: boolean[] | undefined, finishable: boolean[], exactWords: Set<string>,
    bestExactByEnd: Map<number, number>, exactConsumed: Map<string, number>,
    exactArcs: Map<string, RankedArc>): void {
    let corrected = 0;
    const stranded: RankedArc[] = [];
    const offer = (rank: RankedArc): boolean => {
      const arc = rank.arc;
      if (seen.has(arc.entry.word)) {
        return false;
      }
      // 同一个词已有未经纠错的完整音节读法、这一条却只是切到半路的简拼或模糊近路时，让给可靠的那一条。
      // 例如 nihaouu 里的“你好”按 ni+h 只消耗 nih，不能抢在按 ni+hao 读的读法前面；
      // 读完整串的读法、以及纠错得到的读法不受这条限制，打错时的候选仍然照常列出
      if (!arc.corrected && !arc.exact && rank.consumed < code.length) {
        const exact = exactConsumed.get(arc.entry.word);
        if (exact !== undefined && exact > rank.consumed) {
          // 把可靠的读法补到弱读法原来的位置，用户第一眼看到的就是消耗完整的那个
          const better = exactArcs.get(arc.entry.word);
          if (better !== undefined) {
            offer(better);
          }
          return false;
        }
      }
      if (arc.corrected) {
        // 原文读得通时，纠错词必须在原文的音节边界上结束，选了它以后，剩下的拼音还是用户按的样子
        if (exactWords.has(arc.entry.word) || (boundaries !== undefined && !boundaries[arc.end])) {
          return false;
        }
        // 原文读得通、手指又按在自己的键中间时，纠成邻键得到的词必须比同样长度的原文最佳词更可能。
        // 这类纠正也放宽到 CORRECTED_LIST_MARGIN 时，正常打字有四分之一的首屏会混进邻键的词
        const exactScore = bestExactByEnd.get(arc.end);
        const strict = boundaries !== undefined && arc.tapped === true;
        if (corrected >= MAX_CORRECTED_WORDS || (strict && exactScore === undefined) ||
          (exactScore !== undefined && arc.score <= exactScore - (strict ? 0 : CORRECTED_LIST_MARGIN))) {
          return false;
        }
      }
      seen.add(arc.entry.word);
      candidates.push(this.arcCandidate(arc, code, boundaries, exactConsumed.get(arc.entry.word)));
      if (arc.corrected) {
        corrected++;
      }
      return true;
    };
    for (const rank of ranked) {
      if (candidates.length >= limit) {
        break;
      }
      const arc = rank.arc;
      if (seen.has(arc.entry.word)) {
        continue;
      }
      // 选了这个词以后，剩下的拼音连纠错也读不完，例如 mingzui 选消耗 mingz 的“名字”时只剩 ui
      if (rank.consumed < code.length && !finishable[rank.consumed]) {
        stranded.push(rank);
        continue;
      }
      offer(rank);
    }
    // 剩下的拼音连纠错也读不完的词排在能安全断开的前缀之后，不抢前面的位置。
    // 这一段也读不出完整内容时，用户仍能在这里找到能确认的合法开头，或改选、走原文
    for (const rank of stranded) {
      if (candidates.length >= limit) {
        break;
      }
      offer(rank);
    }
  }

  /**
   * 整句的前半段：取整句搜索停在中间某个位置上的最好走法，从长到短列出。
   * 只停在最好整句自己的音节边界上，例如 womenmingtianjian 停在 mingtian 之后，不停在 mingti 之后，
   * 以免把 tian 拆成 ti 与 an，列出“我们命题”。前半段至少有两个词，最后一个词至少有两个音节，因此不列“我们明”。
   * 前半段必须是最好整句开头的一段，例如 nihaowoshizhongguoren 列出“你好我是中国”，不列岔开的“你好我始终”。
   * 前半段不能用到纠错。跨词打反的左半边必须和后一个词一起选，不能停在它后面。
   */
  private sentencePrefixes(code: string, best: SentencePath, finishable: boolean[]): Candidate[] {
    const result: Candidate[] = [];
    const states = this.searchStates;
    const stops = syllableStops(best, code);
    let bestText = '';
    for (const arc of best.arcs) {
      bestText += arc.entry.word;
    }
    for (let end = code.length - 1; end > 0 && result.length < MAX_SENTENCE_PREFIXES; end--) {
      if (end >= states.length || !finishable[end] || !stops.has(end)) {
        continue;
      }
      const top = bestState(states[end]);
      if (top === undefined) {
        continue;
      }
      const path = pathOf(top);
      const last = path.arcs.length > 0 ? path.arcs[path.arcs.length - 1] : undefined;
      if (path.arcs.length < 2 || path.corrected || last === undefined || last.openTail !== undefined ||
        last.end !== end || last.entry.syllables.length < 2) {
        continue;
      }
      let text = '';
      let syllables: string[] = [];
      for (const arc of path.arcs) {
        text += arc.entry.word;
        syllables = syllables.concat(arc.entry.syllables);
      }
      if (text.length < bestText.length && bestText.startsWith(text)) {
        const consumed = this.consumedAfter(last, code);
        const reading = readingOfArcs(path.arcs);
        const meta: CandidateMeta = {
          reading: reading,
          complete: false,
          safeEnd: true,
          exactConsumed: reading === CandidateReading.CORRECTED ? 0 : consumed
        };
        result.push(this.makeCandidate(text, consumed, syllables, path.score, CandidateSource.SENTENCE, meta));
      }
    }
    return result;
  }

  // 选了这个词以后，剩下的拼音连纠错也读不完，例如 mingzui 选消耗 mingz 的“名字”时只剩 ui
  private strandsRest(arc: WordArc, code: string, finishable: boolean[]): boolean {
    const consumed = this.consumedAfter(arc, code);
    return consumed < code.length && !finishable[consumed];
  }

  // 一条词弧消耗到的拼音位置，紧随其后的分隔符一并消耗
  private consumedAfter(arc: WordArc, code: string): number {
    let consumed = arc.end;
    while (consumed < code.length && code.charAt(consumed) === SEPARATOR) {
      consumed++;
    }
    return consumed;
  }

  private arcCandidate(arc: WordArc, code: string, boundaries?: boolean[],
    exactConsumed?: number): Candidate {
    const source = this.userModel !== undefined && this.userModel.isUserEntry(arc.entry) ? CandidateSource.USER :
      (arc.entry.syllables.length === 1 ? CandidateSource.CHAR : CandidateSource.WORD);
    const consumed = this.consumedAfter(arc, code);
    const reading = readingOfArc(arc);
    const meta: CandidateMeta = {
      reading: reading,
      complete: consumed === code.length,
      safeEnd: consumed === code.length || boundaries === undefined || boundaries[consumed] === true,
      exactConsumed: exactConsumed !== undefined ? exactConsumed :
        (reading === CandidateReading.FULL || reading === CandidateReading.FUZZY ? consumed : 0)
    };
    if (arc.userAbbr === true) {
      meta.origin = CandidateOrigin.USER_ABBR;
    }
    return this.makeCandidate(arc.entry.word, consumed, arc.entry.syllables, arc.score, source, meta);
  }

  // 整句只有一个词时按普通词候选处理
  private sentenceCandidate(sentence: SentencePath, code: string,
    boundaries: boolean[] | undefined): Candidate | undefined {
    if (sentence.arcs.length === 0) {
      return undefined;
    }
    if (sentence.arcs.length === 1) {
      return this.arcCandidate(sentence.arcs[0], code, boundaries);
    }
    let text = '';
    let syllables: string[] = [];
    for (const arc of sentence.arcs) {
      text += arc.entry.word;
      syllables = syllables.concat(arc.entry.syllables);
    }
    const reading = readingOfArcs(sentence.arcs);
    const meta: CandidateMeta = {
      reading: reading,
      complete: true,
      safeEnd: true,
      exactConsumed: reading === CandidateReading.CORRECTED ? 0 : code.length
    };
    return this.makeCandidate(text, code.length, syllables, sentence.score, CandidateSource.SENTENCE, meta);
  }

  private makeCandidate(text: string, consumed: number, syllables: string[], score: number,
    source: CandidateSource, meta?: CandidateMeta): Candidate {
    const candidate: Candidate = {
      id: `${consumed}_${text}`,
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

  /**
   * 候选栏显示的拼音切分：沿用最近一次查询选出的最好整句，动作与候选完全同源。
   * 按切分把用户实际按下的字母逐段回写给原串：用户显式键入的分隔符原样保留（包括末尾那个），
   * 切分在原文没有分隔符的位置断开时补一个，例如 xian 首选“西安”时显示 xi'an。
   */
  formatCode(code: string, options: QueryOptions = DEFAULT_QUERY_OPTIONS): string {
    let path: SentencePath | undefined = undefined;
    if (this.cachedValid && code === this.cachedCode && options === this.cachedOptions) {
      path = this.cachedPath;
    } else {
      path = this.bestPath(buildLattice(code, options), '');
    }
    if (path === undefined) {
      return code;
    }
    let text = '';
    let position = 0;
    let first = true;
    const skipSeparators = (): boolean => {
      let skipped = false;
      while (position < code.length && code.charAt(position) === SEPARATOR) {
        text += SEPARATOR;
        position++;
        skipped = true;
      }
      return skipped;
    };
    for (const arc of path.arcs) {
      for (const typed of arc.typed) {
        if (first) {
          skipSeparators();
          first = false;
        } else if (!skipSeparators()) {
          // 切分在这里断开、原文没有分隔符时补一个
          text += SEPARATOR;
        }
        for (let i = 0; i < typed.length; i++) {
          skipSeparators();
          text += typed.charAt(i);
          if (position < code.length && code.charAt(position) === typed.charAt(i)) {
            position++;
          }
        }
      }
    }
    // 末尾显式键入的分隔符不是切分产生的，仍然留在预编辑里
    skipSeparators();
    return text.length > 0 ? text : code;
  }

  // ---------- 开发文档 15.4 节引擎契约 ----------

  async beginSession(sessionId: number): Promise<void> {
    this.sessionId = sessionId;
    this.lastSnapshot = undefined;
  }

  async updateCode(code: string, revision: number): Promise<EngineSnapshot> {
    const candidates = this.query(code, '', 60, DEFAULT_QUERY_OPTIONS);
    const snapshot: EngineSnapshot = {
      sessionId: this.sessionId,
      revision: revision,
      rawCode: code,
      candidates: candidates,
      hasMore: false
    };
    this.lastSnapshot = snapshot;
    return snapshot;
  }

  async proposeCommit(candidateId: string): Promise<CommitProposal> {
    const snapshot = this.lastSnapshot;
    if (snapshot === undefined) {
      throw new Error('no active snapshot');
    }
    for (const candidate of snapshot.candidates) {
      if (candidate.id === candidateId) {
        const proposal: CommitProposal = {
          sessionId: snapshot.sessionId,
          revision: snapshot.revision,
          candidateId: candidateId,
          text: candidate.text,
          remainingCode: snapshot.rawCode.substring(candidate.consumedCodeLength)
        };
        return proposal;
      }
    }
    throw new Error('candidate not found');
  }

  async acceptCommit(proposal: CommitProposal): Promise<EngineSnapshot> {
    return this.updateCode(proposal.remainingCode, proposal.revision + 1);
  }

  async reset(): Promise<void> {
    this.lastSnapshot = undefined;
    this.lastCandidates = [];
    this.cachedValid = false;
  }

  async dispose(): Promise<void> {
    this.lastSnapshot = undefined;
    this.lastCandidates = [];
    this.cachedValid = false;
  }
}
