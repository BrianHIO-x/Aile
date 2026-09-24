// 生成输入法使用的 UTF-8 紧凑词库：AOSP PinyinIME 的 UTF-16 原始词库，加上 tools/lexicon-src/aile-words 下本项目自己整理的常用词。
// 用法：使用 DevEco 自带 Node 执行 node tools/build-lexicon.mjs [--notes]
//   --notes 另外列出多音字取了非常用读音的词条，供人工复核。
// 输出格式（输入法启动时只读索引，每个桶第一次查询时才解析）：
//   首行  "#aile-lexicon<TAB>2<TAB>词频总和<TAB>条目数<TAB>索引行数<TAB>最多音节数<TAB>最小对数概率"
//   索引  每行 "索引键<TAB>起点<TAB>长度"，起点与长度按 UTF-16 码元计，相对数据段开头。
//         索引键为各音节首字母，n、r 记作 l，f 记作 h，与 entry/src/main/ets/engine/Lexicon.ets 的 keyLetter 一致。
//         全部键的前缀也各占一行，只是前缀时长度为 0，引擎据此剪枝
//   "#data" 一行之后为数据段，按索引键分桶，桶内每行 "音节(空格分隔)<TAB>词<TAB>整数词频"，按词频从高到低排列。
//         对数概率等于 ln(词频) - ln(词频总和)，引擎解析一个桶时才计算
//
// 常用词文件格式：每行“词 音节 音节 …”，音节数必须等于字数，ü 写作 v。
//   @5 ～ @1  之后的词按等级给词频，已有的词取两者中较大的词频
//   @set N   之后的词词频强制设为 N
//   @remove  之后的词从词库中删除，写法须与词库完全一致
//   # 开头为注释
import { createHash } from 'node:crypto';
import { copyFileSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const sourcePath = join(root, 'tools', 'lexicon-src', 'rawdict_utf16_65105_freq.txt');
const noticePath = join(root, 'tools', 'lexicon-src', 'NOTICE-AOSP-PinyinIME.txt');
const wordsDir = join(root, 'tools', 'lexicon-src', 'aile-words');
const syllablesPath = join(root, 'entry', 'src', 'main', 'ets', 'engine', 'PinyinSyllables.ets');
const outDir = join(root, 'entry', 'src', 'main', 'resources', 'rawfile', 'lexicon');
const outPath = join(outDir, 'base_lexicon.txt');

const EXPECTED_SOURCE_BYTES = 3570346;
const SYLLABLE_PATTERN = /^[a-z]{1,6}$/;
const MAX_SYLLABLES = 8;
// 常用词等级对应的词频。基础词库里“手机”约 3.8 万，“快递”约 5900，“截图”约 2500
const TIER_FREQ = { 5: 30000, 4: 10000, 3: 3000, 2: 1000, 1: 300 };
const showNotes = process.argv.includes('--notes');

// ---------- AOSP 原始词库 ----------

const buffer = readFileSync(sourcePath);
if (buffer.length !== EXPECTED_SOURCE_BYTES) {
  throw new Error(`unexpected source size ${buffer.length}`);
}
const text = buffer.toString('utf16le').replace(/^﻿/, '');

const merged = new Map();
let skipped = 0;
for (const rawLine of text.split(/\r?\n/)) {
  const line = rawLine.trim();
  if (line.length === 0) {
    continue;
  }
  const parts = line.split(/\s+/);
  if (parts.length < 4) {
    skipped++;
    continue;
  }
  const word = parts[0];
  const freq = Number(parts[1]);
  const syllables = parts.slice(3);
  const wordLength = Array.from(word).length;
  if (!Number.isFinite(freq) || freq < 0 || syllables.length !== wordLength || syllables.length > MAX_SYLLABLES ||
    !syllables.every((s) => SYLLABLE_PATTERN.test(s))) {
    skipped++;
    continue;
  }
  const key = `${syllables.join(' ')}\t${word}`;
  const previous = merged.get(key) ?? 0;
  merged.set(key, Math.max(previous, freq));
}

// 单字读音表：字 → {读音 → 词频}，用来核对常用词里每个字的读音
const charReadings = new Map();
const wordReadings = new Map();
for (const [key, freq] of merged) {
  const [syllables, word] = key.split('\t');
  const chars = Array.from(word);
  if (chars.length === 1) {
    const readings = charReadings.get(word) ?? new Map();
    readings.set(syllables, Math.max(readings.get(syllables) ?? 0, freq));
    charReadings.set(word, readings);
  }
  const list = wordReadings.get(word) ?? [];
  list.push(syllables);
  wordReadings.set(word, list);
}

// ---------- 本项目整理的常用词 ----------

const syllableSource = readFileSync(syllablesPath, 'utf8');
const standardBlock = syllableSource.match(/STANDARD_SYLLABLES: string\[\] = \[([\s\S]*?)\];/);
const standaloneBlock = syllableSource.match(/STANDALONE_SYLLABLES: string\[\] = \[([\s\S]*?)\];/);
const validSyllables = new Set();
for (const block of [standardBlock, standaloneBlock]) {
  for (const match of block[1].matchAll(/'([a-z]+)'/g)) {
    validSyllables.add(match[1]);
  }
}

const errors = [];
const warnings = [];
const notes = [];
const seen = new Map();
let added = 0;
let raised = 0;
let forced = 0;
let removed = 0;

const files = readdirSync(wordsDir).filter((name) => name.endsWith('.txt')).sort();
for (const name of files) {
  const lines = readFileSync(join(wordsDir, name), 'utf8').split(/\r?\n/);
  let mode = { kind: 'tier', freq: 0 };
  lines.forEach((rawLine, index) => {
    const where = `${name}:${index + 1}`;
    const line = rawLine.trim();
    if (line.length === 0 || line.startsWith('#')) {
      return;
    }
    if (line.startsWith('@')) {
      const directive = line.substring(1).trim().split(/\s+/);
      if (directive[0] === 'remove') {
        mode = { kind: 'remove', freq: 0 };
      } else if (directive[0] === 'set') {
        mode = { kind: 'set', freq: Number(directive[1]) };
      } else if (TIER_FREQ[directive[0]] !== undefined) {
        mode = { kind: 'tier', freq: TIER_FREQ[directive[0]] };
      } else {
        errors.push(`${where} 无法识别的指令 ${line}`);
      }
      return;
    }
    if (mode.kind === 'tier' && mode.freq === 0) {
      errors.push(`${where} 词条前缺少等级指令`);
      return;
    }
    const parts = line.split(/\s+/);
    const word = parts[0];
    const syllables = parts.slice(1);
    const chars = Array.from(word);
    if (syllables.length !== chars.length) {
      errors.push(`${where} 音节数与字数不符：${line}`);
      return;
    }
    const badSyllable = syllables.find((s) => !validSyllables.has(s));
    if (badSyllable !== undefined) {
      errors.push(`${where} 不是合法音节 ${badSyllable}：${line}`);
      return;
    }
    const key = `${syllables.join(' ')}\t${word}`;
    if (mode.kind === 'remove') {
      if (merged.delete(key)) {
        removed++;
      } else {
        warnings.push(`${where} 要删除的词条不在词库里：${line}`);
      }
      return;
    }
    if (seen.has(key)) {
      warnings.push(`${where} 与 ${seen.get(key)} 重复：${word}`);
    }
    seen.set(key, where);
    chars.forEach((ch, i) => {
      const readings = charReadings.get(ch);
      if (readings === undefined) {
        warnings.push(`${where} 单字词条里没有“${ch}”：${word}`);
        return;
      }
      if (!readings.has(syllables[i])) {
        warnings.push(`${where} “${ch}”没有 ${syllables[i]} 这个读音（已知 ${Array.from(readings.keys()).join('/')}）：${word}`);
        return;
      }
      if (readings.size > 1 && chars.length > 1) {
        let top = '';
        let topFreq = -1;
        for (const [reading, freq] of readings) {
          if (freq > topFreq) {
            top = reading;
            topFreq = freq;
          }
        }
        if (top !== syllables[i]) {
          notes.push(`${where} ${word} 的“${ch}”读 ${syllables[i]}（常用读音 ${top}）`);
        }
      }
    });
    const known = wordReadings.get(word);
    if (known !== undefined && !known.includes(syllables.join(' '))) {
      warnings.push(`${where} 基础词库里“${word}”读作 ${known.join(' / ')}，这里写成 ${syllables.join(' ')}`);
    }
    const previous = merged.get(key);
    if (mode.kind === 'set') {
      merged.set(key, mode.freq);
      forced++;
    } else if (previous === undefined) {
      merged.set(key, mode.freq);
      added++;
    } else if (previous < mode.freq) {
      merged.set(key, mode.freq);
      raised++;
    }
  });
}

for (const message of errors) {
  console.log(`错误 ${message}`);
}
for (const message of warnings) {
  console.log(`提醒 ${message}`);
}
if (showNotes) {
  for (const message of notes) {
    console.log(`复核 ${message}`);
  }
}
if (errors.length > 0) {
  process.exit(1);
}

// ---------- 输出 ----------

const rows = Array.from(merged.entries()).map(([key, freq]) => {
  const [syllables, word] = key.split('\t');
  return { syllables, word, freq: Math.max(1, Math.round(freq)) };
});

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
  const parts = row.syllables.split(' ');
  const key = parts.map(keyLetter).join('');
  minLogProb = Math.min(minLogProb, Math.round((Math.log(row.freq) - logTotal) * 10000) / 10000);
  maxSyllables = Math.max(maxSyllables, parts.length);
  const bucket = buckets.get(key) ?? [];
  bucket.push(row);
  buckets.set(key, bucket);
}
const slots = new Map();
let data = '';
for (const key of Array.from(buckets.keys()).sort()) {
  const bucket = buckets.get(key);
  bucket.sort((a, b) => b.freq - a.freq || (a.syllables < b.syllables ? -1 : a.syllables > b.syllables ? 1 : 0) ||
    (a.word < b.word ? -1 : a.word > b.word ? 1 : 0));
  const start = data.length;
  for (const row of bucket) {
    data += `${row.syllables}\t${row.word}\t${row.freq}\n`;
  }
  slots.set(key, [start, data.length - start]);
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
const output = lines.join('\n') + '\n' + data;

mkdirSync(outDir, { recursive: true });
writeFileSync(outPath, output, 'utf8');
copyFileSync(noticePath, join(outDir, 'NOTICE-AOSP-PinyinIME.txt'));

const bytes = Buffer.byteLength(output, 'utf8');
const sha256 = createHash('sha256').update(output, 'utf8').digest('hex');
console.log(`常用词 新增 ${added} 调高 ${raised} 强制 ${forced} 删除 ${removed}，提醒 ${warnings.length} 条，复核 ${notes.length} 条`);
console.log(`entries=${rows.length} keys=${buckets.size} slots=${slotKeys.length} skipped=${skipped} total=${total} ` +
  `bytes=${bytes} sha256=${sha256}`);
