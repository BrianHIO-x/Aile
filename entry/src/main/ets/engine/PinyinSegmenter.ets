import {
  canonicalSyllable,
  isAbbreviationLetter,
  isInitial,
  isStandaloneSyllable,
  isSyllable,
  isSyllablePrefix,
  MAX_SYLLABLE_LENGTH
} from './PinyinSyllables';
import { DEFAULT_QUERY_OPTIONS, LetterAlternative, QueryOptions } from './EngineTypes';
import { FuzzyVariant, NO_VARIANTS, prefixVariants, syllableVariants } from './FuzzyPinyin';

export enum EdgeKind {
  FULL = 'full',
  PARTIAL = 'partial',
  ABBR = 'abbr',
  SEPARATOR = 'separator'
}

// 分数均为对数域，惩罚值直接从词条对数概率中扣除
export const PENALTY_PARTIAL_END: number = 1.5;
export const PENALTY_PARTIAL_OF_FULL: number = 4.0;
export const PENALTY_ABBREVIATION: number = 2.2;
// 整串能用完整音节切开时，切进某个完整音节内部的简拼边额外扣的分。
// 例如 hengping 能切成 heng'ping，hen'g'ping 里的 g 就属于这种简拼边
export const PENALTY_ABBREVIATION_SPLIT: number = 3.0;
// 整串恰好能用完整音节切开时，末尾没打完的音节如果切进了某个完整音节内部，额外扣的分。
// 例如 gun 可以读成 gu 加上没打完的 n（姑娘），用户多半要的是“滚”；再打一个字母成为 guni 时，这一档就不再适用
export const PENALTY_PARTIAL_SPLIT: number = 4.5;
// 打错纠正：相邻两个字母互换、多打一个字母。每个音节最多纠正一处。
// 触屏上按到邻键远比这两类打错常见，代价定在手指按在邻键正中时的误触代价（约 3.6 + 2.0）附近
export const EDIT_SWAP_COST: number = 5.5;
export const EDIT_EXTRA_COST: number = 5.5;
// 打出的音节本身读得通时，相邻字母打反的纠正额外多扣的分数
export const READABLE_SWAP_EXTRA_COST: number = 1.0;
// 整串本身能完整切开时，所有打错纠正额外多扣的分数。二元模型会给没见过的组合扣分，
// 不加这一档时，“附近哦”里的 o 会被当成多打的字母吞掉，“这女的”会被纠成“真的”
export const COVERED_EDIT_EXTRA_COST: number = 1.5;
// 误触纠错：落点代价不超过这个值的相邻字母总是参与切分，手指按在两个键交界附近时才会达到。
// 拼音无法完整切分时，再放宽到按键记录的全部相邻字母
export const CORRECTION_COST_LIMIT: number = 3.2;
// 放宽档额外加的代价：手指按在按键正中时，原文读得通的写法优先，纠错只作为补充。
// 手指按在两键交界附近时走的是常规档，不加这部分代价
export const RESCUE_EXTRA_COST: number = 2.0;
export const SEPARATOR: string = '\'';

export interface SyllableEdge {
  start: number;
  end: number;
  // 完整音节为词库拼写，不完整音节与简拼为用户键入的原文。纠错边为替换相邻字母后的音节
  text: string;
  // 用户实际键入的字母，候选栏按它显示切分
  typed: string;
  kind: EdgeKind;
  penalty: number;
  // 开启模糊音时，这条边还可以对应的读音
  variants: FuzzyVariant[];
  // 由相邻按键替换一个字母得到
  corrected: boolean;
  // 跨音节打反的左半边，读音借用了下一个字母。后面只能紧跟这条右半边，两条落在同一个词里
  swapNext?: SyllableEdge;
  // 跨音节打反的右半边，只能跟在自己的左半边后面
  swapTail?: boolean;
  // 只由放宽档的邻键替换得到：手指按在自己的键中间，却被纠成了邻键。按在两键交界附近的常规档，
  // 以及打反、多打字母的纠正都不算
  tapOnly?: boolean;
}

