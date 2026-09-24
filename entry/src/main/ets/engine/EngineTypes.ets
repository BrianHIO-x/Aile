export enum CandidateSource {
  SENTENCE = 'sentence',
  WORD = 'word',
  CHAR = 'char',
  USER = 'user',
  RAW = 'raw'
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
