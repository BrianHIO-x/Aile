// 合并各来源的词表与读音，生成切词和词库共用的词表 tools/lexicon-src/external/vocab.tsv。
// 用法：先运行 fetch-lexicon-sources.mjs 与 scan-lccc.mjs，再用 DevEco 自带 Node 执行 node tools/build-vocab.mjs
// 来源：AOSP 原始词库、本项目整理的常用词（tools/lexicon-src/aile-words）、jieba 词表、THUOCL 领域词表、
//       phrase-pinyin-data 词语读音、pinyin-data 单字读音，以及 LCCC 语料自带切分里反复出现的新词。
// 输出每行 "词<TAB>读音:权重|读音:权重<TAB>先验对数概率<TAB>来源"，读音的权重之和为 1。
// 先验概率只用于切分语料，正式词频由 build-lexicon.mjs 按切分结果重新统计。
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  AOSP_TOTAL,
  chars,
  externalDir,
  isHanWord,
  loadAosp,
  loadCharPinyin,
  loadCurated,
  loadJieba,
  loadPhrasePinyin,
  loadThuocl,
  MAX_SYLLABLES,
  requireExternal
} from './lexicon-lib.mjs';

// 语料里出现这么多次以上的汉字都允许组词，AOSP 原始词库收录的字一律允许
const MIN_CHAR_COUNT = 50;
// 语料自带切分里没有收录在任何词表的词，至少出现这么多次，并且内部结合足够紧密，才作为新词。
// 成语、俗语被切碎后的残片（如“朝九晚”）结合也很紧密，凡是其他词表里更长的词的一部分都不收
const MIN_NEW_WORD_COUNT = 50;
const MIN_NEW_WORD_PMI = 4.0;
const MAX_NEW_WORD_CHARS = 6;
// 各来源读音的可信程度
const READING_WEIGHT = { aile: 3, phrase: 2, aosp: 1.5, large: 1, composed: 1 };
// 合并后权重低于这个比例的读音视为噪声，人工整理与 AOSP 的读音除外
const MIN_READING_SHARE = 0.03;
// 拼读整词时，多音字的次要读音占比达到这个值，就把次要读音也列为整词的一个读音
const COMPOSE_ALTERNATIVE_SHARE = 0.2;
// 先验概率的混合比例：语料自带切分、jieba、AOSP
const PRIOR_MIX = { tokens: 0.5, jieba: 0.3, aosp: 0.2 };
const PRIOR_FLOOR = 1e-9;

function readCounts(name) {
  const result = new Map();
  for (const line of readFileSync(requireExternal(name), 'utf8').split('\n')) {
    const tab = line.indexOf('\t');
    if (tab > 0) {
      result.set(line.substring(0, tab), Number(line.substring(tab + 1)));
    }
  }
  return result;
}

const aosp = loadAosp();
const jieba = loadJieba();
const thuocl = loadThuocl();
const phrase = loadPhrasePinyin();
const charPinyin = loadCharPinyin();
const curated = loadCurated();
const tokens = readCounts('lccc_tokens.tsv');
const charCounts = readCounts('lccc_chars.tsv');
if (curated.errors.length > 0) {
  curated.errors.forEach((message) => console.log(`错误 ${message}`));
  process.exit(1);
}

// ---------- 允许的汉字 ----------

const allowed = new Set();
for (const row of aosp) {
  if (chars(row.word).length === 1) {
    allowed.add(row.word);
  }
}
for (const row of curated.rows) {
  chars(row.word).forEach((ch) => allowed.add(ch));
}
for (const [ch, count] of charCounts) {
  if (count >= MIN_CHAR_COUNT && charPinyin.has(ch)) {
    allowed.add(ch);
  }
}
const allowedWord = (word) => {
  const list = chars(word);
  return list.length <= MAX_SYLLABLES && list.every((ch) => allowed.has(ch));
};

// ---------- 单字读音 ----------

