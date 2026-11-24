# 前端候选回归：单独把 CompositionController 与小词库桩编译成 TypeScript，确定性地检查陈旧候选、RAW、分隔符与精确消费。
# 只写 tools/frontend-regress/build（已由 **/build 忽略），不触碰引擎 bench 的 run.ps1 / regress.ts 与共享 build/src。
$ErrorActionPreference = 'Stop'
$deveco = 'D:\HUAWEI\DevEco Studio'
$node = Join-Path $deveco 'tools\node\node.exe'
$tsc = Join-Path $deveco 'tools\ohpm\node_modules\typescript\lib\tsc.js'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$work = Join-Path $PSScriptRoot 'build'

if (Test-Path $work) {
  if (-not $work.StartsWith($PSScriptRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to remove unexpected path: $work"
  }
  Remove-Item -Recurse -Force $work
}
New-Item -ItemType Directory -Force -Path (Join-Path $work 'src\ime') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $work 'src\engine') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $work 'src\keyboard') | Out-Null

Copy-Item (Join-Path $root 'entry\src\main\ets\ime\CompositionController.ets') (Join-Path $work 'src\ime\CompositionController.ts') -Force
Copy-Item (Join-Path $root 'entry\src\main\ets\ime\CandidateRanking.ets') (Join-Path $work 'src\ime\CandidateRanking.ts') -Force
Copy-Item (Join-Path $root 'entry\src\main\ets\engine\EngineTypes.ets') (Join-Path $work 'src\engine\EngineTypes.ts') -Force
Copy-Item (Join-Path $PSScriptRoot 'composition.test.ts') (Join-Path $work 'src\test.ts') -Force

@'
export interface CandidateView {
  index: number;
  text: string;
  chars: number;
  id: string;
  consumedCodeLength: number;
  revision: number;
}
'@ | Set-Content -Path (Join-Path $work 'src\ime\ImeState.ts') -Encoding utf8NoBOM

@'
export interface TapSample {
  keyId: string;
  dx: number;
  dy: number;
}

export const NO_TAP: TapSample = { keyId: '', dx: 0, dy: 0 };
'@ | Set-Content -Path (Join-Path $work 'src\keyboard\TouchModel.ts') -Encoding utf8NoBOM

@'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "CommonJS",
    "outDir": "out",
    "strict": false,
    "skipLibCheck": true,
    "lib": ["ES2020", "DOM"]
  },
  "include": ["src/**/*.ts"]
}
'@ | Set-Content -Path (Join-Path $work 'tsconfig.json') -Encoding utf8NoBOM

Push-Location $work
try {
  & $node $tsc -p tsconfig.json
  if ($LASTEXITCODE -ne 0) {
    throw "tsc failed with exit code $LASTEXITCODE"
  }
  & $node 'out/test.js'
  if ($LASTEXITCODE -ne 0) {
    throw "frontend regression failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}
