// 生成输入法使用的 UTF-8 紧凑词库 entry/src/main/resources/rawfile/lexicon/base_lexicon.txt。
// 用法（DevEco 自带 Node）：
//   node tools/fetch-lexicon-sources.mjs   下载外部数据（只需一次）
//   node tools/scan-lccc.mjs               拆分 LCCC 语料（只需一次）
//   node tools/build-vocab.mjs             合并词表与读音
//   node --max-old-space-size=3200 tools/count-lccc.mjs   按词表切分语料并计数
//   node --max-old-space-size=3000 tools/find-lccc-absent.mjs   找出语料清洗时过滤掉的词
//   node tools/build-lexicon.mjs           生成词库
//   node tools/build-bigram.mjs            生成词间搭配模型
// 词频按几份来源的概率混合：LCCC 对话语料的切分计数（现代口语）、jieba 词频（书面语）、AOSP 原始词库、
// 本项目手写的聊天语料。多音词按 vocab.tsv 里的读音份额拆分词频。
// 本项目整理的常用词（tools/lexicon-src/aile-words）仍然生效：
//   @5 ～ @1  之后的词条按等级给出词频下限
//   @set N   之后的词条词频强制设为 N
//   @remove  之后的词条删除
//   等级与 @set 的数值沿用 AOSP 原始词库的尺度，换算成概率时除以 AOSP 词频总和。
// 输出格式（输入法启动时只读索引，每个桶第一次查询时才解析）：
//   首行  "#aile-lexicon<TAB>2<TAB>词频总和<TAB>条目数<TAB>索引行数<TAB>最多音节数<TAB>最小对数概率"
//   索引  每行 "索引键<TAB>起点<TAB>长度"，起点与长度按 UTF-16 码元计，相对数据段开头。
//         索引键为各音节首字母，n、r 记作 l，f 记作 h，与 entry/src/main/ets/engine/Lexicon.ets 的 keyLetter 一致。
//         全部键的前缀也各占一行，只是前缀时长度为 0，引擎据此剪枝
//   "#data" 一行之后为数据段，按索引键分桶，桶内每行 "音节(空格分隔)<TAB>词<TAB>整数词频"，按词频从高到低排列。
//         对数概率等于 ln(词频) - ln(词频总和)，引擎解析一个桶时才计算
import { createHash } from 'node:crypto';
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  AOSP_TOTAL,
  chars,
  externalDir,
  loadAosp,
  loadCurated,
  loadJieba,
  outDir,
  requireExternal,
  srcDir
} from './lexicon-lib.mjs';

// 各来源的混合比例。engine-bench 上把 LCCC 调到 0.4 或 0.75，整句准确率的变化都在一个百分点以内
const MIX = { lccc: 0.6, jieba: 0.2, aosp: 0.1, hand: 0.1 };
const JIEBA_TOTAL = 60101967;
// LCCC 清洗时整句删掉了含“操、靠、草、滚”等字的对话，“微信、红包、转账、支付宝”这类词当作广告过滤掉了，
// “政府、改革”这类时政词也一并删掉了。find-lccc-absent.mjs 列出原文里一次都没出现的词，
// 其中在其他来源里不算少见的视为被过滤，概率只按其他来源估计。
// 这些词另外写进 external/censored.tsv，二元模型据此不对它们套用“没见过的组合”的回退扣分
const CENSORED_MIN_PROB = 1e-7;
// 只出现在词表里、没有任何词频的词按这个概率计
const FLOOR_PROB = 2e-9;
// 多字词的概率低于这个值时不收录，AOSP 原始词库与本项目整理的词除外。
// 取 1e-8 时收录三十四万词，整句准确率与现在的十七万词相同，词库大一倍
const MIN_WORD_PROB = 3e-8;
// 概率换成整数词频的倍数，最低的词条词频约为 1
const SCALE = 1 / FLOOR_PROB;
// 单字单独成词的概率，不超过它在 LCCC 里出现总次数的这么多倍。
// jieba 词频里混有大量乱码字，例如 UTF-8 文本按 GBK 读出来的“鍙、鏄、鐨”，频率高达几千上万；
// 还有一批标成 zg 的生僻字，例如“堝、紟、枃”。封顶以后，这些字落到同音字的末尾
const SINGLE_CAP_RATIO = 3;
// LCCC 清洗时整句删掉了含“靠、草、操、滚”等字的对话，这些字在 LCCC 里一次也不出现。
// AOSP 词频达到这个数的单字按被删掉的常用字处理，概率照旧；不到这个数的按乱码或生僻字处理，只按 AOSP 的份额计算
const CENSORED_CHAR_AOSP_MIN = 300;