// 字 → { 读音 → 词频 }，AOSP 有的字用 AOSP 的分布，没有的字按 pinyin-data 的顺序给出递减的权重
const charReadings = new Map();
for (const row of aosp) {
  if (chars(row.word).length !== 1) {
    continue;
  }
  const readings = charReadings.get(row.word) ?? new Map();
  readings.set(row.syllables, Math.max(readings.get(row.syllables) ?? 0, row.freq));
  charReadings.set(row.word, readings);
}
for (const [ch, list] of charPinyin) {
  if (!charReadings.has(ch) && allowed.has(ch)) {
    const readings = new Map();
    list.forEach((syllable, i) => readings.set(syllable, i === 0 ? 1 : 0.05));
    charReadings.set(ch, readings);
  }
}

function dominantReading(ch) {
  const readings = charReadings.get(ch);
  if (readings === undefined) {
    return undefined;
  }
  let best = undefined;
  let bestFreq = -1;
  for (const [syllable, freq] of readings) {
    if (freq > bestFreq) {
      best = syllable;
      bestFreq = freq;
    }
  }
  return best;
}

// ---------- 词语读音 ----------

// 词 → { 来源 → { 读音 → 份额 } }
const sources = new Map();

function addReading(word, source, syllables, share) {
  let bySource = sources.get(word);
  if (bySource === undefined) {
    bySource = new Map();
    sources.set(word, bySource);
  }
  const readings = bySource.get(source) ?? new Map();
  readings.set(syllables, (readings.get(syllables) ?? 0) + share);
  bySource.set(source, readings);
}

const aospWordFreq = new Map();
for (const row of aosp) {
  if (!allowedWord(row.word)) {
    continue;
  }
  addReading(row.word, 'aosp', row.syllables, row.freq);
  aospWordFreq.set(row.word, (aospWordFreq.get(row.word) ?? 0) + row.freq);
}
const curatedFreq = new Map();
const removed = new Set();
for (const row of curated.rows) {
  if (row.kind === 'remove') {
    removed.add(`${row.syllables}\t${row.word}`);
    continue;
  }
  addReading(row.word, 'aile', row.syllables, 1);
  const freq = row.freq / AOSP_TOTAL;
  curatedFreq.set(row.word, Math.max(curatedFreq.get(row.word) ?? 0, freq));
}

// 词表来源：jieba、THUOCL、phrase-pinyin-data 里在语料中出现过的词、语料里的新词
const candidates = new Set();
for (const word of jieba.keys()) {
  candidates.add(word);
}
for (const word of thuocl.keys()) {
  candidates.add(word);
}
for (const word of phrase.keys()) {
  if (tokens.has(word)) {
    candidates.add(word);
  }
}

// 词表里的多字词各个真子串，用来排除残片
const fragments = new Set();
const markFragments = (word) => {
  const list = chars(word);
  for (let i = 0; i < list.length; i++) {
    for (let j = i + 2; j <= list.length; j++) {
      if (j - i < list.length) {
        fragments.add(list.slice(i, j).join(''));
      }
    }
  }
};
for (const source of [jieba.keys(), thuocl.keys(), phrase.keys(), curated.rows.map((row) => row.word)]) {
  for (const word of source) {
    markFragments(word);
  }
}

// 语料切分里的新词：最好的两段拆分与整词相比，整词的概率要高出 e^MIN_NEW_WORD_PMI 倍
const tokenTotal = Array.from(tokens.values()).reduce((sum, count) => sum + count, 0);
const tokenProb = (word) => (tokens.get(word) ?? 0) / tokenTotal;
let newWords = 0;
const newWordSamples = [];
for (const [word, count] of tokens) {
  if (count < MIN_NEW_WORD_COUNT || candidates.has(word) || sources.has(word) || fragments.has(word)) {
    continue;
  }
  const list = chars(word);
  if (list.length < 2 || list.length > MAX_NEW_WORD_CHARS || !allowedWord(word)) {
    continue;
  }
  let bestSplit = 0;
  for (let i = 1; i < list.length; i++) {
    const left = tokenProb(list.slice(0, i).join(''));
    const right = tokenProb(list.slice(i).join(''));
    bestSplit = Math.max(bestSplit, left * right);
  }
  const pmi = bestSplit > 0 ? Math.log(tokenProb(word) / bestSplit) : Infinity;
  if (pmi >= MIN_NEW_WORD_PMI) {
    candidates.add(word);
    newWords++;
    if (newWordSamples.length < 60) {
      newWordSamples.push(`${word}${count}`);
    }
  }
}