export interface SegmentLattice {
  code: string;
  edges: SyllableEdge[][];
  covered: boolean;
  abbreviationsEnabled: boolean;
  // 整串能否只由带元音的完整音节与分隔符切开（不含纯辅音独立音节 m/n/ng/hm/hng），用于区分全拼与简拼
  strictVowelCovered: boolean;
  // 原文能用完整音节切开时（最后一段可以没打完），每个位置是否落在某种切分的音节边界上，纠错边不参与计算。
  // 切不开时为 undefined
  boundaries: boolean[] | undefined;
}

export function isPinyinCode(code: string): boolean {
  for (let i = 0; i < code.length; i++) {
    const c = code.charAt(i);
    if (!((c >= 'a' && c <= 'z') || c === SEPARATOR)) {
      return false;
    }
  }
  return true;
}

function makeEdge(start: number, end: number, text: string, typed: string, kind: EdgeKind,
  penalty: number, variants: FuzzyVariant[] = NO_VARIANTS, corrected: boolean = false): SyllableEdge {
  const edge: SyllableEdge = {
    start: start,
    end: end,
    text: text,
    typed: typed,
    kind: kind,
    penalty: penalty,
    variants: variants,
    corrected: corrected
  };
  return edge;
}

function reachesEnd(edges: SyllableEdge[][], length: number): boolean {
  const reachable: boolean[] = new Array<boolean>(length + 1).fill(false);
  reachable[0] = true;
  for (let i = 0; i < length; i++) {
    if (!reachable[i]) {
      continue;
    }
    for (const edge of edges[i]) {
      reachable[edge.end] = true;
    }
  }
  return reachable[length];
}

/**
 * 整串能否只用完整音节与分隔符切开，最后一段允许是没打完的音节，并且切分里至少有一个完整音节。
 * 能切开时返回每个位置是否落在某种切分的音节边界上，不能切开时返回 undefined。
 * 只打了声母的 sh、zh 这类输入没有完整音节，简拼照常参与，不受影响。
 */
/**
 * 整串只用完整音节与分隔符就能切开时，返回每个位置是否落在某种这样的切分的音节边界上，否则返回 undefined。
 */
function strictBoundaries(edges: SyllableEdge[][], length: number): boolean[] | undefined {
  const forward: boolean[] = new Array<boolean>(length + 1).fill(false);
  const backward: boolean[] = new Array<boolean>(length + 1).fill(false);
  forward[0] = true;
  for (let i = 0; i < length; i++) {
    if (!forward[i]) {
      continue;
    }
    for (const edge of edges[i]) {
      if (!edge.corrected && (edge.kind === EdgeKind.FULL || edge.kind === EdgeKind.SEPARATOR)) {
        forward[edge.end] = true;
      }
    }
  }
  if (!forward[length]) {
    return undefined;
  }
  backward[length] = true;
  for (let i = length - 1; i >= 0; i--) {
    for (const edge of edges[i]) {
      if (!edge.corrected && (edge.kind === EdgeKind.FULL || edge.kind === EdgeKind.SEPARATOR) && backward[edge.end]) {
        backward[i] = true;
        break;
      }
    }
  }
  const boundaries: boolean[] = new Array<boolean>(length + 1).fill(false);
  for (let i = 0; i <= length; i++) {
    boundaries[i] = forward[i] && backward[i];
  }
  return boundaries;
}