function readUnigram(name) {
  const counts = new Map();
  let total = 0;
  for (const line of readFileSync(requireExternal(name), 'utf8').split('\n')) {
    const parts = line.split('\t');
    if (parts.length < 2) {
      continue;
    }
    if (parts[0] === '#total') {
      total = Number(parts[1]);
    } else if (!parts[0].startsWith('#') && parts.length === 2) {
      counts.set(parts[0], Number(parts[1]));
    }
  }
  return { counts: counts, total: total };
}

const lccc = readUnigram('lccc_unigram.tsv');
// LCCC 里每个汉字的出现次数，单独成词与出现在词里都算
const lcccChars = new Map();
for (const line of readFileSync(requireExternal('lccc_chars.tsv'), 'utf8').split('\n')) {
  const tab = line.indexOf('\t');
  if (tab > 0) {
    lcccChars.set(line.substring(0, tab), Number(line.substring(tab + 1)));
  }
}
const hand = readUnigram('hand_unigram.tsv');
const jieba = loadJieba();
const aospWordFreq = new Map();
const aospWords = new Set();
for (const row of loadAosp()) {
  aospWordFreq.set(row.word, (aospWordFreq.get(row.word) ?? 0) + row.freq);
  aospWords.add(row.word);
}
const absent = new Set(readFileSync(requireExternal('lccc_absent.tsv'), 'utf8').split('\n'));
const curated = loadCurated();
if (curated.errors.length > 0) {
  curated.errors.forEach((message) => console.log(`错误 ${message}`));
  process.exit(1);
}
// 词条（读音 + 词）→ 整理给出的概率下限或强制值
const floors = new Map();
const forced = new Map();
const curatedWords = new Set();
for (const row of curated.rows) {
  const key = `${row.syllables}\t${row.word}`;
  if (row.kind === 'tier') {
    floors.set(key, Math.max(floors.get(key) ?? 0, row.freq / AOSP_TOTAL));
    curatedWords.add(row.word);
  } else if (row.kind === 'set') {
    forced.set(key, row.freq / AOSP_TOTAL);
    curatedWords.add(row.word);
  }
}

// 单字的概率按 LCCC 里的总出现次数封顶，LCCC 里没有的字看 AOSP 词频判断是被删掉的常用字还是乱码
function singleCharProb(word, prob) {
  const count = lcccChars.get(word) ?? 0;
  if (count > 0) {
    return Math.min(prob, SINGLE_CAP_RATIO * count / lccc.total);
  }
  const aosp = aospWordFreq.get(word) ?? 0;
  if (aosp >= CENSORED_CHAR_AOSP_MIN) {
    return prob;
  }
  return Math.min(prob, MIX.aosp * aosp / AOSP_TOTAL);
}

