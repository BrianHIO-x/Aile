# 候选排序离线回归：把真实引擎、排序模块与组词控制器编译成 TypeScript，用实际词库跑确定性的排序断言。
# 只写本目录的 build\test，不触碰 tools\engine-bench\build 与 tools\frontend-regress\build。
$ErrorActionPreference = 'Stop'
$deveco = 'D:\HUAWEI\DevEco Studio'
$node = Join-Path $deveco 'tools\node\node.exe'
$tsc = Join-Path $deveco 'tools\ohpm\node_modules\typescript\lib\tsc.js'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$engine = Join-Path $root 'entry\src\main\ets\engine'
$ime = Join-Path $root 'entry\src\main\ets\ime'
$lexicon = Join-Path $root 'entry\src\main\resources\rawfile\lexicon\base_lexicon.txt'
$bigram = Join-Path $root 'entry\src\main\resources\rawfile\lexicon\bigram.txt'
$stage = Join-Path $PSScriptRoot 'build\test'

if (Test-Path $stage) {
  Remove-Item -Recurse -Force $stage
}
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'src\engine') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'src\ime') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'src\keyboard') | Out-Null
foreach ($name in @('EngineTypes', 'Lexicon', 'PinyinSyllables', 'FuzzyPinyin', 'PinyinSegmenter', 'PinyinEngine',
    'BigramModel', 'UserLexicon', 'PinyinFilter')) {
  Copy-Item (Join-Path $engine "$name.ets") (Join-Path $stage "src\engine\$name.ts") -Force
}
foreach ($name in @('CandidateRanking', 'CompositionController')) {
  Copy-Item (Join-Path $ime "$name.ets") (Join-Path $stage "src\ime\$name.ts") -Force
}
Copy-Item (Join-Path $PSScriptRoot 'ranking.test.ts') (Join-Path $stage 'src\ranking.test.ts') -Force

@'
export interface CandidateView {
  index: number;
  text: string;
  chars: number;
  id: string;
  consumedCodeLength: number;
  revision: number;
}
'@ | Set-Content -Path (Join-Path $stage 'src\ime\ImeState.ts') -Encoding UTF8

@'
export interface TapSample {
  keyId: string;
  dx: number;
  dy: number;
}

export const NO_TAP: TapSample = { keyId: '', dx: 0, dy: 0 };
'@ | Set-Content -Path (Join-Path $stage 'src\keyboard\TouchModel.ts') -Encoding UTF8

@'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "CommonJS",
    "outDir": "out",
    "rootDir": "src",
    "strict": false,
    "skipLibCheck": true,
    "lib": ["ES2020"],
    "esModuleInterop": true
  },
  "include": ["src/**/*.ts"]
}
'@ | Set-Content -Path (Join-Path $stage 'tsconfig.json') -Encoding UTF8

Push-Location $stage
try {
  & $node $tsc -p tsconfig.json
  if ($LASTEXITCODE -ne 0) { throw "tsc failed with exit code $LASTEXITCODE" }
  & $node 'out/ranking.test.js' $lexicon $bigram
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
