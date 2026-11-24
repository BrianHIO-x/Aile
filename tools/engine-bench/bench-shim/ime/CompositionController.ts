// engine-bench 用的类型占位：把 ime 层的组词契约照抄一份，让引擎源码可以在 Node 下编译。
// run.ps1 会把它复制成 build/ime/CompositionController.ts，与 UserLexicon 里的 '../ime/CompositionController' 对上。
// 只声明 UserLexicon 用到的成员，形状与 entry/src/main/ets/ime/CompositionController.ets 保持一致。
import { Candidate, CandidateOrigin, CandidateSource, LetterAlternative } from '../src/EngineTypes';

export interface TapSample {
  keyId: string;
  dx: number;
  dy: number;
}

export interface CommitSegment {
  text: string;
  code: string;
  syllables: string[];
  source: CandidateSource;
  alternatives: LetterAlternative[][];
  taps: TapSample[];
  // 这一段的来源，学到的组合续接为 CONTINUATION；与真实 CompositionController 的形状保持一致
  origin?: CandidateOrigin;
}

export interface CommitResult {
  text: string;
  segments: CommitSegment[];
  raw: boolean;
}

export interface CommitLearner {
  learn(result: CommitResult, previousText: string): void;
  flush(): void;
  clear(): void;
}

export interface CandidateRules {
  arrange(code: string, candidates: Candidate[]): Candidate[];
  isPinned(code: string, word: string): boolean;
  pin(code: string, syllables: string[], word: string): void;
  unpin(code: string): void;
  remove(syllables: string[], word: string): void;
  restoreRemoved(): boolean;
}
