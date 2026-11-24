import { Candidate, CandidateReading, CandidateSource } from './EngineTypes';
import { prefixVariants, syllableVariants } from './FuzzyPinyin';
import { SEPARATOR } from './PinyinSegmenter';
import {
  canonicalSyllable,
  isInitial,
  isStandaloneSyllable,
  isSyllable,
  isSyllablePrefix,
  MAX_SYLLABLE_LENGTH,
  STANDARD_SYLLABLES
} from './PinyinSyllables';

function hasVowel(text: string): boolean {
  for (let i = 0; i < text.length; i++) {
    const c = text.charAt(i);
    if (c === 'a' || c === 'e' || c === 'i' || c === 'o' || c === 'u' || c === 'v') {
      return true;
    }
  }
  return false;
}

// 当前候选里是否已经存在读完整串、带元音的完整/模糊读法；有的话只采信完整/模糊读法，不被切进缩写噪音干扰
function hasVowelFullMatch(candidates: Candidate[]): boolean {
  for (const candidate of candidates) {
    if (candidate.source === CandidateSource.RAW || candidate.syllables.length === 0) {
      continue;
    }
    const meta = candidate.meta;
    if (meta !== undefined && meta.complete &&
      (meta.reading === CandidateReading.FULL || meta.reading === CandidateReading.FUZZY) &&
      hasVowel(candidate.syllables[0])) {
      return true;
    }
  }
  return false;
}

function skipSeparators(text: string, from: number): number {
  let pos = from;
  while (pos < text.length && text.charAt(pos) === SEPARATOR) {
    pos++;
  }
  return pos;
}

// 切掉首音节之后剩下的部分能否接上合法音节（或作为最后一段未打完的音节前缀），例如 fangan 切出 fa 后剩 ngan 则不合法
function tailStartsValidSyllable(tail: string, fuzzy: boolean): boolean {
  if (tail.length === 0) {
    return true;
  }
  if (tail.length === 1) {
    return isSyllable(tail) || isSyllablePrefix(tail);
  }
  const sepPos = tail.indexOf(SEPARATOR);
  const head = sepPos >= 0 ? tail.substring(0, sepPos) : tail;
  if (head.length === 0) {
    return false;
  }
  const maxLen = Math.min(head.length, MAX_SYLLABLE_LENGTH);
  for (let k = 1; k <= maxLen; k++) {
    const sub = head.substring(0, k);
    if (isSyllable(canonicalSyllable(sub)) || (fuzzy && syllableVariants(sub).length > 0)) {
      return true;
    }
  }
  if (sepPos < 0 && isSyllablePrefix(tail)) {
    return true;
  }
  if (fuzzy && sepPos < 0) {
    for (const variant of prefixVariants(head)) {
      if (isSyllablePrefix(variant.text) || isSyllable(variant.text)) {
        return true;
      }
    }
  }
  return false;
}

/**
 * 为自由选词左侧栏生成可选的首音节列表：
 * 1) 先按当前候选（allOrder）的热度/相关度顺序提取真实首音节；
 * 2) 补充输入串开头的全部合法全拼切分（含模糊音变体）；
 * 3) 对单字母或未打完音节的前缀，从标准音节表按字母序补全其余匹配音节（不含纯多字母简拼如 srf）。
 */
