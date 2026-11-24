// 第二遍处理 LCCC 训练部分：按 vocab.tsv 的词表与先验概率做最大概率切词，统计词频与相邻两词的次数。
// 用法：先运行 build-vocab.mjs，再执行 node --max-old-space-size=3000 tools/count-lccc.mjs [--limit 行数]
// 本项目手写的语料（tools/lexicon-src/corpus）用同一套切词单独统计，生成时再按权重合并。
// 输出到 tools/lexicon-src/external：
//   lccc_unigram.tsv / hand_unigram.tsv   词<TAB>次数，开头两行为 "#total<TAB>总词数" 与 "#chunks<TAB>片段数"
//   lccc_bigram.tsv / hand_bigram.tsv     前词<TAB>后词<TAB>次数，<s> 与 </s> 表示片段的开头与结尾
// 两两组合的种类很多，计数表放在定长的数组里；表快满时丢掉只出现过一次的组合，这类组合最终也会被剪掉。
import { createReadStream, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import {
  codePoints,
  externalDir,
  hanChunks,
  loadHandCorpus,
  requireExternal,
  root,
  segmentCodes,
  WordTrie
} from './lexicon-lib.mjs';

const UNKNOWN_SCORE = -23;
const MIN_BIGRAM_OUTPUT = 2;
const TABLE_BITS = 25;
const limitIndex = process.argv.indexOf('--limit');
const lineLimit = limitIndex > 0 ? Number(process.argv[limitIndex + 1]) : Infinity;

// ---------- 词表 ----------

const words = [];
const scores = [];
const trie = new WordTrie();
for (const line of readFileSync(requireExternal('vocab.tsv'), 'utf8').split('\n')) {
  const parts = line.split('\t');
  if (parts.length < 3) {
    continue;
  }
  trie.add(parts[0], words.length);
  words.push(parts[0]);
  scores.push(Number(parts[2]));
}
const scoreArray = Float64Array.from(scores);
const V = words.length;
const START = V;
const END = V + 1;
const UNKNOWN = V + 2;
const nameOf = (id) => (id < V ? words[id] : id === START ? '<s>' : id === END ? '</s>' : '<unk>');
console.log(`vocab=${V} trieNodes=${trie.wordAt.length}`);

// ---------- 计数表 ----------

class PairTable {
  constructor(bits) {
    this.capacity = 1 << bits;
    this.mask = this.capacity - 1;
    this.first = new Uint32Array(this.capacity);
    this.second = new Uint32Array(this.capacity);
    this.counts = new Uint32Array(this.capacity);
    this.size = 0;
    this.prunes = 0;
  }

  slot(a, b) {
    let h = Math.imul(a, 0x9e3779b1) ^ Math.imul(b + 0x7f4a7c15, 0x85ebca6b);
    h ^= h >>> 15;
    let i = h & this.mask;
    while (this.counts[i] !== 0 && (this.first[i] !== a || this.second[i] !== b)) {
      i = (i + 1) & this.mask;
    }
    return i;
  }

  add(a, b, count) {
    const i = this.slot(a, b);
    if (this.counts[i] === 0) {
      this.first[i] = a;
      this.second[i] = b;
      this.size++;
    }
    this.counts[i] += count;
    if (this.size > this.capacity * 0.72) {
      this.pruneSingles();
    }
  }

  pruneSingles() {
    const keep = [];
    for (let i = 0; i < this.capacity; i++) {
      if (this.counts[i] > 1) {
        keep.push(this.first[i], this.second[i], this.counts[i]);
      }
    }
    this.first.fill(0);
    this.second.fill(0);
    this.counts.fill(0);
    this.size = 0;
    this.prunes++;
    for (let k = 0; k < keep.length; k += 3) {
      const i = this.slot(keep[k], keep[k + 1]);
      this.first[i] = keep[k];
      this.second[i] = keep[k + 1];
      this.counts[i] = keep[k + 2];
      this.size++;
    }
    console.log(`pruned singles, kept=${this.size}`);
  }
}

function makeCounter(bits) {
  return { unigram: new Float64Array(V + 3), unknown: new Map(), pairs: new PairTable(bits), tokens: 0, chunks: 0 };
}

function countChunk(counter, chunk, weight) {
  const ids = segmentCodes(trie, codePoints(chunk), scoreArray, UNKNOWN_SCORE, 0);
  let previous = START;
  counter.chunks++;
  for (const raw of ids) {
    let id = raw;
    if (raw < 0) {
      const ch = String.fromCodePoint(-1 - raw);
      counter.unknown.set(ch, (counter.unknown.get(ch) ?? 0) + weight);
      id = UNKNOWN;
    }
    counter.unigram[id] += weight;
    counter.tokens += weight;
    counter.pairs.add(previous, id, weight);
    previous = id;
  }
  counter.pairs.add(previous, END, weight);
}

function writeCounts(counter, prefix, minPairCount) {
  const unigramLines = [`#total\t${counter.tokens}`, `#chunks\t${counter.chunks}`];
  for (let id = 0; id < V; id++) {
    if (counter.unigram[id] > 0) {
      unigramLines.push(`${words[id]}\t${counter.unigram[id]}`);
    }
  }
  for (const [ch, count] of counter.unknown) {
    unigramLines.push(`${ch}\t${count}\tunknown`);
  }
  writeFileSync(join(externalDir, `${prefix}_unigram.tsv`), unigramLines.join('\n') + '\n');
  const table = counter.pairs;
  const pairLines = [];
  for (let i = 0; i < table.capacity; i++) {
    if (table.counts[i] >= minPairCount) {
      pairLines.push(`${nameOf(table.first[i])}\t${nameOf(table.second[i])}\t${table.counts[i]}`);
    }
  }
  writeFileSync(join(externalDir, `${prefix}_bigram.tsv`), pairLines.join('\n') + '\n');
  console.log(`${prefix}: chunks=${counter.chunks} tokens=${counter.tokens} pairs=${table.size} ` +
    `written=${pairLines.length} prunes=${table.prunes}`);
}

// ---------- 手写语料 ----------

const hand = makeCounter(16);
const handChunks = [];
for (const line of loadHandCorpus()) {
  for (const chunk of hanChunks(line)) {
    countChunk(hand, chunk, 1);
    handChunks.push(chunk);
  }
}
// 手写评测句不能出现在手写语料里，否则评测结果偏高
for (const rawLine of readFileSync(join(root, 'tools', 'engine-bench', 'sentences.txt'), 'utf8').split(/\r?\n/)) {
  const sentence = rawLine.split('\t')[0];
  if (sentence.length > 0 && !sentence.startsWith('#') && handChunks.some((chunk) => chunk.includes(sentence))) {
    console.log(`提醒 评测句子出现在手写语料里：${sentence}`);
  }
}
// 手写语料很小，所有组合都写出
writeCounts(hand, 'hand', 1);

// ---------- LCCC ----------

const lccc = makeCounter(TABLE_BITS);
const startTime = Date.now();
let lines = 0;
const reader = createInterface({ input: createReadStream(requireExternal('lccc_train.txt')), crlfDelay: Infinity });
for await (const line of reader) {
  if (line.length === 0) {
    continue;
  }
  countChunk(lccc, line, 1);
  lines++;
  if (lines % 2000000 === 0) {
    console.log(`lines=${lines} tokens=${lccc.tokens} pairs=${lccc.pairs.size} s=${(Date.now() - startTime) / 1000}`);
  }
  if (lines >= lineLimit) {
    break;
  }
}
writeCounts(lccc, 'lccc', MIN_BIGRAM_OUTPUT);
console.log(`done in ${(Date.now() - startTime) / 1000}s`);
