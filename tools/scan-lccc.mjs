// 第一遍扫描 LCCC 对话语料：拆出训练与留出两部分，统计原语料自带切分的词频和单字频次。
// 用法：node tools/scan-lccc.mjs（约需几分钟）
// 输出到 tools/lexicon-src/external：
//   lccc_train.txt     训练部分的汉字片段，每行一段，标点、字母、数字处断开
//   lccc_heldout.txt   留出部分的原句，每 100 段对话取 1 段，不参与任何统计，用于评测
//   lccc_tokens.tsv    原语料自带切分的词与次数（只计训练部分，至少出现 3 次），用来发现新词
//   lccc_chars.tsv     训练部分每个汉字的出现次数
import { createReadStream, createWriteStream, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { createGunzip } from 'node:zlib';
import { externalDir, hanChunks, isHanWord, requireExternal } from './lexicon-lib.mjs';

const HELDOUT_EVERY = 100;
const MIN_TOKEN_COUNT = 3;

const input = createReadStream(requireExternal('lccc_base_train.jsonl.gz')).pipe(createGunzip());
const lines = createInterface({ input: input, crlfDelay: Infinity });
const train = createWriteStream(join(externalDir, 'lccc_train.txt'));
const heldout = createWriteStream(join(externalDir, 'lccc_heldout.txt'));
const tokens = new Map();
const charCounts = new Map();
let dialogs = 0;
let utterances = 0;
let hanChars = 0;
let buffer = [];

function flush(force) {
  if (buffer.length >= 4096 || (force && buffer.length > 0)) {
    train.write(buffer.join('\n') + '\n');
    buffer = [];
  }
}

for await (const line of lines) {
  if (line.length === 0) {
    continue;
  }
  const dialog = JSON.parse(line);
  const held = dialogs % HELDOUT_EVERY === 0;
  dialogs++;
  for (const utterance of dialog) {
    utterances++;
    if (held) {
      heldout.write(utterance.replace(/\s+/g, '') + '\n');
      continue;
    }
    for (const token of utterance.split(' ')) {
      if (isHanWord(token)) {
        tokens.set(token, (tokens.get(token) ?? 0) + 1);
      }
    }
    for (const chunk of hanChunks(utterance.replace(/\s+/g, ''))) {
      buffer.push(chunk);
      for (const ch of chunk) {
        charCounts.set(ch, (charCounts.get(ch) ?? 0) + 1);
        hanChars++;
      }
    }
    flush(false);
  }
  if (dialogs % 500000 === 0) {
    console.log(`dialogs=${dialogs} chars=${hanChars} tokens=${tokens.size}`);
  }
}
flush(true);
await new Promise((resolve) => train.end(resolve));
await new Promise((resolve) => heldout.end(resolve));

const tokenRows = Array.from(tokens.entries()).filter(([, count]) => count >= MIN_TOKEN_COUNT)
  .sort((a, b) => b[1] - a[1]);
writeFileSync(join(externalDir, 'lccc_tokens.tsv'),
  tokenRows.map(([word, count]) => `${word}\t${count}`).join('\n') + '\n');
const charRows = Array.from(charCounts.entries()).sort((a, b) => b[1] - a[1]);
writeFileSync(join(externalDir, 'lccc_chars.tsv'), charRows.map(([ch, count]) => `${ch}\t${count}`).join('\n') + '\n');
console.log(`dialogs=${dialogs} utterances=${utterances} hanChars=${hanChars} tokenTypes=${tokenRows.length} ` +
  `charTypes=${charRows.length}`);
