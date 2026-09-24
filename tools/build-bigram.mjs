// 生成词间搭配表：用基础词库给 tools/lexicon-src/corpus 下的语料切词，统计相邻两个词一起出现的次数。
// 用法：先运行 build-lexicon.mjs，再用 DevEco 自带 Node 执行 node tools/build-bigram.mjs
// 输出格式：# 开头为说明行，其余每行为 "前一个词<TAB>后一个词<TAB>次数"。
// 语料按标点断开，只统计同一段里相邻的两个词。评测句子如果整句出现在语料里，会列出来提醒删掉。
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const lexiconPath = join(root, 'entry', 'src', 'main', 'resources', 'rawfile', 'lexicon', 'base_lexicon.txt');
const corpusDir = join(root, 'tools', 'lexicon-src', 'corpus');
const benchPath = join(root, 'tools', 'engine-bench', 'sentences.txt');
const outPath = join(root, 'entry', 'src', 'main', 'resources', 'rawfile', 'lexicon', 'bigram.txt');

// 与引擎相同的长词奖励，切词结果与输入时的整句更接近
const WORD_BONUS_PER_CHAR = 1.0;
const UNKNOWN_CHAR_SCORE = -20;
const MAX_WORD_CHARS = 8;

// 词库格式见 build-lexicon.mjs，只读 “#data” 之后的词条，第三列为词频
const lexiconText = readFileSync(lexiconPath, 'utf8');
const dataStart = lexiconText.indexOf('\n#data\n');
if (!lexiconText.startsWith('#aile-lexicon\t2\t') || dataStart < 0) {
  throw new Error('请先运行 build-lexicon.mjs 生成新格式的词库');
}
const logTotal = Math.log(Number(lexiconText.substring(0, lexiconText.indexOf('\n')).split('\t')[2]));
const best = new Map();
for (const line of lexiconText.substring(dataStart + '\n#data\n'.length).split('\n')) {
  const parts = line.split('\t');
  if (parts.length !== 3) {
    continue;
  }
  const score = Math.log(Number(parts[2])) - logTotal;
  const previous = best.get(parts[1]);
  if (previous === undefined || score > previous) {
    best.set(parts[1], score);
  }
}

function segment(chunk) {
  const chars = Array.from(chunk);
  const n = chars.length;
  const score = new Array(n + 1).fill(Number.NEGATIVE_INFINITY);
  const back = new Array(n + 1).fill(-1);
  score[0] = 0;
  for (let i = 0; i < n; i++) {
    if (score[i] === Number.NEGATIVE_INFINITY) {
      continue;
    }
    for (let len = 1; len <= Math.min(MAX_WORD_CHARS, n - i); len++) {
      const word = chars.slice(i, i + len).join('');
      let value = best.get(word);
      if (value === undefined) {
        if (len > 1) {
          continue;
        }
        value = UNKNOWN_CHAR_SCORE;
      }
      const next = score[i] + value + WORD_BONUS_PER_CHAR * (len - 1);
      if (next > score[i + len]) {
        score[i + len] = next;
        back[i + len] = i;
      }
    }
  }
  const words = [];
  let end = n;
  while (end > 0) {
    const start = back[end];
    words.unshift(chars.slice(start, end).join(''));
    end = start;
  }
  return words;
}

const HAN = /[㐀-鿿]+/g;
const counts = new Map();
const chunks = [];
let sentences = 0;
let tokens = 0;
const unknown = new Set();
for (const name of readdirSync(corpusDir).filter((file) => file.endsWith('.txt')).sort()) {
  for (const rawLine of readFileSync(join(corpusDir, name), 'utf8').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.length === 0 || line.startsWith('#')) {
      continue;
    }
    sentences++;
    for (const chunk of line.match(HAN) ?? []) {
      chunks.push(chunk);
      const words = segment(chunk);
      tokens += words.length;
      for (const word of words) {
        if (!best.has(word)) {
          unknown.add(word);
        }
      }
      for (let i = 0; i + 1 < words.length; i++) {
        const key = `${words[i]}\t${words[i + 1]}`;
        counts.set(key, (counts.get(key) ?? 0) + 1);
      }
    }
  }
}

// 评测句子不能出现在训练语料里
const leaks = [];
for (const rawLine of readFileSync(benchPath, 'utf8').split(/\r?\n/)) {
  if (rawLine.length === 0 || rawLine.startsWith('#')) {
    continue;
  }
  const sentence = rawLine.split('\t')[0];
  if (chunks.some((chunk) => chunk.includes(sentence))) {
    leaks.push(sentence);
  }
}
for (const sentence of leaks) {
  console.log(`提醒 评测句子出现在语料里：${sentence}`);
}
if (unknown.size > 0) {
  console.log(`提醒 词库里没有的单字：${Array.from(unknown).join('')}`);
}

const rows = Array.from(counts.entries()).sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
const out = [
  '# 词间搭配表，由 tools/build-bigram.mjs 从 tools/lexicon-src/corpus 生成，请勿手工修改。',
  `# sentences=${sentences} tokens=${tokens} pairs=${rows.length}`
];
for (const [key, count] of rows) {
  out.push(`${key}\t${count}`);
}
const output = out.join('\n') + '\n';
writeFileSync(outPath, output, 'utf8');
const sha256 = createHash('sha256').update(output, 'utf8').digest('hex');
console.log(`sentences=${sentences} tokens=${tokens} pairs=${rows.length} leaks=${leaks.length} ` +
  `bytes=${Buffer.byteLength(output, 'utf8')} sha256=${sha256}`);
