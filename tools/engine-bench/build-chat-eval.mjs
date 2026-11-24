// 从 LCCC 留出部分（scan-lccc.mjs 生成的 lccc_heldout.txt）抽取聊天评测集，这部分对话不参与任何统计。
// 用法：生成词库以后执行 node tools/engine-bench/build-chat-eval.mjs
// 输出到 tools/lexicon-src/external（不入库）：
//   chat-sentences.txt  "汉字片段<TAB>拼音"，片段为标点之间 4～14 个字的整段
//   chat-words.txt      "拼音<TAB>词语"，留出部分最常见的 400 个多字词，用于简拼评测
// 拼音按词库切词后取每个词最常用的读音，多音字偶尔会标错，只用于前后版本对比。
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  chars,
  codePoints,
  externalDir,
  hanChunks,
  outDir,
  requireExternal,
  segmentCodes,
  WordTrie
} from '../lexicon-lib.mjs';

const SENTENCE_COUNT = 2000;
const WORD_COUNT = 400;
const MIN_CHARS = 4;
const MAX_CHARS = 14;

const lexiconText = readFileSync(join(outDir, 'base_lexicon.txt'), 'utf8');
const total = Number(lexiconText.substring(0, lexiconText.indexOf('\n')).split('\t')[2]);
const best = new Map();
for (const line of lexiconText.substring(lexiconText.indexOf('\n#data\n') + 7).split('\n')) {
  const parts = line.split('\t');
  if (parts.length !== 3) {
    continue;
  }
  const freq = Number(parts[2]);
  const item = best.get(parts[1]) ?? { freq: 0, top: 0, syllables: '' };
  item.freq += freq;
  if (freq > item.top) {
    item.top = freq;
    item.syllables = parts[0];
  }
  best.set(parts[1], item);
}
const words = Array.from(best.keys());
const scores = Float64Array.from(words.map((word) => Math.log(best.get(word).freq / total)));
const trie = new WordTrie();
words.forEach((word, id) => trie.add(word, id));

const chunks = [];
for (const line of readFileSync(requireExternal('lccc_heldout.txt'), 'utf8').split('\n')) {
  for (const chunk of hanChunks(line)) {
    chunks.push(chunk);
  }
}

const sentences = [];
const seen = new Set();
const wordCounts = new Map();
const step = Math.max(1, Math.floor(chunks.length / (SENTENCE_COUNT * 3)));
chunks.forEach((chunk, index) => {
  const list = chars(chunk);
  const ids = segmentCodes(trie, codePoints(chunk), scores, -30, 0);
  if (ids.some((id) => id < 0)) {
    return;
  }
  for (const id of ids) {
    if (chars(words[id]).length >= 2 && chars(words[id]).length <= 4) {
      wordCounts.set(words[id], (wordCounts.get(words[id]) ?? 0) + 1);
    }
  }
  // 重复字很多的片段（哈哈哈哈）不能说明什么，跳过
  if (index % step !== 0 || list.length < MIN_CHARS || list.length > MAX_CHARS ||
    new Set(list).size < list.length * 0.6 || seen.has(chunk) || sentences.length >= SENTENCE_COUNT) {
    return;
  }
  seen.add(chunk);
  sentences.push(`${chunk}\t${ids.map((id) => best.get(words[id]).syllables).join(' ')}`);
});

const topWords = Array.from(wordCounts.entries()).sort((a, b) => b[1] - a[1]).slice(0, WORD_COUNT)
  .map(([word]) => `${best.get(word).syllables}\t${word}`);
writeFileSync(join(externalDir, 'chat-sentences.txt'),
  '# LCCC 留出部分的聊天片段，由 tools/engine-bench/build-chat-eval.mjs 生成\n' + sentences.join('\n') + '\n');
writeFileSync(join(externalDir, 'chat-words.txt'),
  '# LCCC 留出部分最常见的多字词，由 tools/engine-bench/build-chat-eval.mjs 生成\n' + topWords.join('\n') + '\n');
console.log(`chunks=${chunks.length} sentences=${sentences.length} words=${topWords.length}`);
