import { canonicalSyllable, isInitial, isSyllable, isSyllablePrefix } from './PinyinSyllables';

/**
 * 模糊音变体：打出的拼音按模糊规则可以对应的另一个音节或音节前缀。
 */
export interface FuzzyVariant {
  text: string;
  cost: number;
}

// 每改动一处声母或韵母扣除的分数，对数域。同样常用的词里，打出的读音排在前面，
// 常用程度相差三倍以上的模糊读音才会排到前面
export const FUZZY_COST: number = 1.1;

export const NO_VARIANTS: FuzzyVariant[] = [];

// 平翘舌、n 与 l、f 与 h、r 与 l；l 同时对应 n 和 r
const INITIAL_PAIRS: string[][] = [['z', 'zh'], ['c', 'ch'], ['s', 'sh'], ['n', 'l'], ['f', 'h'], ['r', 'l']];
const INITIAL_PARTNERS: Map<string, string[]> = buildInitialPartners();

function buildInitialPartners(): Map<string, string[]> {
  const partners: Map<string, string[]> = new Map<string, string[]>();
  const link = (from: string, to: string): void => {
    const list = partners.get(from);
    if (list === undefined) {
      partners.set(from, [to]);
    } else {
      list.push(to);
    }
  };
  for (const pair of INITIAL_PAIRS) {
    link(pair[0], pair[1]);
    link(pair[1], pair[0]);
  }
  return partners;
}

const CONSONANTS: string = 'bpmfdtnlgkhjqxrzcsyw';

function splitInitial(text: string): string[] {
  if (text.startsWith('zh') || text.startsWith('ch') || text.startsWith('sh')) {
    return [text.substring(0, 2), text.substring(2)];
  }
  if (text.length > 0 && CONSONANTS.indexOf(text.charAt(0)) >= 0) {
    return [text.substring(0, 1), text.substring(1)];
  }
  return ['', text];
}

// 前后鼻音：an 与 ang、en 与 eng、in 与 ing，ian 与 iang、uan 与 uang 随之成立
function finalPartners(final: string): string[] {
  if (final.endsWith('ang') || final.endsWith('eng') || final.endsWith('ing')) {
    return [final.substring(0, final.length - 1)];
  }
  if (final.endsWith('an') || final.endsWith('en') || final.endsWith('in')) {
    return [final + 'g'];
  }
  return [];
}

function initialPartners(initial: string): string[] {
  return INITIAL_PARTNERS.get(initial) ?? [];
}

// 输入串的每个子串都会查询一次，缓存结果；超过上限时整体清空，内存占用保持在很小的范围
const CACHE_LIMIT: number = 4096;
const fullCache: Map<string, FuzzyVariant[]> = new Map<string, FuzzyVariant[]>();
const prefixCache: Map<string, FuzzyVariant[]> = new Map<string, FuzzyVariant[]>();

function remember(cache: Map<string, FuzzyVariant[]>, key: string, variants: FuzzyVariant[]): void {
  if (cache.size >= CACHE_LIMIT) {
    cache.clear();
  }
  cache.set(key, variants);
}

function addVariant(list: FuzzyVariant[], text: string, cost: number): void {
  for (const item of list) {
    if (item.text === text) {
      item.cost = Math.min(item.cost, cost);
      return;
    }
  }
  const variant: FuzzyVariant = { text: text, cost: cost };
  list.push(variant);
}

/**
 * 完整音节的模糊变体，声母与韵母可以同时替换。打出的串本身不是音节时也会计算，例如 len 对应 leng。
 */
export function syllableVariants(typed: string): FuzzyVariant[] {
  const cached = fullCache.get(typed);
  if (cached !== undefined) {
    return cached;
  }
  const self = canonicalSyllable(typed);
  const parts = splitInitial(typed);
  const initials = [parts[0]].concat(initialPartners(parts[0]));
  const finals = [parts[1]].concat(finalPartners(parts[1]));
  const result: FuzzyVariant[] = [];
  for (let i = 0; i < initials.length; i++) {
    for (let f = 0; f < finals.length; f++) {
      if (i === 0 && f === 0) {
        continue;
      }
      const text = canonicalSyllable(initials[i] + finals[f]);
      if (text !== self && isSyllable(text)) {
        addVariant(result, text, FUZZY_COST * ((i > 0 ? 1 : 0) + (f > 0 ? 1 : 0)));
      }
    }
  }
  const variants = result.length > 0 ? result : NO_VARIANTS;
  remember(fullCache, typed, variants);
  return variants;
}

/**
 * 不完整音节与简拼的模糊变体，只替换声母，例如 zh 对应 z，n 对应 l。
 */
export function prefixVariants(typed: string): FuzzyVariant[] {
  const cached = prefixCache.get(typed);
  if (cached !== undefined) {
    return cached;
  }
  const parts = splitInitial(typed);
  const result: FuzzyVariant[] = [];
  for (const initial of initialPartners(parts[0])) {
    const text = initial + parts[1];
    if (isSyllablePrefix(text) || isSyllable(text) || isInitial(text)) {
      addVariant(result, text, FUZZY_COST);
    }
  }
  const variants = result.length > 0 ? result : NO_VARIANTS;
  remember(prefixCache, typed, variants);
  return variants;
}
