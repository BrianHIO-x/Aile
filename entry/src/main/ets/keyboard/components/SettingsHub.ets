import { curves } from '@kit.ArkUI';
import { ImeController } from '../../ime/ImeController';
import { ImeState, PanelMode, SettingsTab } from '../../ime/ImeState';
import { LayoutForm } from '../KeyDefinitions';
import { snapAnimation } from '../Motion';
import { AileIcon, HubTile, TILE_SIZE_VP } from './AileControls';

// 顶部标签分两组：左手区放常用功能与键盘模式，右手区放拼音与工具栏
export const SETTINGS_LEFT_TABS: string[] = ['常用功能', '键盘模式'];
export const SETTINGS_RIGHT_TABS: string[] = ['拼音', '工具栏'];
const SETTINGS_PAGE_COUNT: number = 4;
const FUZZY_CAPTION: string = '点亮后不区分 z/zh c/ch s/sh n/l f/h r/l，以及 an/ang en/eng in/ing';

// 每个拇指区按 4 列排布磁贴，常规布局整宽按 8 列排布
const ZONE_COLUMNS: number = 4;
const FULL_COLUMNS: number = 8;
const HUB_TOP_VP: number = 18;
// 不超过这个数量的磁贴全部放在左手区
const LEFT_ONLY_LIMIT: number = 2;

interface HubItem {
  icon: AileIcon;
  label: string;
  active: boolean;
  action: () => void;
}

interface TileSlot {
  item: HubItem;
  x: number;
}

/**
 * 功能面板：磁贴按拇指区分布。分离布局下磁贴超过两个时左右平分，
 * 左手区从左边缘向右排，右手区贴右边缘向左排，与两侧键区的边缘对齐。
 */
@ComponentV2
export struct SettingsHub {
  @Local state: ImeState = ImeState.get();
  @Param areaWidth: number = 0;
  @Param areaHeight: number = 0;
  @Param split: boolean = true;
  @Param leftX: number = 0;
  @Param leftWidth: number = 0;
  @Param rightX: number = 0;
  @Param rightWidth: number = 0;
  @Param keyGap: number = 6;
  private controller: ImeController = ImeController.get();

  private commonItems(): HubItem[] {
    return [
      { icon: AileIcon.EMOJI, label: '表情', active: false, action: () => this.controller.openEmoji() },
      { icon: AileIcon.CLIPBOARD, label: '剪贴板', active: false, action: () => this.controller.openClipboard() },
      { icon: AileIcon.PHRASE, label: '常用语', active: false, action: () => this.controller.openPhrases() },
      {
        icon: AileIcon.TUNE, label: '布局校准', active: false,
        action: () => this.controller.setPanelMode(PanelMode.TUNER)
      }
    ];
  }

  private modeItems(): HubItem[] {
    return [
      {
        icon: AileIcon.SPLIT, label: '分离模式', active: this.state.currentForm() === LayoutForm.SPLIT,
        action: () => {
          if (this.state.currentForm() !== LayoutForm.SPLIT) {
            this.controller.toggleForm();
          }
        }
      },
      {
        icon: AileIcon.NORMAL, label: '常规模式', active: this.state.currentForm() === LayoutForm.NORMAL,
        action: () => {
          if (this.state.currentForm() !== LayoutForm.NORMAL) {
            this.controller.toggleForm();
          }
        }
      }
    ];
  }

  private pinyinItems(): HubItem[] {
    return [
      {
        icon: AileIcon.FUZZY, label: '模糊拼音', active: this.state.fuzzyPinyin,
        action: () => this.controller.setFuzzyPinyin(!this.state.fuzzyPinyin)
      }
    ];
  }

  private toolbarItems(): HubItem[] {
    return [
      {
        icon: AileIcon.EMOJI, label: '表情', active: this.state.toolbarEmoji,
        action: () => this.controller.setToolbarEmoji(!this.state.toolbarEmoji)
      },
      {
        icon: AileIcon.CLIPBOARD, label: '剪贴板', active: this.state.toolbarClipboard,
        action: () => this.controller.setToolbarClipboard(!this.state.toolbarClipboard)
      }
    ];
  }

  private leftEdge(): number {
    return this.leftX + this.keyGap / 2;
  }

