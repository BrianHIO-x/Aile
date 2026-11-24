import { InputMethodExtensionContext } from '@kit.IMEKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { BigramModel } from '../engine/BigramModel';
import { Lexicon } from '../engine/Lexicon';
import { PinyinEngine } from '../engine/PinyinEngine';
import { UserLexicon } from '../engine/UserLexicon';
import { TouchModel } from '../keyboard/TouchModel';
import { UserLexiconStore } from '../storage/UserLexiconStore';
import { ImeController } from './ImeController';
import { LexiconStatus } from './ImeState';
import { Log } from './Log';

const BASE_LEXICON_PATH: string = 'lexicon/base_lexicon.txt';
const BIGRAM_PATH: string = 'lexicon/bigram.txt';
const TOUCH_MODEL_FILE: string = 'touch_offsets.json';
const SAVE_DELAY_MS: number = 3000;

/**
 * 词库加载与学习数据持久化，面板创建之后异步执行，加载期间英文输入保持可用。
 * 学习数据包括用户词库与按键落点偏移，两者分别保存在各自的文件里。
 */
export class EngineLoader {
  private saveTimer: number = -1;
  private store: UserLexiconStore | undefined = undefined;
  private userLexicon: UserLexicon | undefined = undefined;
  private touchStore: UserLexiconStore | undefined = undefined;
  private generation: number = 0;

  start(context: InputMethodExtensionContext): void {
    const generation = ++this.generation;
    ImeController.get().setCandidateProvider(ImeController.get().rawProvider(), LexiconStatus.LOADING);
    setTimeout(() => {
      if (generation === this.generation) {
        this.load(context, generation);
      }
    }, 50);
  }

  stop(): void {
    this.generation++;
    this.saveNow();
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
  }

  /**
   * 词库、二元模型与学习数据分三步读取，每步之间让出主线程，键盘在加载期间仍能及时响应触摸。
   */
  private load(context: InputMethodExtensionContext, generation: number): void {
    const controller = ImeController.get();
    this.loadTouchModel(context);
    const startTime = Date.now();
    const lexicon = new Lexicon();
    try {
      const text = util.TextDecoder.create('utf-8').decodeToString(
        context.resourceManager.getRawFileContentSync(BASE_LEXICON_PATH));
      const result = lexicon.loadFromText(text);
      Log.info(`lexicon loaded entries=${result.entries} ms=${Date.now() - startTime}`);
    } catch (error) {
      Log.error(`lexicon load failed, code=${(error as BusinessError).code}`);
      controller.setCandidateProvider(controller.rawProvider(), LexiconStatus.MISSING);
      return;
    }
    if (lexicon.size() === 0) {
      controller.setCandidateProvider(controller.rawProvider(), LexiconStatus.FAILED);
      return;
    }
    const engine = new PinyinEngine(lexicon);
    setTimeout(() => {
      if (generation !== this.generation) {
        return;
      }
      this.loadBigram(context, engine);
      setTimeout(() => {
        if (generation === this.generation) {
          this.attachLearning(context, lexicon, engine);
        }
      }, 0);
    }, 0);
  }

  // 二元模型缺失或损坏时照常输入，只是整句不参考前后词的搭配
  private loadBigram(context: InputMethodExtensionContext, engine: PinyinEngine): void {
    try {
      const startTime = Date.now();
      const bigram = new BigramModel();
      const loaded = bigram.loadFromText(util.TextDecoder.create('utf-8').decodeToString(
        context.resourceManager.getRawFileContentSync(BIGRAM_PATH)));
      if (loaded.pairs > 0) {
        engine.setBigramModel(bigram);
      }
      Log.info(`bigram loaded pairs=${loaded.pairs} ms=${Date.now() - startTime}`);
    } catch (error) {
      Log.warn(`bigram load failed, code=${(error as BusinessError).code}`);
    }
  }

  private attachLearning(context: InputMethodExtensionContext, lexicon: Lexicon, engine: PinyinEngine): void {
    const controller = ImeController.get();
    const userLexicon = new UserLexicon();
    userLexicon.attachBase(lexicon);
    const store = new UserLexiconStore(context.filesDir);
    const saved = store.read();
    if (saved !== undefined) {
      try {
        userLexicon.deserialize(saved);
        Log.info(`user lexicon loaded words=${userLexicon.wordCount()} bigrams=${userLexicon.bigramCount()} ` +
          `pending=${userLexicon.pendingCount()}`);
      } catch (error) {
        Log.warn('user lexicon corrupted, backup and start empty');
        store.backupCorrupted();
      }
    }
    userLexicon.setListeners(() => this.scheduleSave(), () => this.saveNow());
    this.store = store;
    this.userLexicon = userLexicon;
    engine.setUserModel(userLexicon);
    controller.setLearner(userLexicon, userLexicon);
    controller.setCandidateProvider(engine, LexiconStatus.READY);
  }

  private loadTouchModel(context: InputMethodExtensionContext): void {
    const model = TouchModel.get();
    const store = new UserLexiconStore(context.filesDir, TOUCH_MODEL_FILE);
    const saved = store.read();
    if (saved !== undefined) {
      try {
        model.deserialize(saved);
        Log.info(`touch model loaded keys=${model.keyCount()}`);
      } catch (error) {
        Log.warn('touch model corrupted, backup and start empty');
        store.backupCorrupted();
      }
    }
    model.setChangeListener(() => this.scheduleSave());
    this.touchStore = store;
  }

  private scheduleSave(): void {
    if (this.saveTimer !== -1) {
      return;
    }
    this.saveTimer = setTimeout(() => {
      this.saveTimer = -1;
      this.saveNow();
    }, SAVE_DELAY_MS);
  }

  private saveNow(): void {
    const lexicon = this.userLexicon;
    const store = this.store;
    if (lexicon !== undefined && store !== undefined && lexicon.isDirty() && store.write(lexicon.serialize())) {
      lexicon.markClean();
    }
    const model = TouchModel.get();
    const touchStore = this.touchStore;
    if (touchStore !== undefined && model.isDirty() && touchStore.write(model.serialize())) {
      model.markClean();
    }
  }
}
