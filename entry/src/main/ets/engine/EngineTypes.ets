export enum CandidateSource {
  SENTENCE = 'sentence',
  WORD = 'word',
  CHAR = 'char',
  USER = 'user',
  RAW = 'raw'
}

// 候选读音的可靠度，由引擎在生成候选时给出，供候选排序区分真实词、自然音节前缀、简拼补全与纠错。
// 排序模块不靠文字长度猜音节切分，音节边界与读音可靠度都取引擎给出的值。
// 候选的来源，供排序与学习区分词库本来列出的候选和学到的组合续接。
// 组合续接只按完整输入串补一条外层候选，不进入音节词格与简拼，见 UserLexicon.suggestContinuations
export enum CandidateOrigin {
  // 词库按读音列出的候选，旧候选没有这一项时按这个处理
  LEXICON = 'lexicon',
  // 用户先确认一个词、紧接着又确认一个词以后学到的组合，例如 shuru 的「输入」之后提示「输入法」
  CONTINUATION = 'continuation',
  // 用户之前打过的词，按首字母自动召回的简拼提示（输入串本身也是合法全拼音节时，不抢全拼首位，紧随其后展示）
  USER_ABBR = 'user_abbr'
}

export enum CandidateReading {
  // 全部音节都由完整音节拼出，没有纠错、模糊音或简拼
  FULL = 'full',
  // 完整音节，但用到了模糊音等价读法
  FUZZY = 'fuzzy',
  // 简拼或没打完的音节，读出的字母少于词条读音
  ABBREVIATION = 'abbreviation',
  // 用到了相邻按键或打反、多打的纠错
  CORRECTED = 'corrected'
}

export interface CandidateMeta {
  reading: CandidateReading;
  // 这条候选消耗了整串输入
  complete: boolean;
  // 消耗停在原文可以安全断开的音节边界
  safeEnd: boolean;
  // 这个候选按原文完整音节最多能读到的位置，没有原文读法时为 0
  exactConsumed: number;
  // 候选来源。词库候选与旧版本候选没有这一项，按 LEXICON 处理
  origin?: CandidateOrigin;
}

export interface Candidate {
  id: string;
  text: string;
  // 消耗的原始输入串字符数
  consumedCodeLength: number;
  // 消耗的音节序列，原文候选为空数组
  syllables: string[];
  score: number;
  source: CandidateSource;
  // 引擎给出的读音边界与可靠度；原文候选与旧版候选项没有这一项
  meta?: CandidateMeta;
}

export interface EngineSnapshot {
  sessionId: number;
  revision: number;
  rawCode: string;
  candidates: Candidate[];
  hasMore: boolean;
}

export interface CommitProposal {
  sessionId: number;
  revision: number;
  candidateId: string;
  text: string;
  remainingCode: string;
}

/**
 * 开发文档 15.4 节约定的引擎适配契约。
 */
export interface EngineAdapter {
  beginSession(sessionId: number): Promise<void>;
  updateCode(code: string, revision: number): Promise<EngineSnapshot>;
  proposeCommit(candidateId: string): Promise<CommitProposal>;
  acceptCommit(proposal: CommitProposal): Promise<EngineSnapshot>;
  reset(): Promise<void>;
  dispose(): Promise<void>;
}

/**
 * 按下某个字母键时，手指落点附近的其他字母及其代价。落点越靠近那个字母，代价越小，代价为对数域。
 */
export interface LetterAlternative {
  letter: string;
  cost: number;
}

/**
 * 查询选项。alternatives 与输入串逐字对应，分隔符与没有记录落点的字母为空数组。
 */
export interface QueryOptions {
  fuzzy: boolean;
  alternatives: LetterAlternative[][];
}

export const DEFAULT_QUERY_OPTIONS: QueryOptions = { fuzzy: false, alternatives: [] };

/**
 * 组词状态机使用的同步候选查询接口，本地引擎在按键路径上同步返回结果。
 */
export interface CandidateProvider {
  isReady(): boolean;
  query(code: string, previousText: string, limit: number, options: QueryOptions): Candidate[];
  // 按最优切分为输入串加入音节分隔，用于候选栏显示
  formatCode(code: string, options: QueryOptions): string;
}

export function rawCandidate(code: string): Candidate {
  const candidate: Candidate = {
    id: `raw_${code}`,
    text: code,
    consumedCodeLength: code.length,
    syllables: [],
    score: -1e9,
    source: CandidateSource.RAW
  };
  return candidate;
}

export class RawCandidateProvider implements CandidateProvider {
  isReady(): boolean {
    return true;
  }

  query(code: string, previousText: string, limit: number, options: QueryOptions): Candidate[] {
    return code.length > 0 && limit > 0 ? [rawCandidate(code)] : [];
  }

  formatCode(code: string, options: QueryOptions): string {
    return code;
  }
}
