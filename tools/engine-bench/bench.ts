// 拼音引擎离线评测。词语样本固定在 words.txt，整句样本在 sentences.txt，两份都不参与词库与二元模型的生成。
// 误触按“手指落在邻键正中”与“落在两键交界附近”两档模拟；另有相邻字母互换、多打一个字母、漏打一个字母三类打错。
// 只在 Node 下运行，这里手写少量声明，省去 @types/node 依赖
declare const require: (name: string) => any;
declare const process: { argv: string[] };
declare const console: { log: (message: string) => void };
const fs = require('fs');

import { Lexicon } from './Lexicon';
import { PinyinEngine } from './PinyinEngine';
import { Candidate, LetterAlternative, QueryOptions } from './EngineTypes';

const TOUCH_SIGMA = 0.42;
const TWO_SIGMA_SQUARED = 2 * TOUCH_SIGMA * TOUCH_SIGMA;
const BASE = 0.8;
const MAX_COST = 5.0;
const MAX_ALTERNATIVES = 4;

interface KeyPos { letter: string; pane: number; x: number; y: number; }
const KEYS: KeyPos[] = [];
function addRow(pane: number, row: number, startX: number, letters: string): void {
  for (let i = 0; i < letters.length; i++) {
    KEYS.push({ letter: letters.charAt(i), pane: pane, x: startX + i + 0.5, y: row + 0.5 });
  }
}
addRow(0, 0, 0, 'qwert');
addRow(0, 1, 0.5, 'asdfg');
addRow(0, 2, 1.5, 'zxcv');
addRow(1, 0, 0, 'yuiop');
addRow(1, 1, -0.5, 'ghjkl');
addRow(1, 2, 0.5, 'bnm');

function keyOf(letter: string): KeyPos | undefined {
  return KEYS.find((k) => k.letter === letter);
}

// 按实际按下的那个按键计算邻键。G 在左右两个键区各有一个，按键不同，邻键也不同
function alternativesAt(hit: KeyPos | undefined, px: number, py: number): LetterAlternative[] {
  if (hit === undefined) {
    return [];
  }
  const distance = (k: KeyPos): number => (px - k.x) * (px - k.x) + (py - k.y) * (py - k.y);
  const hitDistance = distance(hit);
  const list: LetterAlternative[] = [];
  for (const k of KEYS) {
    if (k.pane !== hit.pane || k.letter === hit.letter) {
      continue;
    }
    const cost = BASE + Math.max(0, distance(k) - hitDistance) / TWO_SIGMA_SQUARED;
    if (cost <= MAX_COST) {
      list.push({ letter: k.letter, cost: cost });
    }
  }
  list.sort((a, b) => a.cost - b.cost);
  return list.slice(0, MAX_ALTERNATIVES);
}

function centerAlternatives(letter: string): LetterAlternative[] {
  const hit = keyOf(letter);
  return hit === undefined ? [] : alternativesAt(hit, hit.x, hit.y);
}

const lexPath: string = process.argv[2];
const label: string = process.argv[3] ?? '';
const benchDir: string = process.argv[4] ?? '.';
const bigramPath: string = process.argv[5] ?? '';
const text: string = fs.readFileSync(lexPath, 'utf-8');
const lexicon = new Lexicon();
lexicon.loadFromText(text);
const engine = new PinyinEngine(lexicon);
if (bigramPath.length > 0 && fs.existsSync(bigramPath)) {
  const module = require('./BigramModel');
  const model = new module.BigramModel();
  model.loadFromText(fs.readFileSync(bigramPath, 'utf-8'));
  engine.setBigramModel(model);
}

interface Row { syllables: string[]; word: string; }

function readRows(path: string, textFirst: boolean): Row[] {
  const rows: Row[] = [];
  for (const line of (fs.readFileSync(path, 'utf-8') as string).split('\n')) {
    if (line.length === 0 || line.startsWith('#')) {
      continue;
    }
    const parts = line.trim().split('\t');
    if (parts.length !== 2) {
      continue;
    }
    const word = textFirst ? parts[0] : parts[1];
    const syllables = (textFirst ? parts[1] : parts[0]).split(' ');
    if (Array.from(word).length !== syllables.length) {
      console.log(`跳过音节数与字数不符的样本：${word}`);
      continue;
    }
    rows.push({ syllables: syllables, word: word });
  }
  return rows;
}

