import {
  Candidate,
  CandidateProvider,
  CandidateSource,
  CommitProposal,
  DEFAULT_QUERY_OPTIONS,
  EngineAdapter,
  EngineSnapshot,
  QueryOptions,
  rawCandidate
} from './EngineTypes';
import { keyLetter, Lexicon, LexiconEntry } from './Lexicon';
import { buildLattice, EdgeKind, SegmentLattice, SEPARATOR, SyllableEdge, syllableCost } from './PinyinSegmenter';

// 每条词边的查询上限，桶内已按概率排序
const MATCHES_PER_PATH: number = 150;
const MAX_PATHS_PER_START: number = 400;
// 多音节词相对单字的加分，让“西安”这类完整词排在低频单字之前
export const WORD_BONUS_PER_SYLLABLE: number = 1.0;
// 整句之外，候选列表最多补充几个纠错得到的词
const MAX_CORRECTED_WORDS: number = 2;
// 整句搜索时，每段拼音保留几个最可能的词，词间搭配据此在同音词之间挑选，例如 zai 的在与再。
// engine-bench 上取 3 到 4 个、保留 5 到 8 种状态时准确率相同，这里取较省时的一端
const WORDS_PER_SPAN: number = 3;
// 每个位置最多保留几种“上一个词”继续往后搜索
const BEAM_WIDTH: number = 6;
const EMPTY_ENTRIES: LexiconEntry[] = [];
// 次好整句与最好整句的得分差在这个范围之内时，作为第二个整句候选列出
const SECOND_SENTENCE_MARGIN: number = 2.5;

/**
 * 词间搭配：前一个词后面接这个词时的加分，没有记录时为 0。
 */
export interface TransitionModel {
  bonus(previous: string, next: string): number;
}

/**
 * 用户模型：提供学习得到的词条，并为词条计算个性化加分。
 */
export interface UserModel {
  lookup(initialsKey: string): LexiconEntry[];
  hasKeyPrefix(prefix: string): boolean;
  boost(entry: LexiconEntry, previousText: string): number;
  isUserEntry(entry: LexiconEntry): boolean;
  maxSyllables(): number;
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
      signature += `${edge.end},${edge.kind},${edge.text},${edge.typed},${edge.penalty},${edge.corrected ? 1 : 0},` +
        `${edge.variants.length};`;
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
  // 至少一个音节由相邻按键替换得到
  corrected: boolean;
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
}