for (const word of candidates) {
  if (!allowedWord(word)) {
    continue;
  }
  const readings = phrase.get(word);
  if (readings !== undefined) {
    const curatedList = readings.filter((item) => item.curated);
    const largeList = readings.filter((item) => !item.curated);
    curatedList.forEach((item, i) => addReading(word, 'phrase', item.syllables, i === 0 ? 0.85 : 0.15));
    largeList.forEach((item, i) => addReading(word, 'large', item.syllables, i === 0 ? 0.7 : 0.3));
  } else if (!sources.has(word)) {
    sources.set(word, new Map());
  }
}

// 已有读音的多字词，拼读没有读音的词时整段沿用
const knownPhrase = new Map();
for (const [word, bySource] of sources) {
  if (chars(word).length < 2) {
    continue;
  }
  for (const source of ['aile', 'phrase', 'aosp', 'large']) {
    const readings = bySource.get(source);
    if (readings !== undefined && readings.size > 0) {
      let best = '';
      let bestShare = -1;
      for (const [syllables, share] of readings) {
        if (share > bestShare) {
          best = syllables;
          bestShare = share;
        }
      }
      knownPhrase.set(word, best);
      break;
    }
  }
}

function readingShares(ch) {
  const readings = charReadings.get(ch);
  if (readings === undefined) {
    return [];
  }
  const total = Array.from(readings.values()).reduce((sum, freq) => sum + freq, 0);
  return Array.from(readings.entries()).map(([syllable, freq]) => [syllable, freq / total])
    .sort((a, b) => b[1] - a[1]);
}

// 用已知的多字词与单字常用读音拼出整词读音，段数越少越好。返回 [[读音, 份额]]：
// 单字拼读的位置里，次要读音占比最高的那个多音字另外给出一个读音，份额按单字读音的比例分配
function composeReadings(word) {
  const reading = composeReading(word);
  if (reading === undefined) {
    return [];
  }
  const syllables = reading.split(' ');
  const list = chars(word);
  let spot = -1;
  let spotShare = COMPOSE_ALTERNATIVE_SHARE;
  let spotReading = '';
  let spotMain = 1;
  syllables.forEach((syllable, i) => {
    if (!singleAt[i]) {
      return;
    }
    const shares = readingShares(list[i]);
    if (shares.length > 1 && shares[0][0] === syllable && shares[1][1] >= spotShare) {
      spot = i;
      spotShare = shares[1][1];
      spotReading = shares[1][0];
      spotMain = shares[0][1];
    }
  });
  if (spot < 0) {
    return [[reading, 1]];
  }
  const alternative = syllables.slice();
  alternative[spot] = spotReading;
  return [[reading, spotMain], [alternative.join(' '), spotShare]];
}

// 最近一次拼读里各位置是否来自单字
let singleAt = [];

// 用已知的多字词与单字常用读音拼出整词读音，段数越少越好
function composeReading(word) {
  const list = chars(word);
  const n = list.length;
  const best = new Array(n + 1).fill(undefined);
  best[0] = { pieces: 0, syllables: [], single: [] };
  for (let i = 0; i < n; i++) {
    if (best[i] === undefined) {
      continue;
    }
    for (let j = n; j > i; j--) {
      const piece = list.slice(i, j).join('');
      const reading = j - i === 1 ? dominantReading(piece) : (j - i < n ? knownPhrase.get(piece) : undefined);
      if (reading === undefined) {
        continue;
      }
      const next = {
        pieces: best[i].pieces + 1,
        syllables: best[i].syllables.concat(reading.split(' ')),
        single: best[i].single.concat(j - i === 1 ? [true] : new Array(j - i).fill(false))
      };
      if (best[j] === undefined || next.pieces < best[j].pieces) {
        best[j] = next;
      }
    }
  }
  if (best[n] === undefined) {
    return undefined;
  }
  singleAt = best[n].single;
  return best[n].syllables.join(' ');
}

