import { Candidate, CandidateProvider, CandidateSource, QueryOptions } from './engine/EngineTypes';
import { CandidateView } from './ime/ImeState';
import { CandidateSelection, CompositionController } from './ime/CompositionController';

interface QueryRecord {
  code: string;
  previousText: string;
}

class MapProvider implements CandidateProvider {
  private table: Map<string, Candidate[]> = new Map<string, Candidate[]>();
  queries: QueryRecord[] = [];

  constructor(table: Map<string, Candidate[]>) {
    this.table = table;
  }

  isReady(): boolean {
    return true;
  }

  query(code: string, previousText: string, limit: number, options: QueryOptions): Candidate[] {
    this.queries.push({ code: code, previousText: previousText });
    const found = this.table.get(code);
    return found === undefined ? [] : found.slice();
  }

  formatCode(code: string, options: QueryOptions): string {
    return code;
  }
}

function candidate(id: string, text: string, consumed: number, syllables: string[],
  source: CandidateSource): Candidate {
  const value: Candidate = {
    id: id,
    text: text,
    consumedCodeLength: consumed,
    syllables: syllables,
    score: 0,
    source: source
  };
  return value;
}

function viewAt(engine: CompositionController, index: number): CandidateView {
  const list = engine.getCandidates();
  const value = list[index];
  const view: CandidateView = {
    index: index,
    text: value.text,
    chars: value.text.length,
    id: value.id,
    consumedCodeLength: value.consumedCodeLength,
    revision: engine.getRevision()
  };
  return view;
}

function viewOf(engine: CompositionController, candidateIndex: number, changes: Partial<CandidateView>): CandidateView {
  const base = viewAt(engine, candidateIndex);
  const view: CandidateView = {
    index: changes.index !== undefined ? changes.index : base.index,
    text: changes.text !== undefined ? changes.text : base.text,
    chars: changes.chars !== undefined ? changes.chars : base.chars,
    id: changes.id !== undefined ? changes.id : base.id,
    consumedCodeLength: changes.consumedCodeLength !== undefined ? changes.consumedCodeLength : base.consumedCodeLength,
    revision: changes.revision !== undefined ? changes.revision : base.revision
  };
  return view;
}

function tap(index: number) {
  return { keyId: 'key' + index, dx: 0, dy: 0 };
}

function alt(letter: string) {
  return [{ letter: letter.toUpperCase(), cost: 0.2 }];
}

let passed: number = 0;
let failed: number = 0;

function check(name: string, condition: boolean, detail: string = ''): void {
  if (condition) {
    passed++;
    console.log('PASS ' + name);
  } else {
    failed++;
    console.error('FAIL ' + name + (detail.length > 0 ? ' :: ' + detail : ''));
  }
}

function same(name: string, actual: Object, expected: Object): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  check(name, a === e, 'actual=' + a + ' expected=' + e);
}

function typeLetters(engine: CompositionController, letters: string): void {
  for (let i = 0; i < letters.length; i++) {
    engine.appendCode(letters.charAt(i), alt(letters.charAt(i)), tap(i));
  }
}

function scenarioOne(): void {
  const table = new Map<string, Candidate[]>();
  table.set('nihao', [
    candidate('n-2', '你', 2, ['ni'], CandidateSource.CHAR),
    candidate('n-5', '你好', 5, ['ni', 'hao'], CandidateSource.WORD)
  ]);
  table.set('hao', [candidate('h-3', '好', 3, ['hao'], CandidateSource.CHAR)]);
  const provider = new MapProvider(table);
  const engine = new CompositionController();
  engine.setProvider(provider);
  typeLetters(engine, 'nihao');

  const selected = engine.selectCandidate(viewAt(engine, 0));
  check('partial prefix accepted', selected.accepted);
  check('partial prefix has no final result', selected.result === undefined);
  same('partial prefix leaves exact remainder', engine.getRawCode(), 'hao');
  same('partial prefix keeps chosen text', engine.chosenText(), '你');
  same('candidate refresh uses chosen text as context', provider.queries[provider.queries.length - 1].previousText, '你');

  const last = engine.selectCandidate(viewAt(engine, 0));
  check('final selection produces result', last.result !== undefined);
  const result = last.result;
  if (result === undefined) {
    return;
  }
  same('final text joins chosen prefix', result.text, '你好');
  same('normal selection is not raw', result.raw, false);
  same('first segment consumes only its prefix', result.segments[0].code, 'ni');
  same('first segment taps belong to its prefix', result.segments[0].taps, [tap(0), tap(1)]);
  same('second segment consumes the remainder', result.segments[1].code, 'hao');
  same('second segment alternatives are the remainder',
    result.segments[1].alternatives, [alt('h'), alt('a'), alt('o')]);
  same('second segment taps are the remainder', result.segments[1].taps, [tap(2), tap(3), tap(4)]);
}