  private cellPitch(): number {
    if (this.split) {
      return Math.max(TILE_SIZE_VP + 8, Math.min(this.leftWidth, this.rightWidth) / ZONE_COLUMNS);
    }
    return Math.max(TILE_SIZE_VP + 8, this.leftWidth / FULL_COLUMNS);
  }

  /**
   * 计算磁贴横坐标：左手区第一块磁贴左边缘对齐最左侧按键，右手区最后一块磁贴右边缘对齐最右侧按键。
   */
  private slots(items: HubItem[]): TileSlot[] {
    const pitch = this.cellPitch();
    const gapToNext = pitch - TILE_SIZE_VP;
    const leftCount = !this.split || items.length <= LEFT_ONLY_LIMIT ? items.length : Math.ceil(items.length / 2);
    const result: TileSlot[] = [];
    for (let i = 0; i < items.length; i++) {
      if (i < leftCount) {
        result.push({ item: items[i], x: this.leftEdge() + i * pitch });
      } else {
        const fromRight = items.length - 1 - i;
        const rightEdge = this.rightX + this.rightWidth - this.keyGap / 2;
        result.push({ item: items[i], x: rightEdge - TILE_SIZE_VP - fromRight * (TILE_SIZE_VP + gapToNext) });
      }
    }
    return result;
  }

  @Builder
  tilePage(page: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(this.slots(this.itemsOf(page)), (slot: TileSlot, index: number) => {
        HubTile({
          icon: slot.item.icon,
          label: slot.item.label,
          active: slot.item.active,
          cellWidth: TILE_SIZE_VP,
          action: slot.item.action
        })
          .position({ x: slot.x, y: HUB_TOP_VP })
      }, (slot: TileSlot, index: number) => `${page}_${index}_${slot.x.toFixed(1)}_${slot.item.active}`)
      if (page === SettingsTab.TOOLBAR) {
        Text('点亮的功能会显示在顶部栏')
          .fontSize(12)
          .maxFontScale(1.2)
          .fontColor($r('app.color.key_hint_text'))
          .position({ x: this.leftEdge(), y: HUB_TOP_VP + TILE_SIZE_VP + 14 })
      } else if (page === SettingsTab.PINYIN) {
        // 说明文字限制在左手区宽度内，放不下时换行
        Text(FUZZY_CAPTION)
          .fontSize(12)
          .maxFontScale(1.2)
          .lineHeight(18)
          .fontColor($r('app.color.key_hint_text'))
          .constraintSize({ maxWidth: Math.max(TILE_SIZE_VP, this.leftWidth - this.keyGap) })
          .position({ x: this.leftEdge(), y: HUB_TOP_VP + TILE_SIZE_VP + 14 })
      }
    }
    .width('100%')
    .height('100%')
  }

  private itemsOf(page: number): HubItem[] {
    if (page === SettingsTab.MODE) {
      return this.modeItems();
    }
    if (page === SettingsTab.PINYIN) {
      return this.pinyinItems();
    }
    if (page === SettingsTab.TOOLBAR) {
      return this.toolbarItems();
    }
    return this.commonItems();
  }

  @Builder
  pageDots() {
    Row({ space: 6 }) {
      ForEach([0, 1, 2, 3], (index: number) => {
        Column()
          .width(index === this.state.settingsTab ? 16 : 6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(index === this.state.settingsTab ? $r('app.color.kb_accent') : $r('app.color.key_hint_text'))
          .opacity(index === this.state.settingsTab ? 1 : 0.35)
          .animation(snapAnimation())
      }, (index: number) => `dot_${index}`)
    }
    .margin({ bottom: 12 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Swiper() {
        this.tilePage(SettingsTab.COMMON)
        this.tilePage(SettingsTab.MODE)
        this.tilePage(SettingsTab.PINYIN)
        this.tilePage(SettingsTab.TOOLBAR)
      }
      .index(Math.min(this.state.settingsTab, SETTINGS_PAGE_COUNT - 1))
      .loop(false)
      .indicator(false)
      // 翻页使用系统标准弹簧，点按标签与手指滑动的手感一致
      .curve(curves.interpolatingSpring(0, 1, 328, 34))
      .width('100%')
      .height('100%')
      .onChange((index: number) => this.controller.setSettingsTab(index))

      this.pageDots()
    }
    .width(this.areaWidth)
    .height(this.areaHeight)
    .backgroundColor($r('app.color.kb_background'))
  }
}
