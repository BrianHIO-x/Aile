// 下载生成词库所需的外部原始数据，全部为 MIT 许可，存放在 tools/lexicon-src/external（不入库）。
// 用法：使用 DevEco 自带 Node 执行 node tools/fetch-lexicon-sources.mjs
// 已存在且校验通过的文件不会重复下载。每个文件固定到某一次提交，校验值不符时报错退出。
// 下载交给系统自带的 curl，跟随本机的代理与域名解析设置。
//   jieba           词表与词频                 https://github.com/fxsjy/jieba
//   phrase-pinyin   词语读音（含多音字词）       https://github.com/mozillazg/phrase-pinyin-data
//   pinyin-data     单字读音                   https://github.com/mozillazg/pinyin-data
//   THUOCL          清华大学开放中文词库         https://github.com/thunlp/THUOCL
//   LCCC            清华大学 LCCC 中文对话语料    https://github.com/thu-coai/CDial-GPT
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
export const externalDir = join(root, 'tools', 'lexicon-src', 'external');

const JIEBA = 'https://raw.githubusercontent.com/fxsjy/jieba/67fa2e36e72f69d9134b8a1037b83fbb070b9775';
const PHRASE = 'https://raw.githubusercontent.com/mozillazg/phrase-pinyin-data/cee0ed6e6e4898580cafd2bd5e3723e20b214aa0';
const CHARS = 'https://raw.githubusercontent.com/mozillazg/pinyin-data/923b108dc5d45dee061324c011b478fb649f8b73';
const THUOCL = 'https://raw.githubusercontent.com/thunlp/THUOCL/a30ce79d895d01ab5132a5c74c29703ff7efb4cc/data';
const LCCC = 'https://huggingface.co/datasets/silver/lccc/resolve/5bd582fa28cd7143f2f9c852e08e23089d677c44';

const THUOCL_FILES = ['IT', 'animal', 'caijing', 'car', 'chengyu', 'diming', 'food', 'law', 'lishimingren', 'medical',
  'poem'];

const THUOCL_SHA256 = {
  IT: 'e8cd42c9f5559735fa3bfb91515cbe051f991efd4a803038a1d5c0da85af3526',
  animal: 'bcdc95a32fe713d4bc32957ae26174e3b464908e318e821c9abb295e90249145',
  caijing: '68e63d2009e59c6f388eeaa789d19b6a681657de3e8e56cc3479b21cd8548542',
  car: '58ffd756b89e8574852bc72c254276a1d7fa8821342eb3cbf3be73ca33ab921c',
  chengyu: 'c339d5d6e37d4f8ecdcb82f2a02b7fdfc66796f0a5215155f2aff8a77e89a7eb',
  diming: 'ca5574399da5750a2c36dc373f36e31a66ed1f8a4b21646df6ca44ec0b888d89',
  food: '084caa96ad4f976720003e9420097ba7cb5ddbb17f9f8c8f76bc4b8e0cc777fd',
  law: '8ef1a5f41052ac95dedde88b167c5031a43b3e0211bf128b6125736cc76ef7b2',
  lishimingren: 'd0e5094016e6db8c55d363dc022f48f7b1753cf6d07e216f63cf522ce8e53605',
  medical: 'a01f39f1677af0b6a620bbc68bf293e8e436f06248b74adb625cd61d9ad7bbcd',
  poem: 'f7045571f57114a3a70d2eaaeec8f991897d536be808f93161709f1289c8108c'
};

// 文件名 → [地址, sha256]
export const SOURCES = [
  ['jieba_dict.txt', `${JIEBA}/jieba/dict.txt`, '7197c3211ddd98962b036cdf40324d1ea2bfaa12bd028e68faa70111a88e12a8'],
  ['phrase_pinyin.txt', `${PHRASE}/pinyin.txt`, 'dcc769607c220b312fea3e71cb63421298b4b891b1f7356a95ab58f2c96fff81'],
  ['phrase_large_pinyin.txt', `${PHRASE}/large_pinyin.txt`, '4cf565635a092f3911a7f560fc604aa1a05c95a121488fb28562f3dd2d1441f7'],
  ['char_pinyin.txt', `${CHARS}/pinyin.txt`, '621f8ca9eff8519f47e2b17b564fd318161e13bca07eea8c8e04993cd5d3b52e'],
  ...THUOCL_FILES.map((name) => [`thuocl/THUOCL_${name}.txt`, `${THUOCL}/THUOCL_${name}.txt`, THUOCL_SHA256[name]]),
  ['lccc_base_train.jsonl.gz', `${LCCC}/lccc_base_train.jsonl.gz`, '2162e0ed923fba62329cabf7e1493fbe59248afc94a62508e4abdea61e624627']
];

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function fetchOne(name, url, expected) {
  const path = join(externalDir, name);
  if (existsSync(path) && (expected === '' || sha256(path) === expected)) {
    console.log(`已有 ${name}`);
    return;
  }
  mkdirSync(dirname(path), { recursive: true });
  const partial = `${path}.part`;
  execFileSync('curl', ['-fsSL', '--retry', '3', '-o', partial, url], { stdio: 'inherit' });
  const actual = sha256(partial);
  if (expected !== '' && actual !== expected) {
    throw new Error(`${name} 校验值不符 ${actual}`);
  }
  renameSync(partial, path);
  console.log(`下载 ${name} bytes=${readFileSync(path).length} sha256=${actual}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  for (const [name, url, expected] of SOURCES) {
    fetchOne(name, url, expected);
  }
}