export function extractPinyinOptions(rawCode: string, candidates: Candidate[], allOrder: number[],
  fuzzy: boolean): string[] {
  const result: string[] = [];
  if (rawCode.length === 0) {
    return result;
  }
  const seen: Set<string> = new Set<string>();
  const add = (syllable: string): void => {
    if (syllable.length > 0 && !seen.has(syllable)) {
      seen.add(syllable);
      result.push(syllable);
    }
  };

  // 1) 从候选池按 allOrder 顺序提取首音节
  const fullOnly = hasVowelFullMatch(candidates);
  const useOrder = allOrder.length > 0;
  const total = useOrder ? allOrder.length : candidates.length;
  for (let i = 0; i < total; i++) {
    const index = useOrder ? allOrder[i] : i;
    if (index < 0 || index >= candidates.length) {
      continue;
    }
    const candidate = candidates[index];
    if (candidate.source === CandidateSource.RAW || candidate.syllables.length === 0) {
      continue;
    }
    const meta = candidate.meta;
    if (meta !== undefined && !meta.safeEnd) {
      continue;
    }
    if (fullOnly && meta !== undefined &&
      meta.reading !== CandidateReading.FULL && meta.reading !== CandidateReading.FUZZY) {
      continue;
    }
    add(candidate.syllables[0]);
  }

  // 2) 输入串开头的合法首音节切分
  const lead = skipSeparators(rawCode, 0);
  const rest = rawCode.substring(lead);
  if (rest.length === 0) {
    return result;
  }
  const sepPos = rest.indexOf(SEPARATOR);
  const head = sepPos >= 0 ? rest.substring(0, sepPos) : rest;
  if (head.length === 0) {
    return result;
  }
  const maxCut = Math.min(head.length, MAX_SYLLABLE_LENGTH);
  for (let len = maxCut; len >= 1; len--) {
    const sub = head.substring(0, len);
    const canon = canonicalSyllable(sub);
    const standalone = lead === 0 && len === rawCode.length && isStandaloneSyllable(sub);
    if (!isSyllable(canon) && !standalone) {
      continue;
    }
    const tailStart = skipSeparators(rest, len);
    const tail = rest.substring(tailStart);
    const valid = tail.length === 0 || len === head.length || tailStartsValidSyllable(tail, fuzzy);
    if (!valid) {
      continue;
    }
    add(canon);
    if (fuzzy) {
      for (const variant of syllableVariants(sub)) {
        add(variant.text);
      }
    }
  }

  // 3) 无分词符的单音节前缀/声母补全（如 m、sh、xian → xiang）
  if (sepPos < 0 && head.length > 0 && head.length <= MAX_SYLLABLE_LENGTH &&
    (isSyllablePrefix(head) || isInitial(head))) {
    const addByPrefix = (prefix: string): void => {
      for (const syl of STANDARD_SYLLABLES) {
        if (syl.startsWith(prefix)) {
          add(syl);
        }
      }
      if (prefix === 'lv') {
        add('lue');
      } else if (prefix === 'nv') {
        add('nue');
      }
    };
    addByPrefix(head);
    if (fuzzy) {
      for (const variant of prefixVariants(head)) {
        addByPrefix(variant.text);
      }
      for (const variant of syllableVariants(head)) {
        add(variant.text);
      }
    }
  }

  return result;
}

function matchesPrefixWithFuzzy(syllable: string, prefix: string, fuzzy: boolean): boolean {
  if (syllable.startsWith(prefix)) {
    return true;
  }
  if (!fuzzy) {
    return false;
  }
  for (const variant of prefixVariants(prefix)) {
    if (syllable.startsWith(variant.text)) {
      return true;
    }
  }
  return false;
}

/**
 * 计算按某个首音节补查单字时，从当前 rawCode 开头应消耗多少字符（不含尾随分隔符）。
 * 无法在开头匹配到该音节时返回 0。
 */
export function consumedForSyllable(rawCode: string, syllable: string, fuzzy: boolean): number {
  if (rawCode.length === 0 || syllable.length === 0) {
    return 0;
  }
  const lead = skipSeparators(rawCode, 0);
  const rest = rawCode.substring(lead);
  const sepPos = rest.indexOf(SEPARATOR);
  const head = sepPos >= 0 ? rest.substring(0, sepPos) : rest;
  if (head.length === 0) {
    return 0;
  }
  const maxLen = Math.min(head.length, MAX_SYLLABLE_LENGTH);
  // 规则 1：head 前缀正好就是该音节
  for (let len = maxLen; len >= 1; len--) {
    if (canonicalSyllable(head.substring(0, len)) === syllable) {
      return lead + len;
    }
  }
  // 规则 2：开启模糊音时，head 前缀模糊等价于该音节
  if (fuzzy) {
    for (let len = maxLen; len >= 1; len--) {
      const sub = head.substring(0, len);
      for (const variant of syllableVariants(sub)) {
        if (variant.text === syllable) {
          return lead + len;
        }
      }
    }
  }
  // 规则 3：head 整个是该音节的未打完前缀
  if (syllable.startsWith(head) || (head === 'lv' && syllable === 'lue') || (head === 'nv' && syllable === 'nue')) {
    return lead + head.length;
  }
  // 规则 4：开启模糊音时，head 模糊后是该音节的前缀
  if (fuzzy) {
    for (const variant of prefixVariants(head)) {
      if (syllable.startsWith(variant.text)) {
        return lead + head.length;
      }
    }
  }
  // 规则 5：简拼首声母（先双字母 zh/ch/sh，再单字母）
  if (head.length >= 2) {
    const two = head.substring(0, 2);
    if (isInitial(two) && matchesPrefixWithFuzzy(syllable, two, fuzzy)) {
      return lead + 2;
    }
  }
  const one = head.charAt(0);
  if (matchesPrefixWithFuzzy(syllable, one, fuzzy)) {
    return lead + 1;
  }
  return 0;
}
