import { InputMethodExtensionAbility } from '@kit.IMEKit';
import { Want } from '@kit.AbilityKit';
import { EngineLoader } from '../ime/EngineLoader';
import { ImeController } from '../ime/ImeController';
import { Log } from '../ime/Log';

export default class InputMethodService extends InputMethodExtensionAbility {
  private engineLoader: EngineLoader = new EngineLoader();

  onCreate(want: Want): void {
    Log.info('InputMethodService onCreate');
    ImeController.get().onCreate(this.context);
    this.engineLoader.start(this.context);
  }

  onDestroy(): void {
    Log.info('InputMethodService onDestroy');
    this.engineLoader.stop();
    ImeController.get().onDestroy();
  }
}
