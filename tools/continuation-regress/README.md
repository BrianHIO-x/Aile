# 定向续接回归

两次相邻的明确确认 → 用户词库记下组合 → 候选栏补出外层候选 → 保存重载以后仍然可用。
不启动 DevEco 构建、不启动模拟器、不调用共享 Hvigor，直接在 Node 里消费真实源码：

- 真实词库与二元模型（`entry/src/main/resources/rawfile/lexicon/`）
- 真实引擎 `PinyinEngine` / `Lexicon` / `BigramModel`
- 真实组词控制器 `CompositionController` 与排序 `CandidateRanking`
- 真实用户词库 `UserLexicon`（学习、续接索引、固定/删除、序列化）
- 真实 `ContinuationTracker`（相邻判定、时间窗、选区与长度核对）

只有 ArkUI 的两处类型换成最小占位：`CandidateView`（ImeState）与 `TapSample`/`NO_TAP`（TouchModel）。
`ImeController.finishCommit` 的发起顺序在 `commitText()` 里逐条复刻：先 `start` + `noteOwnInsert`，
再按编辑框回执 `learn` → `noteTextLength` → `noteSelection` → `verified` → `learnContinuation`。

## 用法

在仓库根目录：

```powershell
powershell -ExecutionPolicy Bypass -File tools\continuation-regress\run.ps1
```

可选 `-Lexicon`、`-Bigram` 指向另一套词库做对照。
退出码：0 全部通过，1 有断言失败，2 参数或编译失败。

## 目录

```text
continuation-regress/
  run.ps1                 唯一入口；只清理并写入本目录 build（**/build 已忽略）
  continuation.test.ts    断言集
  build/                  临时编译目录（每次重建）
```

## 覆盖的检查

1. **continuableSegments 全有或全无**：全部合格才整次参与；中间夹原文、首段是合成整句、
   首段是学到的组合、音节与字数对不上、结果标记为原文，都整次不参与。这条守住“过滤掉不合格段
   再取首尾会伪造相邻”的边界。
2. **ContinuationTracker**：相邻两次成功提交连成一对；正好 3000ms 相连、3001ms 不相连；
   换会话、上下文前进两代、序号缺口、`break()`、`failed()`、假成功（没有真实回执）都不相连。
3. **noteSelection 折叠选区边界**：前后都必须是光标（`oldBegin===oldEnd` 且 `newBegin===newEnd`）；
   新选区 `begin<end`、旧的选区、反向范围、负下标都打断；自己的插入推动光标不算打断；
   位移超过待核对字数时打断。
4. **noteTextLength**：第一次推送只当基准；自己插入后的长度对得上；多出来的长度判定为别处改动。
5. **真实词库已知组合**：`shuru` 首选“输入”，点按后 `fa` 选“法”，再次输入 `shuru` 时
   “输入法”作为组合续接出现在普通候选栏前几位（`consumedCodeLength=5`，读音 `shu ru fa`，
   来源 `CandidateOrigin.CONTINUATION`），默认首选仍是“输入”。
6. **保存重载**：`serialize()` 把续接写进词的 `x` 字段；`deserialize()` 读回并重建续接索引以后，
   重载的词数、二元关联数与“输入法”的提示都还在。
7. **只认整串**：`shur`、`shurun`、`shuru `（尾随空格不行，这里是多打一个空格再打字母）都不提示；
   记下的码是 `shu'ru` 时只认带撇号的整串，去掉撇号的 `shuru` 不提示。
8. **未知组合两次**：词库里没有的“法输入”第一次确认不提示，再确认一次才提示，且确认次数随文件保存。
9. **固定、删除、撤销**：固定“输入法”后排首位；取消固定回到“输入”；删除以后不再提示，
   删除记录随文件保存，撤销以后回来；固定同样随文件保存。
10. **打断、超时、假成功**：中间插入标点、超过时间窗、没有真实回执都不学组合；假成功之后的
    成功提交也不能越过它连到更早一次。
11. **引擎层兜底**：即使调用方直接调用 `learnContinuation`，原文、合成整句、学到的组合都不会被记下。

## 最近一次结果

2026-11-21 00:2x，当前源码、真实词库 174542 条：**82 项全部通过，失败 0**（退出码 0）。

同一份源码上顺带跑的已有回归：

| 套件 | 入口 | 结果 |
| --- | --- | --- |
| 定向续接回归 | `tools\continuation-regress\run.ps1` | 82 项全部通过，失败 0 |
| 引擎契约回归 | `tools\engine-bench\run.ps1 -Regress` | 63 项，失败 0 |
| 组词控制器回归 | `tools\frontend-regress\run.ps1`（用 pwsh 跑，见下） | 53 项通过，失败 0 |
| 候选排序回归 | `tools\candidate-rank\run.ps1` | 101 项通过，失败 0 |

本机的 Windows PowerShell 5.1 不认 `-Encoding utf8NoBOM`，`tools\frontend-regress\run.ps1` 要用
`pwsh -File` 运行；这是脚本与宿主版本的老问题，与源码无关。

## 注意

- 只写本目录 `build`，不碰 `entry/build`、`tools/engine-bench/build`、`tools/frontend-regress/build`、
  `tools/candidate-rank/build` 或 `tools/engine-bench/build/candidate-smoke`。
- 候选栏是否真的画出来、触摸命中与视觉换页仍需真机/模拟器；这里验证的是数据与顺序。
