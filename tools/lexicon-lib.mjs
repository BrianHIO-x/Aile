// 词库构建脚本共用的数据读取：AOSP 原始词库、本项目整理的常用词，以及 fetch-lexicon-sources.mjs 下载的外部数据。
// 读音一律去掉声调，ü 写作 v，lüe、nüe 按词库拼写记作 lue、nue。
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const root = join(dirname(fileURLToPath(import.meta.url)), '..');
export const srcDir = join(root, 'tools', 'lexicon-src');
export const externalDir = join(srcDir, 'external');
export const outDir = join(root, 'entry', 'src', 'main', 'resources', 'rawfile', 'lexicon');

const AOSP_PATH = join(srcDir, 'rawdict_utf16_65105_freq.txt');
const AOSP_BYTES = 3570346;
const SYLLABLES_PATH = join(root, 'entry', 'src', 'main', 'ets', 'engine', 'PinyinSyllables.ets');
export const MAX_SYLLABLES = 8;

// AOSP 原始词库的词频总和，本项目整理的常用词按这个尺度给出等级词频
export const AOSP_TOTAL = 108384826;
export const TIER_FREQ = { 5: 30000, 4: 10000, 3: 3000, 2: 1000, 1: 300 };

export function requireExternal(name) {
  const path = join(externalDir, name);
  if (!existsSync(path)) {
    throw new Error(`缺少 ${name}，请先运行 node tools/fetch-lexicon-sources.mjs`);
  }
  return path;
}

// ---------- 音节 ----------

let syllableSet = undefined;

export function validSyllables() {
  if (syllableSet === undefined) {
    const source = readFileSync(SYLLABLES_PATH, 'utf8');
    syllableSet = new Set();
    for (const name of ['STANDARD_SYLLABLES', 'STANDALONE_SYLLABLES']) {
      const block = source.match(new RegExp(`${name}: string\\[\\] = \\[([\\s\\S]*?)\\];`));
      for (const match of block[1].matchAll(/'([a-z]+)'/g)) {
        syllableSet.add(match[1]);
      }
    }
  }
  return syllableSet;
}

const TONE_MAP = new Map(Object.entries({
  ā: 'a', á: 'a', ǎ: 'a', à: 'a', ē: 'e', é: 'e', ě: 'e', è: 'e', ê: 'e', ế: 'e', ề: 'e',
  ī: 'i', í: 'i', ǐ: 'i', ì: 'i', ō: 'o', ó: 'o', ǒ: 'o', ò: 'o', ū: 'u', ú: 'u', ǔ: 'u', ù: 'u',
  ü: 'v', ǖ: 'v', ǘ: 'v', ǚ: 'v', ǜ: 'v', ń: 'n', ň: 'n', ǹ: 'n', ḿ: 'm', m̀: 'm'
}));

/**
 * 带声调的拼音音节换成词库拼写，不是合法音节时返回 undefined。
 */
export function plainSyllable(text) {
  let out = '';
  for (const ch of text.normalize('NFC').toLowerCase()) {
    if (ch >= 'a' && ch <= 'z') {
      out += ch;
    } else if (TONE_MAP.has(ch)) {
      out += TONE_MAP.get(ch);
    } else if (ch === '̄' || ch === '́' || ch === '̌' || ch === '̀') {
      continue;
    } else {
      return undefined;
    }
  }
  if (out === 'lve') {
    out = 'lue';
  } else if (out === 'nve') {
    out = 'nue';
  }
  return validSyllables().has(out) ? out : undefined;
}

// ---------- 字形 ----------

export function isHan(ch) {
  const code = ch.codePointAt(0);
  return (code >= 0x4e00 && code <= 0x9fff) || (code >= 0x3400 && code <= 0x4dbf);
}

export function isHanWord(word) {
  if (word.length === 0) {
    return false;
  }
  for (const ch of word) {
    if (!isHan(ch)) {
      return false;
    }
  }
  return true;
}

export function chars(word) {
  return Array.from(word);
}

// ---------- AOSP 原始词库 ----------

/**
 * 返回 [{ word, syllables, freq, extended }]，extended 为 GB2312 以外的字。同一词同一读音取较大词频。
 */