const words = readRows(`${benchDir}/words.txt`, false);
const sentences = readRows(`${benchDir}/sentences.txt`, true);

interface Case { code: string; options: QueryOptions; }
interface Result { first: number; top3: number; total: number; chars: number; charTotal: number; ms: number; }

function pct(n: number, total: number): string {
  return total > 0 ? `${((n / total) * 100).toFixed(1)}%` : '-';
}

function seedOf(word: string): number {
  let seed = 0;
  for (let i = 0; i < word.length; i++) {
    seed = (seed * 31 + word.charCodeAt(i)) % 9973;
  }
  return seed;
}

// 首位候选与目标逐字比对，统计字准确率
function matchedChars(candidate: Candidate | undefined, target: string): number {
  if (candidate === undefined) {
    return 0;
  }
  const a = Array.from(candidate.text);
  const b = Array.from(target);
  let count = 0;
  for (let i = 0; i < Math.min(a.length, b.length); i++) {
    if (a[i] === b[i]) {
      count++;
    }
  }
  return count;
}

function measure(rows: Row[], build: (r: Row) => Case | undefined): Result {
  const result: Result = { first: 0, top3: 0, total: 0, chars: 0, charTotal: 0, ms: 0 };
  const start = Date.now();
  for (const row of rows) {
    const made = build(row);
    if (made === undefined) {
      continue;
    }
    result.total++;
    const list = engine.query(made.code, '', 60, made.options);
    const rank = list.findIndex((c) => c.text === row.word);
    if (rank === 0) {
      result.first++;
    }
    if (rank >= 0 && rank < 3) {
      result.top3++;
    }
    result.chars += matchedChars(list[0], row.word);
    result.charTotal += Array.from(row.word).length;
  }
  result.ms = Date.now() - start;
  return result;
}

function plainCase(code: string): Case {
  const alts: LetterAlternative[][] = [];
  for (let i = 0; i < code.length; i++) {
    alts.push(centerAlternatives(code.charAt(i)));
  }
  return { code: code, options: { fuzzy: false, alternatives: alts } };
}

// 误触：把第 p 个字母换成同一键区里最近的邻键，落点分两档
function typoCase(row: Row, edgeTap: boolean): Case | undefined {
  const code = row.syllables.join('');
  const p = seedOf(row.word) % code.length;
  const intended = keyOf(code.charAt(p));
  if (intended === undefined) {
    return undefined;
  }
  let nearest: KeyPos | undefined = undefined;
  let best = Number.MAX_VALUE;
  for (const k of KEYS) {
    if (k.pane !== intended.pane || k.letter === intended.letter) {
      continue;
    }
    const d = (k.x - intended.x) * (k.x - intended.x) + (k.y - intended.y) * (k.y - intended.y);
    if (d < best) {
      best = d;
      nearest = k;
    }
  }
  if (nearest === undefined) {
    return undefined;
  }
  const typed = code.substring(0, p) + nearest.letter + code.substring(p + 1);
  // 落点：edgeTap 为两键交界靠误触键一侧，否则为误触键正中
  const px = edgeTap ? (nearest.x + intended.x) / 2 + (nearest.x - intended.x) * 0.15 : nearest.x;
  const py = edgeTap ? (nearest.y + intended.y) / 2 + (nearest.y - intended.y) * 0.15 : nearest.y;
  const alts: LetterAlternative[][] = [];
  for (let i = 0; i < typed.length; i++) {
    alts.push(i === p ? alternativesAt(nearest, px, py) : centerAlternatives(typed.charAt(i)));
  }
  return { code: typed, options: { fuzzy: false, alternatives: alts } };
}