function scenarioStale(): void {
  const table = new Map<string, Candidate[]>();
  table.set('ni', [candidate('ni', '你', 2, ['ni'], CandidateSource.CHAR)]);
  table.set('nih', [candidate('nih', '你', 2, ['ni'], CandidateSource.CHAR)]);
  const provider = new MapProvider(table);
  const engine = new CompositionController();
  engine.setProvider(provider);
  engine.appendCode('n', alt('n'), tap(0));
  engine.appendCode('i', alt('i'), tap(1));
  const oldView = viewAt(engine, 0);
  const oldRevision = engine.getRevision();
  engine.appendCode('h', alt('h'), tap(2));
  const revisionAfterTyping = engine.getRevision();
  const queriesAfterTyping = provider.queries.length;

  const stale = engine.selectCandidate(oldView);
  check('stale view rejected', stale.accepted === false);
  check('stale view has no result', stale.result === undefined);
  same('stale view does not refresh candidates', provider.queries.length, queriesAfterTyping);
  same('stale view does not change revision', engine.getRevision(), revisionAfterTyping);
  same('stale view does not change input', engine.getRawCode(), 'nih');
  check('revision moved after typing', revisionAfterTyping > oldRevision);
}

function scenarioValidation(): void {
  const table = new Map<string, Candidate[]>();
  table.set('ni', [
    candidate('ni', '你', 2, ['ni'], CandidateSource.CHAR),
    candidate('ni2', '泥', 2, ['ni'], CandidateSource.CHAR)
  ]);
  const provider = new MapProvider(table);
  const engine = new CompositionController();
  engine.setProvider(provider);
  engine.appendCode('n', alt('n'), tap(0));
  engine.appendCode('i', alt('i'), tap(1));
  const revision = engine.getRevision();
  const queries = provider.queries.length;

  const wrongText = engine.selectCandidate(viewOf(engine, 0, { text: '妳' }));
  const wrongId = engine.selectCandidate(viewOf(engine, 0, { id: 'other' }));
  const zero = engine.selectCandidate(viewOf(engine, 0, { consumedCodeLength: 0 }));
  const negative = engine.selectCandidate(viewOf(engine, 0, { consumedCodeLength: -1 }));
  const fraction = engine.selectCandidate(viewOf(engine, 0, { consumedCodeLength: 1.5 }));
  const tooLong = engine.selectCandidate(viewOf(engine, 0, { consumedCodeLength: 3 }));
  const wrongIndex = engine.selectCandidate(viewOf(engine, 0, { index: 1.5 }));
  const staleRevision = engine.selectCandidate(viewOf(engine, 0, { revision: revision - 1 }));

  check('wrong text rejected', wrongText.accepted === false);
  check('wrong id rejected', wrongId.accepted === false);
  check('zero consumption rejected', zero.accepted === false);
  check('negative consumption rejected', negative.accepted === false);
  check('fractional consumption rejected', fraction.accepted === false);
  check('consumption beyond code rejected', tooLong.accepted === false);
  check('fractional index rejected before array access', wrongIndex.accepted === false);
  check('old revision rejected', staleRevision.accepted === false);
  same('rejected events do not consume input', engine.getRawCode(), 'ni');
  same('rejected events do not refresh candidates', provider.queries.length, queries);
  same('rejected events do not change revision', engine.getRevision(), revision);
}

function scenarioRaw(): void {
  const table = new Map<string, Candidate[]>();
  table.set('nihao', [
    candidate('n-2', '你', 2, ['ni'], CandidateSource.CHAR),
    candidate('n-5', '你好', 5, ['ni', 'hao'], CandidateSource.WORD)
  ]);
  table.set('hao', [candidate('raw-hao', 'hao', 3, [], CandidateSource.RAW)]);
  const provider = new MapProvider(table);
  const engine = new CompositionController();
  engine.setProvider(provider);
  typeLetters(engine, 'nihao');
  engine.selectCandidate(viewAt(engine, 0));
  const rawSelection = engine.selectCandidate(viewAt(engine, 0));
  const result = rawSelection.result;
  check('raw candidate finishes composition', result !== undefined);
  if (result === undefined) {
    return;
  }
  same('raw click keeps previously chosen text', result.text, '你hao');
  same('raw click makes the whole result raw', result.raw, true);
  same('raw segment is marked raw', result.segments[1].source, CandidateSource.RAW);
}