interface ScoredEntry {
  entry: LexiconEntry;
  cost: number;
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
 * 词条与一串音节边逐个比对，全部满足时返回模糊音代价之和，否则返回 -1。
 */
function entryCost(entry: LexiconEntry, edges: SyllableEdge[]): number {
  if (entry.syllables.length !== edges.length) {
    return -1;
  }
  let cost = 0;
  for (let i = 0; i < edges.length; i++) {
    const syllableCostValue = syllableCost(entry.syllables[i], edges[i]);
    if (syllableCostValue < 0) {
      return -1;
    }
    cost += syllableCostValue;
  }
  return cost;
}

/**
 * 同一终点保留得分最高的几个词，同一个词只留得分最高的一条。
 */
function keepTop(map: Map<number, WordArc[]>, arc: WordArc): void {
  let list = map.get(arc.end);
  if (list === undefined) {
    map.set(arc.end, [arc]);
    return;
  }
  for (let i = 0; i < list.length; i++) {
    if (list[i].entry.word === arc.entry.word) {
      if (arc.score > list[i].score) {
        list[i] = arc;
        list.sort((a: WordArc, b: WordArc) => b.score - a.score);
      }
      return;
    }
  }
  if (list.length < WORDS_PER_SPAN) {
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

// 同一个“上一个词”只保留得分最高的状态
function offerState(map: Map<string, SearchState>, state: SearchState): void {
  const key = state.arc !== undefined ? state.arc.entry.word : '';
  const existing = map.get(key);
  if (existing === undefined || state.score > existing.score) {
    map.set(key, state);
  }
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

function topStates(map: Map<string, SearchState>): SearchState[] {
  const list: SearchState[] = [];
  map.forEach((state: SearchState) => list.push(state));
  list.sort((a: SearchState, b: SearchState) => b.score - a.score);
  return list.length > BEAM_WIDTH ? list.slice(0, BEAM_WIDTH) : list;
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
  private sessionId: number = 0;
  private lastSnapshot: EngineSnapshot | undefined = undefined;
  private lastCandidates: Candidate[] = [];
  // 候选栏显示拼音切分时复用最近一次查询的整句，同一输入串不再重复计算
  private cachedValid: boolean = false;
  private cachedCode: string = '';
  private cachedOptions: QueryOptions | undefined = undefined;
  private cachedPath: SentencePath | undefined = undefined;

  constructor(lexicon: Lexicon) {
    this.lexicon = lexicon;
  }

  setUserModel(model: UserModel | undefined): void {
    this.userModel = model;
    this.cachedValid = false;
  }

  setBigramModel(model: TransitionModel | undefined): void {
    this.transitions = model;
    this.cachedValid = false;
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
        penalty: (previous !== undefined ? previous.penalty : 0) + edge.penalty,
        corrected: (previous !== undefined && previous.corrected) || edge.corrected,
        exact: (previous === undefined || previous.exact) && edge.kind === EdgeKind.FULL
      };
      stack.push(path);
    };
    // 栈顶先出，纠错边先入栈，原文的组合先展开
    const pushAll = (previous: PathState | undefined, edges: SyllableEdge[]): void => {
      for (const edge of edges) {
        if (edge.corrected && (previous === undefined || !previous.corrected)) {
          pushPath(previous, edge);
        }
      }
      for (const edge of edges) {
        if (!edge.corrected && edge.kind !== EdgeKind.SEPARATOR) {
          pushPath(previous, edge);
        }
      }
    };
    pushAll(undefined, edgesAtStart);
    let visited = 0;
    while (stack.length > 0 && visited < MAX_PATHS_PER_START) {
      const path = stack.pop() as PathState;
      visited++;
      this.matchPath(path, start, previousText, allMatches, arcs);
      if (path.depth < maxDepth) {
        pushAll(path, this.syllableEdgesAt(lattice, path.end));
      }
    }
    return arcs;
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

  private matchPath(path: PathState, start: number, previousText: string, allMatches: boolean,
    out: WordArc[]): void {
    const model = this.userModel;
    const userBucket = model !== undefined ? model.lookup(path.key) : EMPTY_ENTRIES;
    const bucket = path.depth <= this.lexicon.maxSyllables() ? this.lexicon.lookup(path.key) : EMPTY_ENTRIES;
    if (userBucket.length === 0 && bucket.length === 0) {
      return;
    }
    const edges = edgesOf(path);
    for (const entry of userBucket) {
      const cost = entryCost(entry, edges);
      if (cost >= 0) {
        out.push(this.makeArc(start, path, edges, entry, cost, previousText));
      }
    }
    if (!allMatches) {
      // 桶内按概率从高到低排列，代价不为负；概率已不高于第 WORDS_PER_SPAN 名的得分时，后面的词条不会更好
      const top: ScoredEntry[] = [];
      for (const entry of bucket) {
        if (top.length >= WORDS_PER_SPAN && entry.logProb <= top[top.length - 1].score) {
          break;
        }
        const cost = entryCost(entry, edges);
        if (cost < 0) {
          continue;
        }
        const scored: ScoredEntry = { entry: entry, cost: cost, score: entry.logProb - cost };
        if (top.length < WORDS_PER_SPAN) {
          top.push(scored);
        } else if (scored.score > top[top.length - 1].score) {
          top[top.length - 1] = scored;
        } else {
          continue;
        }
        top.sort((a: ScoredEntry, b: ScoredEntry) => b.score - a.score);
      }
      for (const item of top) {
        out.push(this.makeArc(start, path, edges, item.entry, item.cost, previousText));
      }
      return;
    }
    let found = 0;
    for (const entry of bucket) {
      const cost = entryCost(entry, edges);
      if (cost >= 0) {
        out.push(this.makeArc(start, path, edges, entry, cost, previousText));
        found++;
        if (found >= MATCHES_PER_PATH) {
          break;
        }
      }
    }
  }

  private makeArc(start: number, path: PathState, edges: SyllableEdge[], entry: LexiconEntry, cost: number,
    previousText: string): WordArc {
    const boost = this.userModel !== undefined ? this.userModel.boost(entry, previousText) : 0;
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
      corrected: path.corrected
    };
    return arc;
  }

  // ---------- 整句 ----------

  private startArcs(lattice: SegmentLattice, position: number, context: string): StartArcs {
    const all: Map<number, WordArc[]> = new Map<number, WordArc[]>();
    const exact: Map<number, WordArc[]> = new Map<number, WordArc[]>();
    for (const arc of this.collectArcs(lattice, position, context, false)) {
      keepTop(all, arc);
      if (!arc.corrected) {
        keepTop(exact, arc);
      }
    }
    const result: StartArcs = { all: flatten(all), exact: flatten(exact) };
    return result;
  }

  private transition(state: SearchState, arc: WordArc): number {
    const model = this.transitions;
    if (model === undefined || state.arc === undefined) {
      return 0;
    }
    return model.bonus(state.arc.entry.word, arc.entry.word);
  }

  // 各起点的词弧只计算一次，含纠错与不含纠错的两次整句搜索共用
  /**
   * 连续打字时，每加一个字母，只有靠近末尾的几个位置会多出或少掉音节边。
   * 某个起点上次搜索读过的位置，如果这次的边特征串都没变，词弧原样沿用，不再重新搜索。
   * 上文或学习记录变了，缓存整体作废。
   */
  private startArcsProvider(lattice: SegmentLattice, previousText: string): StartArcsProvider {
    const signatures = edgeSignatures(lattice);
    const cacheKey = `${previousText}\t${this.userModel !== undefined ? this.userModel.revision() : -1}`;
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
   * 整句搜索。每个位置按“上一个词”分别记录最好得分，接下一个词时加上两个词的搭配分，
   * 每个位置只保留得分最高的 BEAM_WIDTH 种状态。没有搭配模型时，结果与只记最好得分的动态规划相同。
   */
  private viterbi(lattice: SegmentLattice, arcsAt: StartArcsProvider, allowCorrection: boolean):
    SentencePath | undefined {
    const finals = this.search(lattice, arcsAt, allowCorrection);
    return finals.length > 0 ? pathOf(finals[0]) : undefined;
  }

  // 返回走到串尾的各个状态，按得分从高到低排列，每个状态的最后一个词互不相同
  private search(lattice: SegmentLattice, arcsAt: StartArcsProvider, allowCorrection: boolean): SearchState[] {
    const length = lattice.code.length;
    if (length === 0 || !lattice.covered) {
      return [];
    }
    const states: Map<string, SearchState>[] = [];
    for (let i = 0; i <= length; i++) {
      states.push(new Map<string, SearchState>());
    }
    const origin: SearchState = { score: 0, arc: undefined, previous: undefined };
    offerState(states[0], origin);
    for (let position = 0; position < length; position++) {
      const current = topStates(states[position]);
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
          const next: SearchState = {
            score: state.score + arc.score + this.transition(state, arc),
            arc: arc,
            previous: state
          };
          offerState(states[arc.end], next);
        }
      }
    }
    return topStates(states[length]);
  }

  bestPath(lattice: SegmentLattice, previousText: string): SentencePath | undefined {
    return this.viterbi(lattice, this.startArcsProvider(lattice, previousText), true);
  }

  // ---------- 候选 ----------

  /**
   * 候选顺序：最好的整句在前；最好整句用到了纠错时，原文的最好整句紧随其后。
   * 得分相差不到 SECOND_SENTENCE_MARGIN 的次好整句也列出来，它的最后一个词与最好整句不同。
   * 然后是从首字开始的词，消耗拼音多的在前。纠错得到的词只在比同样长度的原文词更可能时列出，
   * 并且数量有限，正常打字时候选列表不会混入邻键的字。
   */
  query(code: string, previousText: string, limit: number,
    options: QueryOptions = DEFAULT_QUERY_OPTIONS): Candidate[] {
    const candidates: Candidate[] = [];
    if (code.length === 0 || limit <= 0) {
      return candidates;
    }
    const lattice = buildLattice(code, options);
    const arcsAt = this.startArcsProvider(lattice, previousText);
    const finals = this.search(lattice, arcsAt, true);
    const best = finals.length > 0 ? pathOf(finals[0]) : undefined;
    this.cachedValid = true;
    this.cachedCode = code;
    this.cachedOptions = options;
    this.cachedPath = best;
    const seen: Set<string> = new Set<string>();
    const sentences: SentencePath[] = [];
    if (best !== undefined) {
      sentences.push(best);
      if (best.corrected) {
        const exactBest = this.viterbi(lattice, arcsAt, false);
        if (exactBest !== undefined) {
          sentences.push(exactBest);
        }
      }
      // 只打了一个词时，后面的词语候选已经覆盖同音词，次好整句不再占位
      if (best.arcs.length >= 3 && finals.length > 1 &&
        finals[1].score >= finals[0].score - SECOND_SENTENCE_MARGIN) {
        sentences.push(pathOf(finals[1]));
      }
    }
    for (const sentence of sentences) {
      const candidate = this.sentenceCandidate(sentence, code);
      if (candidate !== undefined && !seen.has(candidate.text)) {
        seen.add(candidate.text);
        candidates.push(candidate);
      }
    }
    let firstStart = 0;
    while (firstStart < code.length && code.charAt(firstStart) === SEPARATOR) {
      firstStart++;
    }
    const arcs = this.collectArcs(lattice, firstStart, previousText, true);
    const bestExactByEnd: Map<number, number> = new Map<number, number>();
    for (const arc of arcs) {
      const known = bestExactByEnd.get(arc.end);
      if (!arc.corrected && (known === undefined || arc.score > known)) {
        bestExactByEnd.set(arc.end, arc.score);
      }
    }
    arcs.sort((a: WordArc, b: WordArc) => {
      if (a.end !== b.end) {
        return b.end - a.end;
      }
      return b.score - a.score;
    });
    let correctedCount = 0;
    for (const arc of arcs) {
      if (candidates.length >= limit - 1) {
        break;
      }
      if (seen.has(arc.entry.word)) {
        continue;
      }
      if (arc.corrected) {
        const exactScore = bestExactByEnd.get(arc.end);
        if (correctedCount >= MAX_CORRECTED_WORDS || (exactScore !== undefined && arc.score <= exactScore)) {
          continue;
        }
        correctedCount++;
      }
      seen.add(arc.entry.word);
      candidates.push(this.arcCandidate(arc, code));
    }
    const raw = code.split(SEPARATOR).join('');
    if (raw.length > 0 && !seen.has(raw)) {
      candidates.push(rawCandidate(code));
    }
    this.lastCandidates = candidates;
    return candidates;
  }

  // 一条词弧消耗到的拼音位置，紧随其后的分隔符一并消耗
  private consumedAfter(arc: WordArc, code: string): number {
    let consumed = arc.end;
    while (consumed < code.length && code.charAt(consumed) === SEPARATOR) {
      consumed++;
    }
    return consumed;
  }

  private arcCandidate(arc: WordArc, code: string): Candidate {
    const source = this.userModel !== undefined && this.userModel.isUserEntry(arc.entry) ? CandidateSource.USER :
      (arc.entry.syllables.length === 1 ? CandidateSource.CHAR : CandidateSource.WORD);
    return this.makeCandidate(arc.entry.word, this.consumedAfter(arc, code), arc.entry.syllables, arc.score, source);
  }

  // 整句只有一个词时按普通词候选处理
  private sentenceCandidate(sentence: SentencePath, code: string): Candidate | undefined {
    if (sentence.arcs.length === 0) {
      return undefined;
    }
    if (sentence.arcs.length === 1) {
      return this.arcCandidate(sentence.arcs[0], code);
    }
    let text = '';
    let syllables: string[] = [];
    for (const arc of sentence.arcs) {
      text += arc.entry.word;
      syllables = syllables.concat(arc.entry.syllables);
    }
    return this.makeCandidate(text, code.length, syllables, sentence.score, CandidateSource.SENTENCE);
  }

  private makeCandidate(text: string, consumed: number, syllables: string[], score: number,
    source: CandidateSource): Candidate {
    const candidate: Candidate = {
      id: `${consumed}_${text}`,
      text: text,
      consumedCodeLength: consumed,
      syllables: syllables,
      score: score,
      source: source
    };
    return candidate;
  }

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
    const pieces: string[] = [];
    for (const arc of path.arcs) {
      for (const typed of arc.typed) {
        pieces.push(typed);
      }
    }
    return pieces.join(SEPARATOR);
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
