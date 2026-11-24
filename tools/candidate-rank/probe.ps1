# 候选排序探针：只在本目录的 build\probe 下编译引擎源码，打印候选池供排序规则设计使用。
$ErrorActionPreference = 'Stop'
$deveco = 'D:\HUAWEI\DevEco Studio'
$node = Join-Path $deveco 'tools\node\node.exe'
$tsc = Join-Path $deveco 'tools\ohpm\node_modules\typescript\lib\tsc.js'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$engine = Join-Path $root 'entry\src\main\ets\engine'
$lexicon = Join-Path $root 'entry\src\main\resources\rawfile\lexicon\base_lexicon.txt'
$bigram = Join-Path $root 'entry\src\main\resources\rawfile\lexicon\bigram.txt'
$stage = Join-Path $PSScriptRoot 'build\probe'

if (Test-Path $stage) {
  Remove-Item -Recurse -Force $stage
}
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'src') | Out-Null
foreach ($name in @('EngineTypes', 'Lexicon', 'PinyinSyllables', 'FuzzyPinyin', 'PinyinSegmenter', 'PinyinEngine', 'BigramModel')) {
  Copy-Item (Join-Path $engine "$name.ets") (Join-Path $stage "src\$name.ts") -Force
}
Copy-Item (Join-Path $PSScriptRoot 'probe.ts') (Join-Path $stage 'src\probe.ts') -Force
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
  & $node 'out/probe.js' $lexicon $bigram
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
