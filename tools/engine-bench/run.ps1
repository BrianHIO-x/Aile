# 拼音引擎离线评测：把 entry 下的引擎源码复制成 TypeScript，用 DevEco 自带的 tsc 编译后跑一遍指标。
# 指标见 bench.ts 开头的说明，每项给出目标排在首位与前三位的比例。
# 用法：powershell -ExecutionPolicy Bypass -File tools\engine-bench\run.ps1 [-Label 名称] [-NoBigram] [-Dump] [-Regress]
#   对比别的版本时，用 -EngineDir 指向另一份引擎源码目录，用 -Lexicon、-Bigram 指向另一份词库与二元模型，不必改动工程里的文件
#   加上 -Regress 以后不跑指标，改跑 regress.ts 里的确定性回归（候选契约、同末词备选、同音词上下文、原文兜底等）
#   回归单独编译到 build\regress，不覆盖 build\out 里其余的中间产物，日常调参留下的文件不受影响
param([string]$Label = '当前参数', [switch]$NoBigram, [switch]$Dump, [string]$EngineDir = '', [string]$Lexicon = '',
  [string]$Bigram = '', [switch]$Regress)

$ErrorActionPreference = 'Stop'
$deveco = 'D:\HUAWEI\DevEco Studio'
$node = Join-Path $deveco 'tools\node\node.exe'
$tsc = Join-Path $deveco 'tools\ohpm\node_modules\typescript\lib\tsc.js'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$engine = if ($EngineDir -ne '') { $EngineDir } else { Join-Path $root 'entry\src\main\ets\engine' }
$lexicon = if ($Lexicon -ne '') { $Lexicon } else { Join-Path $root 'entry\src\main\resources\rawfile\lexicon\base_lexicon.txt' }
$bigram = if ($Bigram -ne '') { $Bigram } else { Join-Path $root 'entry\src\main\resources\rawfile\lexicon\bigram.txt' }
# build-chat-eval.mjs 生成的聊天评测集，没有生成时跳过
$chat = Join-Path $root 'tools\lexicon-src\external'
$work = Join-Path $PSScriptRoot 'build'
$names = @('EngineTypes', 'Lexicon', 'PinyinSyllables', 'FuzzyPinyin', 'PinyinSegmenter', 'PinyinEngine', 'BigramModel')

# 回归要实例化用户词库，另外带上 UserLexicon 与一份 ime 层组词契约的类型占位。
# 它单独编译到 build\regress，普通评测仍然只写 build\src 与 build\out 里自己生成的那几个文件。
if ($Regress) {
  $stage = Join-Path $work 'regress'
  $sources = $names + @('UserLexicon')
  Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path (Join-Path $stage 'src') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $stage 'ime') | Out-Null
  foreach ($name in $sources) {
    $file = Join-Path $engine "$name.ets"
    if (Test-Path $file) {
      Copy-Item $file (Join-Path $stage "src\$name.ts") -Force
    }
  }
  Copy-Item (Join-Path $PSScriptRoot 'regress.ts') (Join-Path $stage 'src\regress.ts') -Force
  Copy-Item (Join-Path $PSScriptRoot 'bench-shim\ime\CompositionController.ts') (Join-Path $stage 'ime\CompositionController.ts') -Force
  @'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "CommonJS",
    "outDir": "out",
    "rootDir": ".",
    "strict": false,
    "skipLibCheck": true,
    "lib": ["ES2020"],
    "esModuleInterop": true
  },
  "include": ["src/**/*.ts", "ime/**/*.ts"]
}
'@ | Set-Content -Path (Join-Path $stage 'tsconfig.json') -Encoding UTF8
  Push-Location $stage
  try {
    & $node $tsc -p tsconfig.json
    if ($LASTEXITCODE -ne 0) {
      exit $LASTEXITCODE
    }
    & $node 'out/src/regress.js' $lexicon $bigram
    exit $LASTEXITCODE
  } finally {
    Pop-Location
  }
}

if (Test-Path (Join-Path $work 'src')) {
  Remove-Item -Recurse -Force (Join-Path $work 'src')
}
New-Item -ItemType Directory -Force -Path (Join-Path $work 'src') | Out-Null
foreach ($name in $names) {
  $source = Join-Path $engine "$name.ets"
  if (Test-Path $source) {
    Copy-Item $source (Join-Path $work "src\$name.ts") -Force
  }
}
Copy-Item (Join-Path $PSScriptRoot 'bench.ts') (Join-Path $work 'src\bench.ts') -Force

# 只覆盖自己生成的文件，build\out 里调参用的其他产物保持原样
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
'@ | Set-Content -Path (Join-Path $work 'tsconfig.json') -Encoding UTF8

# PowerShell 调用外部程序时会丢掉空字符串参数，不用二元模型时传一个占位的减号
$bigramArg = if ($NoBigram) { '-' } else { $bigram }
$extra = @()
if ($Dump) { $extra += '--dump' }
Push-Location $work
try {
    & $node $tsc -p tsconfig.json
    if ($LASTEXITCODE -ne 0) {
      exit $LASTEXITCODE
    }
    & $node 'out/bench.js' $lexicon $Label $PSScriptRoot $bigramArg $chat @extra
    exit $LASTEXITCODE
} finally {
  Pop-Location
}