export function loadAosp() {
  const buffer = readFileSync(AOSP_PATH);
  if (buffer.length !== AOSP_BYTES) {
    throw new Error(`unexpected AOSP source size ${buffer.length}`);
  }
  const text = buffer.toString('utf16le').replace(/^﻿/, '');
  const merged = new Map();
  for (const rawLine of text.split(/\r?\n/)) {
    const parts = rawLine.trim().split(/\s+/);
    if (parts.length < 4) {
      continue;
    }
    const word = parts[0];
    const freq = Number(parts[1]);
    const syllables = parts.slice(3);
    if (!Number.isFinite(freq) || freq < 0 || syllables.length !== chars(word).length ||
      syllables.length > MAX_SYLLABLES || !syllables.every((s) => validSyllables().has(s))) {
      continue;
    }
    const key = `${syllables.join(' ')}\t${word}`;
    const previous = merged.get(key);
    if (previous === undefined || previous.freq < freq) {
      merged.set(key, { word: word, syllables: syllables.join(' '), freq: freq, extended: parts[2] === '1' });
    }
  }
  return Array.from(merged.values());
}

// ---------- 外部数据 ----------

/**
 * jieba 词表：词 → 词频，只保留全部由汉字组成的词。
 */
export function loadJieba() {
  const result = new Map();
  for (const line of readFileSync(requireExternal('jieba_dict.txt'), 'utf8').split(/\r?\n/)) {
    const parts = line.split(' ');
    if (parts.length < 2 || !isHanWord(parts[0])) {
      continue;
    }
    const freq = Number(parts[1]);
    if (Number.isFinite(freq) && freq > 0) {
      result.set(parts[0], Math.max(result.get(parts[0]) ?? 0, freq));
    }
  }
  return result;
}

/**
 * THUOCL 各领域词表：词 → 文档频率。同一个词出现在几个领域时取最大值。
 */
export function loadThuocl() {
  const result = new Map();
  const dir = requireExternal('thuocl');
  for (const name of readdirSync(dir).filter((file) => file.endsWith('.txt'))) {
    const text = readFileSync(join(dir, name), 'utf8').replace(/^﻿/, '');
    for (const line of text.split(/\r\n|\r|\n/)) {
      const parts = line.trim().split(/\s+/);
      if (parts.length < 2 || !isHanWord(parts[0])) {
        continue;
      }
      const df = Number(parts[parts.length - 1]);
      if (Number.isFinite(df) && df > 0) {
        result.set(parts[0], Math.max(result.get(parts[0]) ?? 0, df));
      }
    }
  }
  return result;
}

function parsePinyinLine(line) {
  if (line.startsWith('#')) {
    return undefined;
  }
  const colon = line.indexOf(':');
  if (colon <= 0) {
    return undefined;
  }
  const word = line.substring(0, colon).trim();
  const hash = line.indexOf('#', colon);
  const syllables = line.substring(colon + 1, hash > 0 ? hash : line.length).trim().split(/\s+/).map(plainSyllable);
  if (!isHanWord(word) || syllables.length !== chars(word).length || syllables.some((s) => s === undefined)) {
    return undefined;
  }
  return { word: word, syllables: syllables.join(' ') };
}

/**
 * phrase-pinyin-data 的词语读音：词 → 读音列表，先列出人工校对的 pinyin.txt，再补充 large_pinyin.txt。
 * curated 标出人工校对过的读音。
 */
export function loadPhrasePinyin() {
  const result = new Map();
  const add = (path, curated) => {
    for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
      const parsed = parsePinyinLine(line);
      if (parsed === undefined) {
        continue;
      }
      const list = result.get(parsed.word) ?? [];
      const existing = list.find((item) => item.syllables === parsed.syllables);
      if (existing === undefined) {
        list.push({ syllables: parsed.syllables, curated: curated });
      }
      result.set(parsed.word, list);
    }
  };
  add(requireExternal('phrase_pinyin.txt'), true);
  add(requireExternal('phrase_large_pinyin.txt'), false);
  return result;
}

/**
 * pinyin-data 的单字读音：字 → 读音列表，按数据里的顺序排列，第一个通常是最常用的读音。
 */