function fullSyllableBoundaries(edges: SyllableEdge[][], length: number): boolean[] | undefined {
  const forward: boolean[] = new Array<boolean>(length + 1).fill(false);
  const backward: boolean[] = new Array<boolean>(length + 1).fill(false);
  forward[0] = true;
  for (let i = 0; i < length; i++) {
    if (!forward[i]) {
      continue;
    }
    for (const edge of edges[i]) {
      if (edge.kind === EdgeKind.FULL || edge.kind === EdgeKind.SEPARATOR) {
        forward[edge.end] = true;
      }
    }
  }
  backward[length] = true;
  for (let i = length - 1; i >= 0; i--) {
    for (const edge of edges[i]) {
      const joins = edge.kind === EdgeKind.FULL || edge.kind === EdgeKind.SEPARATOR ? backward[edge.end] :
        edge.kind === EdgeKind.PARTIAL && edge.end === length;
      if (joins) {
        backward[i] = true;
        break;
      }
    }
  }
  if (!backward[0]) {
    return undefined;
  }
  let hasFull = false;
  const boundaries: boolean[] = new Array<boolean>(length + 1).fill(false);
  for (let i = 0; i < length; i++) {
    boundaries[i] = forward[i] && backward[i];
    if (!boundaries[i]) {
      continue;
    }
    for (const edge of edges[i]) {
      if (edge.kind === EdgeKind.FULL && backward[edge.end]) {
        hasFull = true;
      }
    }
  }
  boundaries[length] = true;
  return hasFull ? boundaries : undefined;
}

