// 生成词间搭配模型 entry/src/main/resources/rawfile/lexicon/bigram.txt：带回退的二元语言模型。
// 用法：先运行 count-lccc.mjs 与 build-lexicon.mjs，再用 DevEco 自带 Node 执行 node tools/build-bigram.mjs
// 计数来自 LCCC 对话语料与本项目手写语料（按 HAND_WEIGHT 倍计入），词的概率取自生成好的词库。
// 模型：P(后|前) = (次数 - 折扣) / 前词次数，没有记录的组合按 α(前) × P(后) 回退。
// 引擎给每个词弧计算过 ln P(后)，这里存的是需要额外加上的部分：
//   有记录的组合  ln P(后|前) - ln P(后)
//   没有记录      ln α(前)
// 只保留与回退估计相差足够大的组合，剪掉以后重新计算 α，概率之和仍为 1。
// LCCC 过滤掉的词（build-lexicon.mjs 写出的 censored.tsv）在语料里从未出现，作为后词时不套用回退扣分。
// 输出格式：首行 "#aile-bigram<TAB>2<TAB>前词数<TAB>组合数<TAB>量化倍数"，
//   第二行 "#neutral<TAB>词 词 …"，列出不套用回退扣分的后词，
//   其余每行 "前词<TAB>lnα<TAB>后词 值 后词 值 …"，数值都乘以量化倍数取整，各行按前词的 UTF-16 编码排序，
//   引擎用二分查找定位前词。<s> 表示一段话的开头。
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { outDir, requireExternal } from './lexicon-lib.mjs';

// 手写语料每句的次数按这个倍数计入
const HAND_WEIGHT = 20;
const DISCOUNT = 0.8;
const MIN_PAIR_COUNT = 3;
// 有记录的估计与回退估计相差的自然对数至少为 MIN_GAIN，并且次数 × 相差的对数至少为 MIN_WEIGHTED_GAIN，
// 后者近似这个组合对整体似然的贡献。engine-bench 上，同样三十多万个组合，按贡献剪枝比只按相差剪枝
// 整句准确率高一个百分点；组合数翻倍到六十万，聊天整句只再高一个百分点，文件大小也翻倍
const MIN_GAIN = 0.3;
const MIN_WEIGHTED_GAIN = 80;
const QUANT = 10;
const START = '<s>';
// 过滤词里只列出概率不低于这个值的，约六千个。更少见的词很少出现在整句里，列出来只会拖慢加载
const MIN_NEUTRAL_PROB = 1e-6;

// ---------- 词的概率 ----------

const lexiconText = readFileSync(join(outDir, 'base_lexicon.txt'), 'utf8');
const dataStart = lexiconText.indexOf('\n#data\n');
const total = Number(lexiconText.substring(0, lexiconText.indexOf('\n')).split('\t')[2]);
const wordProb = new Map();
for (const line of lexiconText.substring(dataStart + 7).split('\n')) {
  const parts = line.split('\t');
  if (parts.length === 3) {
    wordProb.set(parts[1], (wordProb.get(parts[1]) ?? 0) + Number(parts[2]) / total);
  }
}

// ---------- 计数 ----------

function readUnigram(name) {
  const counts = new Map();
  let chunks = 0;
  for (const line of readFileSync(requireExternal(name), 'utf8').split('\n')) {
    const parts = line.split('\t');
    if (parts[0] === '#chunks') {
      chunks = Number(parts[1]);
    } else if (parts.length === 2 && !parts[0].startsWith('#')) {
      counts.set(parts[0], Number(parts[1]));
    }
  }
  counts.set(START, chunks);
  return counts;
}

const contextCount = new Map();
for (const [name, weight] of [['lccc_unigram.tsv', 1], ['hand_unigram.tsv', HAND_WEIGHT]]) {
  for (const [word, count] of readUnigram(name)) {
    contextCount.set(word, (contextCount.get(word) ?? 0) + weight * count);
  }
}

// 前词 → { 后词 → 次数 }
const pairs = new Map();
for (const [name, weight] of [['lccc_bigram.tsv', 1], ['hand_bigram.tsv', HAND_WEIGHT]]) {
  for (const line of readFileSync(requireExternal(name), 'utf8').split('\n')) {
    const parts = line.split('\t');
    if (parts.length !== 3 || !wordProb.has(parts[1]) || (parts[0] !== START && !wordProb.has(parts[0]))) {
      continue;
    }
    let row = pairs.get(parts[0]);
    if (row === undefined) {
      row = new Map();
      pairs.set(parts[0], row);
    }
    row.set(parts[1], (row.get(parts[1]) ?? 0) + weight * Number(parts[2]));
  }
}

// ---------- 估计与剪枝 ----------

function backoffWeight(kept) {
  let bigramMass = 0;
  let unigramMass = 0;
  for (const item of kept) {
    bigramMass += item.prob;
    unigramMass += wordProb.get(item.word);
  }
  return Math.max(1e-6, 1 - bigramMass) / Math.max(1e-6, 1 - unigramMass);
}

const out = [];
let pairTotal = 0;
let positive = 0;
for (const previous of Array.from(pairs.keys()).sort()) {
  const c1 = contextCount.get(previous) ?? 0;
  if (c1 <= 0) {
    continue;
  }
  const candidates = [];
  for (const [word, count] of pairs.get(previous)) {
    if (count >= MIN_PAIR_COUNT) {
      candidates.push({ word: word, count: count, prob: (count - DISCOUNT) / c1 });
    }
  }
  if (candidates.length === 0) {
    continue;
  }
  const initialAlpha = Math.log(backoffWeight(candidates));
  const kept = candidates.filter((item) => {
    const gain = Math.abs(Math.log(item.prob) - Math.log(wordProb.get(item.word)) - initialAlpha);
    return gain >= MIN_GAIN && item.count * gain >= MIN_WEIGHTED_GAIN;
  });
  if (kept.length === 0) {
    continue;
  }
  const alpha = Math.log(backoffWeight(kept));
  kept.sort((a, b) => (a.word < b.word ? -1 : a.word > b.word ? 1 : 0));
  const values = [];
  for (const item of kept) {
    const value = Math.round((Math.log(item.prob) - Math.log(wordProb.get(item.word))) * QUANT);
    values.push(`${item.word} ${value}`);
    if (value > 0) {
      positive++;
    }
  }
  pairTotal += kept.length;
  out.push(`${previous}\t${Math.round(alpha * QUANT)}\t${values.join(' ')}`);
}

const neutral = readFileSync(requireExternal('censored.tsv'), 'utf8').split('\n')
  .filter((word) => (wordProb.get(word) ?? 0) >= MIN_NEUTRAL_PROB);
const output = `#aile-bigram\t2\t${out.length}\t${pairTotal}\t${QUANT}\n#neutral\t${neutral.join(' ')}\n` +
  out.join('\n') + '\n';
writeFileSync(join(outDir, 'bigram.txt'), output, 'utf8');
const sha256 = createHash('sha256').update(output, 'utf8').digest('hex');
console.log(`rows=${out.length} pairs=${pairTotal} positive=${positive} neutral=${neutral.length} ` +
  `bytes=${Buffer.byteLength(output, 'utf8')} ` +
  `sha256=${sha256}`);