export function loadCharPinyin() {
  const result = new Map();
  for (const line of readFileSync(requireExternal('char_pinyin.txt'), 'utf8').split(/\r?\n/)) {
    const match = line.match(/^U\+([0-9A-F]+):\s*([^#]+)#/);
    if (match === null) {
      continue;
    }
    const ch = String.fromCodePoint(parseInt(match[1], 16));
    if (!isHan(ch)) {
      continue;
    }
    const readings = [];
    for (const item of match[2].trim().split(',')) {
      const syllable = plainSyllable(item.trim());
      if (syllable !== undefined && !readings.includes(syllable)) {
        readings.push(syllable);
      }
    }
    if (readings.length > 0) {
      result.set(ch, readings);
    }
  }
  return result;
}

// ---------- 本项目整理的常用词 ----------

/**
 * 读取 tools/lexicon-src/aile-words，格式见 build-lexicon.mjs 开头的说明。
 * 返回 { rows: [{ where, kind, freq, word, syllables }], errors }，kind 为 tier、set、remove。
 */
export function loadCurated() {
  const wordsDir = join(srcDir, 'aile-words');
  const rows = [];
  const errors = [];
  for (const name of readdirSync(wordsDir).filter((file) => file.endsWith('.txt')).sort()) {
    let mode = { kind: 'tier', freq: 0 };
    readFileSync(join(wordsDir, name), 'utf8').split(/\r?\n/).forEach((rawLine, index) => {
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
      if (syllables.length !== chars(word).length) {
        errors.push(`${where} 音节数与字数不符：${line}`);
        return;
      }
      const bad = syllables.find((s) => !validSyllables().has(s));
      if (bad !== undefined) {
        errors.push(`${where} 不是合法音节 ${bad}：${line}`);
        return;
      }
      rows.push({ where: where, kind: mode.kind, freq: mode.freq, word: word, syllables: syllables.join(' ') });
    });
  }
  return { rows: rows, errors: errors };
}

/**
 * 本项目编写的聊天语料，每行一句或几句，# 开头为注释。
 */
export function loadHandCorpus() {
  const corpusDir = join(srcDir, 'corpus');
  const lines = [];
  for (const name of readdirSync(corpusDir).filter((file) => file.endsWith('.txt')).sort()) {
    for (const rawLine of readFileSync(join(corpusDir, name), 'utf8').split(/\r?\n/)) {
      const line = rawLine.trim();
      if (line.length > 0 && !line.startsWith('#')) {
        lines.push(line);
      }
    }
  }
  return lines;
}

/**
 * 按汉字切出连续的汉字片段，标点、数字、字母与空白都是断点。
 */
export function hanChunks(text) {
  return text.match(/[㐀-䶿一-鿿]+/g) ?? [];
}

// ---------- 切词 ----------

/**
 * 按字建立的词典树，结点编号从 0 开始，子结点存在以“结点编号 × 0x110000 + 码位”为键的表里。
 * 每个结点记一个词编号，-1 表示到这里还不是词。
 */
export class WordTrie {
  constructor() {
    this.children = new Map();
    this.wordAt = [-1];
    this.maxDepth = 0;
  }

  add(word, id) {
    let node = 0;
    let depth = 0;
    for (const ch of word) {
      const key = node * 0x110000 + ch.codePointAt(0);
      let next = this.children.get(key);
      if (next === undefined) {
        next = this.wordAt.length;
        this.wordAt.push(-1);
        this.children.set(key, next);
      }
      node = next;
      depth++;
    }
    this.wordAt[node] = id;
    this.maxDepth = Math.max(this.maxDepth, depth);
  }
}

/**
 * 最大概率切词。codes 为码位数组，score[id] 为词的对数概率，没有收录的单字按 unknownScore 计，
 * 每多一个字加 bonusPerChar。返回词编号数组，没有收录的单字记为 -1 - 码位。
 */
export function segmentCodes(trie, codes, score, unknownScore, bonusPerChar) {
  const n = codes.length;
  const best = new Float64Array(n + 1).fill(-Infinity);
  const back = new Int32Array(n + 1);
  const choice = new Int32Array(n + 1);
  best[0] = 0;
  for (let i = 0; i < n; i++) {
    const base = best[i];
    if (base === -Infinity) {
      continue;
    }
    let node = 0;
    let matchedSingle = false;
    for (let j = i; j < n; j++) {
      const next = trie.children.get(node * 0x110000 + codes[j]);
      if (next === undefined) {
        break;
      }
      node = next;
      const id = trie.wordAt[node];
      if (id >= 0) {
        if (j === i) {
          matchedSingle = true;
        }
        const value = base + score[id] + bonusPerChar * (j - i);
        if (value > best[j + 1]) {
          best[j + 1] = value;
          back[j + 1] = i;
          choice[j + 1] = id;
        }
      }
    }
    if (!matchedSingle) {
      const value = base + unknownScore;
      if (value > best[i + 1]) {
        best[i + 1] = value;
        back[i + 1] = i;
        choice[i + 1] = -1 - codes[i];
      }
    }
  }
  const words = [];
  let end = n;
  while (end > 0) {
    words.push(choice[end]);
    end = back[end];
  }
  words.reverse();
  return words;
}

export function codePoints(text) {
  const codes = [];
  for (const ch of text) {
    codes.push(ch.codePointAt(0));
  }
  return codes;
}