let composed = 0;
let dropped = 0;
const rows = [];
for (const [word, bySource] of sources) {
  const isChar = chars(word).length === 1;
  const merged = new Map();
  const protectedReadings = new Set();
  if (isChar) {
    const readings = charReadings.get(word);
    if (readings === undefined) {
      dropped++;
      continue;
    }
    const total = Array.from(readings.values()).reduce((sum, freq) => sum + freq, 0);
    for (const [syllables, freq] of readings) {
      merged.set(syllables, freq / total);
      protectedReadings.add(syllables);
    }
  } else {
    let weightSum = 0;
    // 本项目整理过的词以整理的读音为准，其他来源多出的读音多半是标错的（如 phrase-pinyin-data 的“还款 hai kuan”）。
    // 没有整理过时，人工校对的 phrase-pinyin-data 与 AOSP 不一致的地方，AOSP 独有的读音只保留很小的份额
    const aileReadings = bySource.get('aile');
    const checked = new Set();
    for (const source of aileReadings !== undefined ? ['aile'] : ['phrase']) {
      for (const syllables of (bySource.get(source) ?? new Map()).keys()) {
        checked.add(syllables);
      }
    }
    for (const [source, readings] of bySource) {
      const total = Array.from(readings.values()).reduce((sum, share) => sum + share, 0);
      const weight = READING_WEIGHT[source];
      weightSum += weight;
      for (const [syllables, share] of readings) {
        const doubtful = checked.size > 0 && !checked.has(syllables) &&
          (aileReadings !== undefined || source === 'aosp');
        merged.set(syllables, (merged.get(syllables) ?? 0) + weight * share / total * (doubtful ? 0.25 : 1));
        if (source === 'aile' || (source === 'aosp' && !doubtful)) {
          protectedReadings.add(syllables);
        }
      }
    }
    if (weightSum === 0) {
      const readings = composeReadings(word);
      if (readings.length === 0) {
        dropped++;
        continue;
      }
      for (const [syllables, share] of readings) {
        merged.set(syllables, share);
        protectedReadings.add(syllables);
      }
      weightSum = readings.reduce((sum, item) => sum + item[1], 0);
      composed++;
    }
    for (const [syllables, value] of merged) {
      merged.set(syllables, value / weightSum);
    }
  }
  for (const syllables of Array.from(merged.keys())) {
    if (removed.has(`${syllables}\t${word}`) ||
      (merged.get(syllables) < MIN_READING_SHARE && !protectedReadings.has(syllables))) {
      merged.delete(syllables);
    }
  }
  if (merged.size === 0) {
    dropped++;
    continue;
  }
  const total = Array.from(merged.values()).reduce((sum, value) => sum + value, 0);
  const readingText = Array.from(merged.entries()).sort((a, b) => b[1] - a[1])
    .map(([syllables, value]) => `${syllables}:${(value / total).toFixed(4)}`).join('|');
  const prior = PRIOR_MIX.tokens * tokenProb(word) + PRIOR_MIX.jieba * (jieba.get(word) ?? 0) / 60101967 +
    PRIOR_MIX.aosp * (aospWordFreq.get(word) ?? 0) / AOSP_TOTAL;
  const boosted = Math.max(prior, curatedFreq.get(word) ?? 0, PRIOR_FLOOR);
  const flags = Array.from(bySource.keys()).concat(jieba.has(word) ? ['jieba'] : [])
    .concat(thuocl.has(word) ? ['thuocl'] : []).concat(tokens.has(word) ? ['lccc'] : []).join(',');
  rows.push(`${word}\t${readingText}\t${Math.log(boosted).toFixed(4)}\t${flags}`);
}
rows.sort();
writeFileSync(join(externalDir, 'vocab.tsv'), rows.join('\n') + '\n');
console.log(`allowedChars=${allowed.size} words=${rows.length} composed=${composed} dropped=${dropped} ` +
  `newWords=${newWords}`);
console.log(`新词示例：${newWordSamples.join(' ')}`);