function hasVowel(text: string): boolean {
  for (let i = 0; i < text.length; i++) {
    if ('aeiouv'.indexOf(text.charAt(i)) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 打错纠正边，只纠正相邻两个字母互换与多打一个字母。打出的这段本身读得通时不做纠正；
 * 位于末尾时，纠正以后是某个音节的开头也可以，这时按没打完的音节处理。
 * 没打完的写法必须已经带有韵母，bs、zhg 这类简拼不会被当成打错。
 * 原文能完整切开时同样生成这些纠正边。打错的串往往仍能切成别的合法音节（如 lain 读成 la'in），
 * 只在原文切不开时纠正会把大部分打错漏掉，这里交给分数决定谁排前面。
 * 不做漏打一个字母的纠正：打字时很少在音节中间漏掉字母，想少按几个字母时用户会直接打简拼，例如 srf 对应输入法
 */
function addEditCorrections(code: string, edges: SyllableEdge[][], fuzzy: boolean, coveredExtra: number): void {
  const length = code.length;
  const offer = (start: number, end: number, variant: string, typed: string, cost: number): void => {
    const text = canonicalSyllable(variant);
    if (isSyllable(text)) {
      addCorrectedEdge(edges[start], start, end, text, typed, cost + coveredExtra, fuzzy);
    } else if (end === length && hasVowel(variant) && isSyllablePrefix(variant)) {
      addCorrectedPartial(edges[start], start, end, variant, typed, cost + coveredExtra + PENALTY_PARTIAL_END, fuzzy);
    }
  };
  for (let i = 0; i < length; i++) {
    if (code.charAt(i) === SEPARATOR) {
      continue;
    }
    const maxLength = Math.min(MAX_SYLLABLE_LENGTH + 1, length - i);
    for (let len = 2; len <= maxLength; len++) {
      const typed = code.substring(i, i + len);
      if (typed.indexOf(SEPARATOR) >= 0) {
        break;
      }
      const end = i + len;
      if (isSyllable(typed) || (end === length && isSyllablePrefix(typed))) {
        // 读得通的音节也接受相邻字母打反的纠正，多扣一截。ou 与 uo、ai 与 ia、ei 与 ie 打反以后
        // 常常正好是另一个合法音节，例如 rugou 想打“如果”
        if (isSyllable(typed)) {
          for (let j = 0; j + 1 < len; j++) {
            const swapped = canonicalSyllable(typed.substring(0, j) + typed.charAt(j + 1) + typed.charAt(j) +
              typed.substring(j + 2));
            if (typed.charAt(j) !== typed.charAt(j + 1) && isSyllable(swapped)) {
              addCorrectedEdge(edges[i], i, end, swapped, typed, EDIT_SWAP_COST + READABLE_SWAP_EXTRA_COST + coveredExtra,
                fuzzy);
            }
          }
        }
        continue;
      }
      // 这一段最后一个字母能和后面的字母拼成音节开头时，它多半属于下一个音节，不当成多打的字母吞掉。
      // 例如 youbuguan 里的 g，当成 bu 多打的字母时，选了“又不”就只剩下 uan
      const next = code.substring(end - 1, end + 1);
      const tailOpensNext = end < length && (isSyllable(next) || isSyllablePrefix(next));
      for (let j = 0; j < len; j++) {
        const variant = typed.substring(0, j) + typed.substring(j + 1);
        if (!tailOpensNext || variant !== typed.substring(0, len - 1)) {
          offer(i, end, variant, typed, EDIT_EXTRA_COST);
        }
      }
      for (let j = 0; j + 1 < len; j++) {
        if (typed.charAt(j) !== typed.charAt(j + 1)) {
          offer(i, end, typed.substring(0, j) + typed.charAt(j + 1) + typed.charAt(j) + typed.substring(j + 2), typed,
            EDIT_SWAP_COST);
        }
      }
    }
  }
}

/**
 * 跨音节打反：前一个音节的最后一个字母与后一个音节的第一个字母互换，例如 xiaznai 想打“现在”，
 * shemne 想打“什么”。两个大拇指分管左右两半键盘时，跨音节的两个字母常常一先一后按反。
 * 每处打反生成一对纠错边：左半边读成换回字母以后的前一个音节，代价记在这条边上；
 * 右半边读成后一个音节，只能紧跟在自己的左半边后面，并且两条落在同一个词里，见 PinyinEngine.collectArcs。
 * 两半都必须带韵母并且至少两个字母，单独的 m、n 与 a、e、o 不参与，以免拆出大量噪声。
 */
function addCrossSwaps(code: string, edges: SyllableEdge[][], fuzzy: boolean, coveredExtra: number): void {
  const length = code.length;
  for (let j = 1; j + 1 < length; j++) {
    const a = code.charAt(j);
    const b = code.charAt(j + 1);
    if (a === b || a === SEPARATOR || b === SEPARATOR) {
      continue;
    }
    for (let i = j - 1; i >= 0 && j - i + 1 <= MAX_SYLLABLE_LENGTH; i--) {
      if (code.charAt(i) === SEPARATOR) {
        break;
      }
      const leftText = code.substring(i, j) + b;
      const left = canonicalSyllable(leftText);
      if (!isSyllable(left) || !hasVowel(leftText)) {
        continue;
      }
      for (let k = j + 3; k <= length && k - j - 1 <= MAX_SYLLABLE_LENGTH; k++) {
        if (code.charAt(k - 1) === SEPARATOR) {
          break;
        }
        const rightText = a + code.substring(j + 2, k);
        if (!hasVowel(rightText)) {
          continue;
        }
        const typed = code.substring(j + 1, k);
        const right = canonicalSyllable(rightText);
        let tail: SyllableEdge | undefined = undefined;
        if (isSyllable(right)) {
          tail = makeEdge(j + 1, k, right, typed, EdgeKind.FULL, 0, fuzzy ? syllableVariants(right) : NO_VARIANTS, true);
        } else if (k === length && isSyllablePrefix(rightText)) {
          tail = makeEdge(j + 1, k, rightText, typed, EdgeKind.PARTIAL, PENALTY_PARTIAL_END,
            fuzzy ? prefixVariants(rightText) : NO_VARIANTS, true);
        }
        if (tail === undefined) {
          continue;
        }
        tail.swapTail = true;
        const head = makeEdge(i, j + 1, left, code.substring(i, j + 1), EdgeKind.FULL, EDIT_SWAP_COST + coveredExtra,
          fuzzy ? syllableVariants(left) : NO_VARIANTS, true);
        head.swapNext = tail;
        edges[i].push(head);
        edges[j + 1].push(tail);
      }
    }
  }
}

/**
 * 这一段上是否已有按前缀匹配的边。末尾的不完整音节与简拼边都按前缀匹配，含义相同，惩罚更轻的那条即可。
 * 完整音节边只匹配同一个音节，不影响简拼边，例如 a 之外还要有匹配 an、ai、ang 的简拼边。
 */
function hasPrefixEdge(list: SyllableEdge[], end: number): boolean {
  for (const edge of list) {
    if (edge.end === end && !edge.corrected &&
      (edge.kind === EdgeKind.PARTIAL || edge.kind === EdgeKind.ABBR)) {
      return true;
    }
  }
  return false;
}

// 跨音节打反的两半只能成对使用，其他纠正不能与它们合并
function isSwapPart(edge: SyllableEdge): boolean {
  return edge.swapNext !== undefined || edge.swapTail === true;
}

/**
 * 替换一个字母后的完整音节。同一位置、同一音节只保留代价最小的一条，与原文相同的音节不重复添加。
 */
function addCorrectedEdge(list: SyllableEdge[], start: number, end: number, text: string, typed: string,
  cost: number, fuzzy: boolean, tap: boolean = false): void {
  for (const edge of list) {
    if (edge.end === end && edge.kind === EdgeKind.FULL && edge.text === text && !isSwapPart(edge)) {
      if (edge.corrected && cost < edge.penalty) {
        edge.penalty = cost;
      }
      if (edge.corrected && !tap) {
        edge.tapOnly = false;
      }
      return;
    }
  }
  const edge = makeEdge(start, end, text, typed, EdgeKind.FULL, cost, fuzzy ? syllableVariants(text) : NO_VARIANTS,
    true);
  if (tap) {
    edge.tapOnly = true;
  }
  list.push(edge);
}

// 纠正以后仍没打完的末尾音节，同一位置、同一写法只保留代价最小的一条
function addCorrectedPartial(list: SyllableEdge[], start: number, end: number, text: string, typed: string,
  cost: number, fuzzy: boolean): void {
  for (const edge of list) {
    if (edge.end === end && edge.kind === EdgeKind.PARTIAL && edge.text === text && !isSwapPart(edge)) {
      if (edge.corrected && cost < edge.penalty) {
        edge.penalty = cost;
      }
      return;
    }
  }
  list.push(makeEdge(start, end, text, typed, EdgeKind.PARTIAL, cost, fuzzy ? prefixVariants(text) : NO_VARIANTS,
    true));
}

/**
 * 误触纠错边：每个音节最多替换一个字母，替换后必须是合法音节。
 * 只取代价落在 (minCost, maxCost] 之间的相邻字母，两档分别调用时不会重复。
 */
function addCorrections(code: string, edges: SyllableEdge[][], alternatives: LetterAlternative[][], fuzzy: boolean,
  minCost: number, maxCost: number, onlyEndingAt: number = -1, extraCost: number = 0): void {
  const length = code.length;
  for (let i = 0; i < length; i++) {
    if (code.charAt(i) === SEPARATOR) {
      continue;
    }
    const maxLength = Math.min(MAX_SYLLABLE_LENGTH, length - i);
    for (let len = 1; len <= maxLength; len++) {
      const typed = code.substring(i, i + len);
      if (typed.indexOf(SEPARATOR) >= 0) {
        break;
      }
      if (onlyEndingAt >= 0 && i + len !== onlyEndingAt) {
        continue;
      }
      for (let j = 0; j < len; j++) {
        const options = i + j < alternatives.length ? alternatives[i + j] : undefined;
        if (options === undefined) {
          continue;
        }
        for (const alternative of options) {
          if (alternative.cost <= minCost || alternative.cost > maxCost) {
            continue;
          }
          const variant = typed.substring(0, j) + alternative.letter + typed.substring(j + 1);
          if (isSyllable(variant)) {
            addCorrectedEdge(edges[i], i, i + len, canonicalSyllable(variant), typed, alternative.cost + extraCost,
              fuzzy, extraCost > 0);
          }
        }
      }
    }
  }
}

/**
 * 在字符位置上构造音节边。完整音节可以覆盖全串时只使用完整音节与末尾不完整音节，
 * 无法覆盖时再加入简拼声母边，例如 zhg、nhao。
 * 开启模糊音时，每条边附带可以互换的读音；打出的串本身不是音节而模糊读音是音节时，也作为完整音节，例如 len。
 * 带有按键落点时加入纠错边：手指按在两键交界附近的字母总会参与，其余相邻字母按放宽代价参与，
 * 原文读得通时这些边排在原文写法之后，手指按在邻键正中的误触也能纠正，例如 rugui 想打如果。
 * 无论原文能否切开都生成打错纠正边：相邻两个字母互换、多打一个字母，例如 zhnog、shuu。
 * 整串能用完整音节切开时，切进完整音节内部的简拼边多扣一截，hengping 因此切成 heng'ping。
 */
export function buildLattice(code: string, options: QueryOptions = DEFAULT_QUERY_OPTIONS): SegmentLattice {
  const length = code.length;
  const edges: SyllableEdge[][] = [];
  for (let i = 0; i <= length; i++) {
    edges.push([]);
  }
  if (length === 0 || !isPinyinCode(code)) {
    const empty: SegmentLattice = {
      code: code, edges: edges, covered: false, abbreviationsEnabled: false, strictVowelCovered: false,
      boundaries: undefined
    };
    return empty;
  }
  const fuzzy = options.fuzzy;
  for (let i = 0; i < length; i++) {
    if (code.charAt(i) === SEPARATOR) {
      edges[i].push(makeEdge(i, i + 1, '', SEPARATOR, EdgeKind.SEPARATOR, 0));
      continue;
    }
    const maxLength = Math.min(MAX_SYLLABLE_LENGTH, length - i);
    for (let len = 1; len <= maxLength; len++) {
      const typed = code.substring(i, i + len);
      if (typed.indexOf(SEPARATOR) >= 0) {
        break;
      }
      const end = i + len;
      const atEnd = end === length;
      if (isSyllable(typed)) {
        edges[i].push(makeEdge(i, end, canonicalSyllable(typed), typed, EdgeKind.FULL, 0,
          fuzzy ? syllableVariants(typed) : NO_VARIANTS));
      } else if (i === 0 && atEnd && isStandaloneSyllable(typed)) {
        edges[i].push(makeEdge(i, end, typed, typed, EdgeKind.FULL, 0));
      } else if (fuzzy) {
        const variants = syllableVariants(typed);
        if (variants.length > 0) {
          edges[i].push(makeEdge(i, end, typed, typed, EdgeKind.FULL, 0, variants));
        }
      }
      if (atEnd && isSyllablePrefix(typed)) {
        // 键入串本身已是完整音节时，用户更可能想要该音节，补全路径加重惩罚
        const penalty = isSyllable(typed) ? PENALTY_PARTIAL_OF_FULL : PENALTY_PARTIAL_END;
        edges[i].push(makeEdge(i, end, typed, typed, EdgeKind.PARTIAL, penalty,
          fuzzy ? prefixVariants(typed) : NO_VARIANTS));
      }
    }
  }
  const exactCovered = reachesEnd(edges, length);
  const boundaries = fullSyllableBoundaries(edges, length);
  // 末尾没打完的音节切进完整音节内部时多扣一截，此时纠错边还没有加入
  const strict = strictBoundaries(edges, length);
  if (strict !== undefined) {
    for (let i = 0; i < length; i++) {
      if (strict[i]) {
        continue;
      }
      for (const edge of edges[i]) {
        if (edge.kind === EdgeKind.PARTIAL && edge.end === length) {
          edge.penalty += PENALTY_PARTIAL_SPLIT;
        }
      }
    }
  }
  // 打错纠正不再只看原文能否切开：打错的串多半仍能切成别的合法音节，统一生成后按代价竞争
  addEditCorrections(code, edges, fuzzy, exactCovered ? COVERED_EDIT_EXTRA_COST : 0);
  addCrossSwaps(code, edges, fuzzy, exactCovered ? COVERED_EDIT_EXTRA_COST : 0);
  const alternatives = options.alternatives;
  if (alternatives.length > 0) {
    addCorrections(code, edges, alternatives, fuzzy, -1, CORRECTION_COST_LIMIT);
    // 放宽档覆盖按键记录的全部相邻字母。原文读得通时这些边带着放宽代价，排在原文写法之后；
    // 手指按在邻键正中的误触（如 rugui 想打如果）因此也能纠正，原文切不开时更是必须放宽
    addCorrections(code, edges, alternatives, fuzzy, CORRECTION_COST_LIMIT, Number.MAX_VALUE, -1,
      RESCUE_EXTRA_COST);
  }
  // 简拼边始终参与切分：sh 对应时候，ng 对应那个，aq 对应安全，这些串本身也能当作音节或音节开头。
  // 每条简拼边扣的分远大于完整音节，全拼打完的词排在前面；切进完整音节内部的简拼边再多扣一截
  const abbreviationPenalty = (start: number, end: number): number => {
    const splits = boundaries !== undefined && (!boundaries[start] || !boundaries[end]);
    return PENALTY_ABBREVIATION + (splits ? PENALTY_ABBREVIATION_SPLIT : 0);
  };
  for (let i = 0; i < length; i++) {
    if (code.charAt(i) === SEPARATOR) {
      continue;
    }
    const one = code.substring(i, i + 1);
    if (isAbbreviationLetter(one) && !hasPrefixEdge(edges[i], i + 1)) {
      edges[i].push(makeEdge(i, i + 1, one, one, EdgeKind.ABBR, abbreviationPenalty(i, i + 1),
        fuzzy ? prefixVariants(one) : NO_VARIANTS));
    }
    if (i + 2 <= length) {
      const two = code.substring(i, i + 2);
      if (two.length === 2 && isInitial(two) && !hasPrefixEdge(edges[i], i + 2)) {
        edges[i].push(makeEdge(i, i + 2, two, two, EdgeKind.ABBR, abbreviationPenalty(i, i + 2),
          fuzzy ? prefixVariants(two) : NO_VARIANTS));
      }
    }
  }
  const lattice: SegmentLattice = {
    code: code,
    edges: edges,
    covered: reachesEnd(edges, length),
    abbreviationsEnabled: true,
    strictVowelCovered: strict !== undefined && hasVowel(code),
    boundaries: boundaries
  };
  return lattice;
}

/**
 * 词条音节满足一条音节边时返回模糊音代价，精确读音为 0，不满足时返回 -1。
 */
export function syllableCost(syllable: string, edge: SyllableEdge): number {
  switch (edge.kind) {
    case EdgeKind.FULL:
      if (syllable === edge.text) {
        return 0;
      }
      for (const variant of edge.variants) {
        if (syllable === variant.text) {
          return variant.cost;
        }
      }
      return -1;
    case EdgeKind.PARTIAL:
      if (syllable !== edge.text && syllable.startsWith(edge.text)) {
        return 0;
      }
      for (const variant of edge.variants) {
        if (syllable !== variant.text && syllable.startsWith(variant.text)) {
          return variant.cost;
        }
      }
      return -1;
    case EdgeKind.ABBR:
      if (syllable.startsWith(edge.text)) {
        return 0;
      }
      for (const variant of edge.variants) {
        if (syllable.startsWith(variant.text)) {
          return variant.cost;
        }
      }
      return -1;
    default:
      return -1;
  }
}