// 在第 k 个音节内部做一次打错，edit 返回改动后的音节，不适用时返回 undefined
function syllableEdit(row: Row, edit: (syllable: string, seed: number) => string | undefined): Case | undefined {
  const seed = seedOf(row.word);
  for (let shift = 0; shift < row.syllables.length; shift++) {
    const k = (seed + shift) % row.syllables.length;
    const changed = edit(row.syllables[k], seed);
    if (changed !== undefined) {
      const typed = row.syllables.slice(0, k).concat([changed]).concat(row.syllables.slice(k + 1)).join('');
      return plainCase(typed);
    }
  }
  return undefined;
}

function swapEdit(syllable: string, seed: number): string | undefined {
  const spots: number[] = [];
  for (let i = 0; i + 1 < syllable.length; i++) {
    if (syllable.charAt(i) !== syllable.charAt(i + 1)) {
      spots.push(i);
    }
  }
  if (spots.length === 0) {
    return undefined;
  }
  const i = spots[seed % spots.length];
  return syllable.substring(0, i) + syllable.charAt(i + 1) + syllable.charAt(i) + syllable.substring(i + 2);
}

function extraEdit(syllable: string, seed: number): string | undefined {
  const i = seed % syllable.length;
  return syllable.substring(0, i + 1) + syllable.charAt(i) + syllable.substring(i + 1);
}

function missingEdit(syllable: string, seed: number): string | undefined {
  if (syllable.length < 3) {
    return undefined;
  }
  const i = 1 + seed % (syllable.length - 1);
  return syllable.substring(0, i) + syllable.substring(i + 1);
}

const full = measure(words, (r) => plainCase(r.syllables.join('')));
const abbr = measure(words, (r) => plainCase(r.syllables.map((s) => s.charAt(0)).join('')));
const typoEdge = measure(words, (r) => typoCase(r, true));
const typoCenter = measure(words, (r) => typoCase(r, false));
const swap = measure(words, (r) => syllableEdit(r, swapEdit));
const extra = measure(words, (r) => syllableEdit(r, extraEdit));
const missing = measure(words, (r) => syllableEdit(r, missingEdit));
const sentence = measure(sentences, (r) => plainCase(r.syllables.join('')));
// 奇数行用于调参，偶数行留作验证，调参时只看调参半边，汇报时看验证半边
const tuneHalf = measure(sentences.filter((r, i) => i % 2 === 0), (r) => plainCase(r.syllables.join('')));
const checkHalf = measure(sentences.filter((r, i) => i % 2 === 1), (r) => plainCase(r.syllables.join('')));

const pair = (r: Result): string => `${pct(r.first, r.total)}/${pct(r.top3, r.total)}`;
console.log(`${label}`);
console.log(`  词语 全拼 ${pair(full)}  简拼 ${pair(abbr)}  误触-交界 ${pair(typoEdge)}  误触-正中 ${pair(typoCenter)}`);
console.log(`  打错 互换 ${pair(swap)}  多打 ${pair(extra)}  漏打 ${pair(missing)}`);
console.log(`  整句 ${sentences.length} 句 首位 ${pair(sentence)}  字准确率 ${pct(sentence.chars, sentence.charTotal)}` +
  `  调参半边 ${pct(tuneHalf.first, tuneHalf.total)}  验证半边 ${pct(checkHalf.first, checkHalf.total)}`);
const totalMs = [full, abbr, typoEdge, typoCenter, swap, extra, missing, sentence].reduce((s, r) => s + r.ms, 0);
console.log(`  用时 ${totalMs}ms，其中整句 ${sentence.ms}ms`);

// 传入 --dump 时列出整句首位不对的句子，便于逐句检查
if (process.argv.indexOf('--dump') >= 0) {
  for (const row of sentences) {
    const made = plainCase(row.syllables.join(''));
    const list = engine.query(made.code, '', 60, made.options);
    if (list.length === 0 || list[0].text !== row.word) {
      console.log(`  ✗ ${row.word} → ${list.length > 0 ? list[0].text : '（无）'}`);
    }
  }
}