const rows = [];
const censored = [];
let droppedWords = 0;
let keptWords = 0;
for (const line of readFileSync(requireExternal('vocab.tsv'), 'utf8').split('\n')) {
  const parts = line.split('\t');
  if (parts.length < 4) {
    continue;
  }
  const word = parts[0];
  const other = MIX.hand * (hand.counts.get(word) ?? 0) / hand.total +
    MIX.jieba * (jieba.get(word) ?? 0) / JIEBA_TOTAL +
    MIX.aosp * (aospWordFreq.get(word) ?? 0) / AOSP_TOTAL;
  const lcccCount = lccc.counts.get(word) ?? 0;
  const single = chars(word).length === 1;
  let prob = MIX.lccc * lcccCount / lccc.total + other;
  if (lcccCount === 0 && absent.has(word) && other / (1 - MIX.lccc) >= CENSORED_MIN_PROB &&
    (!single || (lcccChars.get(word) ?? 0) > 0 || (aospWordFreq.get(word) ?? 0) >= CENSORED_CHAR_AOSP_MIN)) {
    prob = other / (1 - MIX.lccc);
    censored.push(word);
  }
  if (single) {
    prob = singleCharProb(word, prob);
  }
  if (prob <= 0) {
    prob = FLOOR_PROB;
  }
  if (!single && prob < MIN_WORD_PROB && !aospWords.has(word) && !curatedWords.has(word)) {
    droppedWords++;
    continue;
  }
  keptWords++;
  for (const item of parts[1].split('|')) {
    const colon = item.lastIndexOf(':');
    const syllables = item.substring(0, colon);
    const key = `${syllables}\t${word}`;
    let entryProb = prob * Number(item.substring(colon + 1));
    if (forced.has(key)) {
      entryProb = forced.get(key);
    } else if (floors.has(key)) {
      entryProb = Math.max(entryProb, floors.get(key));
    }
    rows.push({ syllables: syllables, word: word, freq: Math.max(1, Math.round(entryProb * SCALE)) });
  }
}

// ---------- 输出 ----------

function keyLetter(syllable) {
  const c = syllable.charAt(0);
  return c === 'n' || c === 'r' ? 'l' : c === 'f' ? 'h' : c;
}

const total = rows.reduce((sum, row) => sum + row.freq, 0);
const logTotal = Math.log(total);
const buckets = new Map();
let maxSyllables = 0;
let minLogProb = 0;
for (const row of rows) {
  const syllableList = row.syllables.split(' ');
  const key = syllableList.map(keyLetter).join('');
  minLogProb = Math.min(minLogProb, Math.round((Math.log(row.freq) - logTotal) * 10000) / 10000);
  maxSyllables = Math.max(maxSyllables, syllableList.length);
  const bucket = buckets.get(key) ?? [];
  bucket.push(row);
  buckets.set(key, bucket);
}
const slots = new Map();
const pieces = [];
let dataLength = 0;
for (const key of Array.from(buckets.keys()).sort()) {
  const bucket = buckets.get(key);
  bucket.sort((a, b) => b.freq - a.freq || (a.syllables < b.syllables ? -1 : a.syllables > b.syllables ? 1 : 0) ||
    (a.word < b.word ? -1 : a.word > b.word ? 1 : 0));
  const start = dataLength;
  for (const row of bucket) {
    const text = `${row.syllables}\t${row.word}\t${row.freq}\n`;
    pieces.push(text);
    dataLength += text.length;
  }
  slots.set(key, [start, dataLength - start]);
}
// 只作为前缀出现的键长度为 0
for (const key of Array.from(buckets.keys())) {
  for (let i = 1; i < key.length; i++) {
    const prefix = key.substring(0, i);
    if (!slots.has(prefix)) {
      slots.set(prefix, [0, 0]);
    }
  }
}
const slotKeys = Array.from(slots.keys()).sort();
const lines = [`#aile-lexicon\t2\t${total}\t${rows.length}\t${slotKeys.length}\t${maxSyllables}\t${minLogProb}`];
for (const key of slotKeys) {
  const [start, length] = slots.get(key);
  lines.push(`${key}\t${start}\t${length}`);
}
lines.push('#data');
const output = lines.join('\n') + '\n' + pieces.join('');

writeFileSync(join(externalDir, 'censored.tsv'), censored.join('\n') + '\n');
mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, 'base_lexicon.txt'), output, 'utf8');
copyFileSync(join(srcDir, 'NOTICE-AOSP-PinyinIME.txt'), join(outDir, 'NOTICE-AOSP-PinyinIME.txt'));
copyFileSync(join(srcDir, 'NOTICE-lexicon-sources.txt'), join(outDir, 'NOTICE-lexicon-sources.txt'));

const bytes = Buffer.byteLength(output, 'utf8');
const sha256 = createHash('sha256').update(output, 'utf8').digest('hex');
console.log(`words=${keptWords} dropped=${droppedWords} censored=${censored.length} entries=${rows.length} ` +
  `keys=${buckets.size} slots=${slotKeys.length} total=${total} bytes=${bytes} sha256=${sha256}`);
