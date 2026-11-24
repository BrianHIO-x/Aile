# 定向续接回归：真实词库 + 真实引擎 + 真实组词控制器 + 真实用户词库 + 真实 ContinuationTracker。
# 只写本目录的 build（已由 **/build 忽略），不调用共享 Hvigor，也不碰 engine-bench / candidate-rank /
# frontend-regress / candidate-smoke 的构建产物。使用 DevEco 自带 node + tsc，与其它回归同一套工具链。
#
# 用法：powershell -ExecutionPolicy Bypass -File tools\continuation-regress\run.ps1
# 可选：-Lexicon、-Bigram 指向另一套词库与二元模型做对照
param([string]$Lexicon = '', [string]$Bigram = '')

$ErrorActionPreference = 'Stop'
$deveco = 'D:\HUAWEI\DevEco Studio'
$node = Join-Path $deveco 'tools\node\node.exe'
$tsc = Join-Path $deveco 'tools\ohpm\node_modules\typescript\lib\tsc.js'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$work = Join-Path $PSScriptRoot 'build'

if (-not (Test-Path $node)) { throw "node not found: $node" }
if (-not (Test-Path $tsc)) { throw "tsc not found: $tsc" }

if (Test-Path $work) {
  if (-not $work.StartsWith($PSScriptRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to remove unexpected path: $work"
  }
  Remove-Item -Recurse -Force $work
}
New-Item -ItemType Directory -Force -Path (Join-Path $work 'src\engine') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $work 'src\ime') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $work 'src\keyboard') | Out-Null

# 引擎：用户词库的持久化与续接索引都在这一层
$engineNames = @('EngineTypes', 'Lexicon', 'PinyinSyllables', 'FuzzyPinyin', 'PinyinSegmenter', 'PinyinEngine',
  'BigramModel', 'UserLexicon')
foreach ($name in $engineNames) {
  $source = Join-Path $root "entry\src\main\ets\engine\$name.ets"
  if (-not (Test-Path $source)) { throw "missing engine source: $source" }
  Copy-Item $source (Join-Path $work "src\engine\$name.ts") -Force
}
# 组词控制器与候选排序用真实源码：续接候选要经过真实的 arrange / withContinuations / rankCandidates
foreach ($name in @('CompositionController', 'CandidateRanking', 'ContinuationTracker')) {
  $source = Join-Path $root "entry\src\main\ets\ime\$name.ets"
  if (-not (Test-Path $source)) { throw "missing ime source: $source" }
  Copy-Item $source (Join-Path $work "src\ime\$name.ts") -Force
}

# Windows PowerShell 5.1 不认 utf8NoBOM，显式用不带 BOM 的 UTF8 写占位文件
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Write-Utf8([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, $utf8NoBom)
}

Write-Utf8 (Join-Path $work 'src\ime\ImeState.ts') @'
export interface CandidateView {
  index: number;
  text: string;
  chars: number;
  id: string;
  consumedCodeLength: number;
  revision: number;
}
'@

Write-Utf8 (Join-Path $work 'src\keyboard\TouchModel.ts') @'
export interface TapSample {
  keyId: string;
  dx: number;
  dy: number;
}

export const NO_TAP: TapSample = { keyId: '', dx: 0, dy: 0 };
'@

Write-Utf8 (Join-Path $work 'src\node-shim.d.ts') @'
declare function require(name: string): any;
declare const process: any;
declare const console: any;
'@

Copy-Item (Join-Path $PSScriptRoot 'continuation.test.ts') (Join-Path $work 'src\continuation.test.ts') -Force

Write-Utf8 (Join-Path $work 'tsconfig.json') @'
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
'@

$lexiconPath = if ($Lexicon -ne '') { (Resolve-Path $Lexicon).Path } else {
  Join-Path $root 'entry\src\main\resources\rawfile\lexicon\base_lexicon.txt' }
$bigramPath = if ($Bigram -ne '') { (Resolve-Path $Bigram).Path } else {
  Join-Path $root 'entry\src\main\resources\rawfile\lexicon\bigram.txt' }
if (-not (Test-Path $lexiconPath)) { throw "lexicon not found: $lexiconPath" }
if (-not (Test-Path $bigramPath)) { throw "bigram not found: $bigramPath" }

Push-Location $work
try {
  & $node $tsc -p tsconfig.json
  if ($LASTEXITCODE -ne 0) {
    throw "tsc failed with exit code $LASTEXITCODE"
  }
  & $node 'out/continuation.test.js' $lexiconPath $bigramPath
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
