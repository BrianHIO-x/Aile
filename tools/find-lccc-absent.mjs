// 找出 LCCC 训练部分原文里一次都没出现过的词，写到 tools/lexicon-src/external/lccc_absent.tsv。
// 用法：在 count-lccc.mjs 之后执行 node --max-old-space-size=3000 tools/find-lccc-absent.mjs
// LCCC 清洗时整句删掉了含“操、靠、草、滚”等字的对话，“微信、红包、转账”这类词也当作广告过滤掉了。
// 切词计数为 0 的词有两种：原文里根本没有（被过滤），或者原文里有、只是总被切成更短的词（如“送我”）。
// 这里按原文子串逐个核对，只列出前一种，build-lexicon.mjs 对它们改用其他来源估计词频。
import { createReadStream, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { codePoints, externalDir, requireExternal, WordTrie } from './lexicon-lib.mjs';

const segmented = new Set();
for (const line of readFileSync(requireExternal('lccc_unigram.tsv'), 'utf8').split('\n')) {
  const tab = line.indexOf('\t');
  if (tab > 0 && !line.startsWith('#')) {
    segmented.add(line.substring(0, tab));
  }
}
const words = [];
const trie = new WordTrie();
for (const line of readFileSync(requireExternal('vocab.tsv'), 'utf8').split('\n')) {
  const word = line.substring(0, line.indexOf('\t'));
  if (word.length > 0 && !segmented.has(word)) {
    trie.add(word, words.length);
    words.push(word);
  }
}
const seen = new Uint8Array(words.length);
const reader = createInterface({ input: createReadStream(requireExternal('lccc_train.txt')), crlfDelay: Infinity });
for await (const line of reader) {
  const codes = codePoints(line);
  for (let i = 0; i < codes.length; i++) {
    let node = 0;
    for (let j = i; j < codes.length; j++) {
      const next = trie.children.get(node * 0x110000 + codes[j]);
      if (next === undefined) {
        break;
      }
      node = next;
      const id = trie.wordAt[node];
      if (id >= 0) {
        seen[id] = 1;
      }
    }
  }
}
const absent = words.filter((word, id) => seen[id] === 0);
writeFileSync(join(externalDir, 'lccc_absent.tsv'), absent.join('\n') + '\n');
console.log(`checked=${words.length} absent=${absent.length}`);
