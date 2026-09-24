import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LayoutProfile, parseProfile, ProfileOrientation, sanitizeProfile } from '../keyboard/LayoutProfile';
import { Log } from '../ime/Log';

const STORE_NAME: string = 'thumb_ime_settings';
const KEY_PROFILE_PREFIX: string = 'layout_profile_v1_';

/**
 * 布局档案与开关保存在输入法扩展自己的沙箱中。
 */
export class LayoutStore {
  private store: preferences.Preferences | undefined = undefined;

  init(context: common.BaseContext): void {
    try {
      const options: preferences.Options = { name: STORE_NAME };
      this.store = preferences.getPreferencesSync(context as Context, options);
    } catch (error) {
      Log.error(`preferences open failed, code=${(error as BusinessError).code}`);
      this.store = undefined;
    }
  }

  loadProfile(orientation: ProfileOrientation): LayoutProfile {
    const store = this.store;
    if (store === undefined) {
      return sanitizeProfile(undefined, orientation);
    }
    try {
      const text = store.getSync(KEY_PROFILE_PREFIX + orientation, '') as string;
      return parseProfile(text, orientation);
    } catch (error) {
      Log.error(`profile load failed, code=${(error as BusinessError).code}`);
      return sanitizeProfile(undefined, orientation);
    }
  }

  saveProfile(orientation: ProfileOrientation, profile: LayoutProfile): void {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(KEY_PROFILE_PREFIX + orientation, JSON.stringify(sanitizeProfile(profile, orientation)));
      store.flush();
    } catch (error) {
      Log.error(`profile save failed, code=${(error as BusinessError).code}`);
    }
  }

  loadFlag(key: string, fallback: boolean): boolean {
    const store = this.store;
    if (store === undefined) {
      return fallback;
    }
    try {
      return store.getSync(key, fallback) as boolean;
    } catch (error) {
      Log.error(`flag load failed, code=${(error as BusinessError).code}`);
      return fallback;
    }
  }

  saveFlag(key: string, value: boolean): void {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(key, value);
      store.flush();
    } catch (error) {
      Log.error(`flag save failed, code=${(error as BusinessError).code}`);
    }
  }

  /**
   * 字符串列表以 JSON 保存，内容损坏或类型不符时返回空列表。
   */
  loadList(key: string): string[] {
    const store = this.store;
    if (store === undefined) {
      return [];
    }
    try {
      const raw = JSON.parse(store.getSync(key, '[]') as string) as Object;
      if (!Array.isArray(raw)) {
        return [];
      }
      return (raw as Object[]).filter((item: Object) => typeof item === 'string').map((item: Object) => item as string);
    } catch (error) {
      return [];
    }
  }

  saveList(key: string, list: string[]): void {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(key, JSON.stringify(list));
      store.flush();
    } catch (error) {
      Log.error(`list save failed, code=${(error as BusinessError).code}`);
    }
  }
}

export const KEY_TOOLBAR_EMOJI: string = 'toolbar_emoji';
export const KEY_TOOLBAR_CLIPBOARD: string = 'toolbar_clipboard';
export const KEY_FUZZY_PINYIN: string = 'fuzzy_pinyin';
export const KEY_CLIPBOARD_ITEMS: string = 'clipboard_items_v1';
export const KEY_PHRASE_ITEMS: string = 'phrase_items_v1';
export const KEY_RECENT_EMOJI: string = 'recent_emoji_v1';
