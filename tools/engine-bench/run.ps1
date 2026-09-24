# 拼音引擎离线评测：把 entry 下的引擎源码复制成 TypeScript，用 DevEco 自带的 tsc 编译后跑一遍指标。
# 指标见 bench.ts 开头的说明，每项给出目标排在首位与前三位的比例。
# 用法：powershell -ExecutionPolicy Bypass -File tools\engine-bench\run.ps1 [-Label 名称] [-NoBigram] [-Dump]
#   对比别的版本时，用 -EngineDir 指向另一份引擎源码目录，用 -Lexicon 指向另一份词库，不必改动工程里的文件
param([string]$Label = '当前参数', [switch]$NoBigram, [switch]$Dump, [string]$EngineDir = '', [string]$Lexicon = '')

$ErrorActionPreference = 'Stop'
$deveco = 'D:\HUAWEI\DevEco Studio'
$node = Join-Path $deveco 'tools\node\node.exe'
$tsc = Join-Path $deveco 'tools\ohpm\node_modules\typescript\lib\tsc.js'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$engine = if ($EngineDir -ne '') { $EngineDir } else { Join-Path $root 'entry\src\main\ets\engine' }
$lexicon = if ($Lexicon -ne '') { $Lexicon } else { Join-Path $root 'entry\src\main\resources\rawfile\lexicon\base_lexicon.txt' }
$bigram = Join-Path $root 'entry\src\main\resources\rawfile\lexicon\bigram.txt'
$work = Join-Path $PSScriptRoot 'build'

if (Test-Path (Join-Path $work 'src')) {
  Remove-Item -Recurse -Force (Join-Path $work 'src')
}
New-Item -ItemType Directory -Force -Path (Join-Path $work 'src') | Out-Null
foreach ($name in @('EngineTypes', 'Lexicon', 'PinyinSyllables', 'FuzzyPinyin', 'PinyinSegmenter', 'PinyinEngine',
    'BigramModel')) {
  $source = Join-Path $engine "$name.ets"
  if (Test-Path $source) {
    Copy-Item $source (Join-Path $work "src\$name.ts") -Force
  }
}
Copy-Item (Join-Path $PSScriptRoot 'bench.ts') (Join-Path $work 'src\bench.ts') -Force

@'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "CommonJS",
    "outDir": "out",
    "strict": false,
    "skipLibCheck": true,
    "lib": ["ES2020"],
    "esModuleInterop": true
  },
  "include": ["src/**/*.ts"]
}
'@ | Set-Content -Path (Join-Path $work 'tsconfig.json') -Encoding UTF8

$bigramArg = if ($NoBigram) { '' } else { $bigram }
$extra = @()
if ($Dump) { $extra += '--dump' }
Push-Location $work
try {
  & $node $tsc -p tsconfig.json
  & $node 'out/bench.js' $lexicon $Label $PSScriptRoot $bigramArg @extra
} finally {
  Pop-Location
}
