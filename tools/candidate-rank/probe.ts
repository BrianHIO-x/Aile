// 候选排序的探针：打印真实引擎的候选池，按目标输入检查排序前后的顺序与特征。
// 运行：powershell -ExecutionPolicy Bypass -File tools\candidate-rank\probe.ps1
declare const require: (name: string) => any;
declare const process: { argv: string[] };
declare const console: { log: (message: string) => void };
const fs = require('fs');

import { Candidate, CandidateSource, LetterAlternative, QueryOptions } from './EngineTypes';
import { Lexicon } from './Lexicon';
import { BigramModel } from './BigramModel';
import { PinyinEngine } from './PinyinEngine';

function plain(): QueryOptions {
  return { fuzzy: false, alternatives: [] };
}

function nearAlt(code: string): QueryOptions {
  const near: Map<string, string[]> = new Map<string, string[]>();
  near.set('b', ['v', 'n', 'g']);
  near.set('u', ['y', 'i', 'j']);
  near.set('n', ['b', 'm', 'h']);
  near.set('e', ['w', 'r', 'd']);
  near.set('g', ['f', 'h', 'b']);
  near.set('s', ['a', 'd', 'x']);
  near.set('h', ['g', 'j', 'y']);
  near.set('i', ['u', 'o', 'k']);
  near.set('y', ['t', 'u', 'h']);
  near.set('o', ['i', 'p', 'l']);
  near.set('f', ['d', 'g', 'r']);
  near.set('a', ['q', 's', 'z']);
  near.set('z', ['x', 'a', 'c']);
  near.set('j', ['h', 'k', 'u']);
  near.set('l', ['k', 'o', 'p']);
  near.set('m', ['n', 'j', 'k']);
  near.set('t', ['r', 'y', 'g']);
  near.set('w', ['q', 'e', 's']);
  near.set('x', ['z', 'c', 's']);
  near.set('q', ['w', 'a', '1']);
  near.set('r', ['e', 't', 'f']);
  near.set('d', ['s', 'f', 'e']);
  near.set('c', ['x', 'v', 'd']);
  near.set('v', ['c', 'b', 'f']);
  near.set('p', ['o', 'l', '[']);
  near.set('k', ['j', 'l', 'i']);
  const alternatives: LetterAlternative[][] = [];
  for (let i = 0; i < code.length; i++) {
    const letters = near.get(code.charAt(i));
    const list: LetterAlternative[] = [];
    if (letters !== undefined) {
      for (const letter of letters) {
        list.push({ letter: letter, cost: 3.6 });
      }
    }
    alternatives.push(list);
  }
  return { fuzzy: false, alternatives: alternatives };
}

function describe(candidate: Candidate): string {
  const meta = candidate.meta;
  const reading = meta === undefined ? '?' : meta.reading;
  const complete = meta === undefined ? '?' : (meta.complete ? 'C' : 'p');
  const safe = meta === undefined ? '?' : (meta.safeEnd ? 'S' : 'u');
  const exact = meta === undefined ? '?' : String(meta.exactConsumed);
  return candidate.text + '(' + candidate.source + ',c' + candidate.consumedCodeLength + ',syl=' +
    candidate.syllables.join('/') + ',' + reading + ',' + complete + safe + ',x=' + exact +
    ',score=' + candidate.score.toFixed(2) + ')';
}

function show(engine: PinyinEngine, code: string, options: QueryOptions, limit: number = 40): void {
  const list = engine.query(code, '', limit, options);
  console.log('');
  console.log('=== ' + code + ' (' + list.length + ') ===');
  for (let i = 0; i < Math.min(list.length, 24); i++) {
    console.log('  ' + i + ': ' + describe(list[i]));
  }
}

function main(): void {
  const lexiconPath: string = process.argv[2];
  const bigramPath: string = process.argv[3];
  const lexicon = new Lexicon();
  lexicon.loadFromText(fs.readFileSync(lexiconPath, 'utf-8'));
  const engine = new PinyinEngine(lexicon);
  if (bigramPath !== undefined && bigramPath !== '-') {
    const model = new BigramModel();
    model.loadFromText(fs.readFileSync(bigramPath, 'utf-8'));
    engine.setBigramModel(model);
  }
  const codes: string[] = ['nihao', 'shi', 'srf', 'xian', 'xi\'an', 'zhongguo', 'ni\'an',
    'nihaowomenmingtianjian', 'womenmingtianzailianxi', 'nihaoii', 'vvv', 'zhegewentiwomenxiawuzaitaolun',
    'nh', 'jintiantianqihenhao', 'jttqhh', 'tian\'anmen', 'ji'];
  for (const code of codes) {
    show(engine, code, plain(), 60);
  }
  const typo: string[][] = [['bunengg', '不能'], ['shiyongg', '使用'], ['zhnogguo', '中国'], ['xianzai', '现在']];
  for (const item of typo) {
    show(engine, item[0], nearAlt(item[0]), 60);
  }
}

main();