function scenarioRawButton(): void {
  const table = new Map<string, Candidate[]>();
  table.set('nihao', [
    candidate('n-2', '你', 2, ['ni'], CandidateSource.CHAR),
    candidate('n-5', '你好', 5, ['ni', 'hao'], CandidateSource.WORD)
  ]);
  table.set('hao', [candidate('h-3', '好', 3, ['hao'], CandidateSource.CHAR)]);
  const provider = new MapProvider(table);
  const engine = new CompositionController();
  engine.setProvider(provider);
  typeLetters(engine, 'nihao');
  engine.selectCandidate(viewAt(engine, 0));
  const result = engine.commitRaw();
  same('original-text button keeps chosen text', result.text, '你hao');
  same('original-text button result is raw', result.raw, true);
  same('original-text remainder is a raw segment', result.segments[1].source, CandidateSource.RAW);
}

function scenarioRawThenNormal(): void {
  const table = new Map<string, Candidate[]>();
  table.set('nihao', [candidate('raw-prefix', 'ni', 2, [], CandidateSource.RAW)]);
  table.set('hao', [candidate('h-3', '好', 3, ['hao'], CandidateSource.CHAR)]);
  const provider = new MapProvider(table);
  const engine = new CompositionController();
  engine.setProvider(provider);
  typeLetters(engine, 'nihao');
  const first = engine.selectCandidate(viewAt(engine, 0));
  check('partial raw prefix accepted', first.accepted);
  check('partial raw prefix leaves remainder', engine.getRawCode() === 'hao');
  const last = engine.selectCandidate(viewAt(engine, 0));
  check('normal completion still returns a result', last.result !== undefined);
  if (last.result === undefined) {
    return;
  }
  same('earlier raw segment makes later normal completion raw', last.result.raw, true);
  same('raw prefix text is preserved', last.result.text, 'ni好');
}

function scenarioSeparator(): void {
  const table = new Map<string, Candidate[]>();
  table.set("ni'hao", [candidate('sep-3', '你', 3, ['ni'], CandidateSource.CHAR)]);
  table.set('hao', [candidate('h-3', '好', 3, ['hao'], CandidateSource.CHAR)]);
  const provider = new MapProvider(table);
  const engine = new CompositionController();
  engine.setProvider(provider);
  engine.appendCode('n', alt('n'), tap(0));
  engine.appendCode('i', alt('i'), tap(1));
  engine.appendSeparator();
  engine.appendCode('h', alt('h'), tap(3));
  engine.appendCode('a', alt('a'), tap(4));
  engine.appendCode('o', alt('o'), tap(5));
  const selected = engine.selectCandidate(viewAt(engine, 0));
  check('separator candidate accepted', selected.accepted);
  check('separator candidate leaves remainder', engine.getRawCode() === 'hao');
  const last = engine.selectCandidate(viewAt(engine, 0));
  const result = last.result;
  check('separator final result exists', result !== undefined);
  if (result === undefined) {
    return;
  }
  same('separator is included in the consumed prefix', result.segments[0].code, "ni'");
  same('separator alternatives include the empty separator slot', result.segments[0].alternatives, [alt('n'), alt('i'), []]);
  same('separator tap is the empty tap', result.segments[0].taps, [tap(0), tap(1), { keyId: '', dx: 0, dy: 0 }]);
  same('separator remainder starts after the separator', result.segments[1].code, 'hao');
}

function scenarioSpaceFirst(): void {
  const table = new Map<string, Candidate[]>();
  table.set('nihao', [candidate('n-2', '你', 2, ['ni'], CandidateSource.CHAR)]);
  table.set('hao', [candidate('h-3', '好', 3, ['hao'], CandidateSource.CHAR)]);
  const provider = new MapProvider(table);
  const engine = new CompositionController();
  engine.setProvider(provider);
  typeLetters(engine, 'nihao');
  const first = engine.selectFirst();
  check('space selects first candidate partially', first === undefined);
  same('space first candidate consumes its prefix', engine.getRawCode(), 'hao');
  const result = engine.selectFirst();
  check('space final result exists', result !== undefined);
  if (result !== undefined) {
    same('space commits first candidate text', result.text, '你好');
  }
}

scenarioOne();
scenarioStale();
scenarioValidation();
scenarioRaw();
scenarioRawButton();
scenarioRawThenNormal();
scenarioSeparator();
scenarioSpaceFirst();

console.log('frontend-regress result: ' + passed + ' passed, ' + failed + ' failed');
if (failed > 0) {
  throw new Error('frontend-regress failed: ' + failed);
}
