import { ImeController } from '../../ime/ImeController';
import { ImeState } from '../../ime/ImeState';
import { EMOJI_CATEGORIES, emojiAssetPath } from '../EmojiData';
import { slideInTransition } from '../Motion';
import { PanelZone, zoneColumns, zoneRows } from '../PanelZones';

const EMOJI_CELL_VP: number = 58;
const EMOJI_CELL_HEIGHT_VP: number = 54;
const EMOJI_IMAGE_VP: number = 34;
const EMOJI_ROW_GAP_VP: number = 2;
const FULL_MIN_COLUMNS: number = 6;
const ZONE_MIN_COLUMNS: number = 4;
// 分离布局下顶部栏左组放前五个分类，其余分类放在右组
export const EMOJI_LEFT_TAB_COUNT: number = 5;

interface EmojiRow {
  key: string;
  zones: string[][];
}

/**
 * 表情面板：按分类显示可滚动的表情网格，分类在顶部栏切换。
 * 分离布局下网格分成左右两块，每行先排左手区再排右手区。
 * 面板高度包含底部手势横条区域，网格内容可以滚动到横条下方。
 */
@ComponentV2
export struct EmojiPanel {
  @Local state: ImeState = ImeState.get();
  @Param areaWidth: number = 0;
  @Param areaHeight: number = 0;
  @Param bottomInset: number = 0;
  @Param zones: PanelZone[] = [];
  private controller: ImeController = ImeController.get();
  // 下一次重建网格时的滑入方向：1 从右侧进入，-1 从左侧进入，0 不加动效
  private slideFrom: number = 0;

  // 面板刚打开时网格随面板整体进入，切换分类时新网格沿分类方向滑入
  @Monitor('state.emojiCategory')
  onCategoryChanged(monitor: IMonitor): void {
    const change = monitor.value<number>();
    const before = change === undefined ? this.state.emojiCategory : change.before;
    this.slideFrom = this.state.emojiCategory >= before ? 1 : -1;
  }

  private items(): string[] {
    const index = Math.max(0, Math.min(EMOJI_CATEGORIES.length - 1, this.state.emojiCategory));
    return index === 0 ? this.state.recentEmoji : EMOJI_CATEGORIES[index].emojis;
  }

  @Computed
  get columns(): number {
    return zoneColumns(this.zones, EMOJI_CELL_VP, 0, this.zones.length > 1 ? ZONE_MIN_COLUMNS : FULL_MIN_COLUMNS);
  }

  // 键值包含分类、列数、区域位置与表情，布局或内容变化后行会重新构建
  @Computed
  get rows(): EmojiRow[] {
    const items = this.items();
    const geometry = this.zones.map((zone: PanelZone) => `${zone.x.toFixed(1)}_${zone.width.toFixed(1)}`).join('_');
    return zoneRows(items.length, this.columns, this.zones.length).map((row: number[][], index: number) => {
      const zones = row.map((indices: number[]) => indices.map((i: number) => items[i]));
      const result: EmojiRow = {
        key: `${this.state.emojiCategory}_${this.columns}_${geometry}_${index}_` +
          zones.map((cells: string[]) => cells.join('')).join('|'),
        zones: zones
      };
      return result;
    });
  }

  @Styles
  cellNormal() {
    .backgroundColor(Color.Transparent)
  }

  @Styles
  cellPressed() {
    .backgroundColor($r('app.color.key_pressed_background'))
  }

  @Builder
  emojiCell(emoji: string, cellWidth: number) {
    Stack() {
      Image($rawfile(emojiAssetPath(emoji)))
        .width(EMOJI_IMAGE_VP)
        .height(EMOJI_IMAGE_VP)
        .objectFit(ImageFit.Contain)
        .interpolation(ImageInterpolation.High)
        .draggable(false)
    }
    .width(cellWidth)
    .height(EMOJI_CELL_HEIGHT_VP)
    .borderRadius(12)
    .stateStyles({ normal: this.cellNormal, pressed: this.cellPressed })
    .accessibilityText(emoji)
    .onClick(() => this.controller.insertEmoji(emoji))
  }

  @Builder
  emojiRow(row: EmojiRow) {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(row.zones, (cells: string[], zone: number) => {
        Row() {
          ForEach(cells, (emoji: string) => {
            this.emojiCell(emoji, this.zones[zone].width / this.columns)
          }, (emoji: string, index: number) => `${index}_${emoji}`)
        }
        .width(this.zones[zone].width)
        .height(EMOJI_CELL_HEIGHT_VP)
        .position({ x: this.zones[zone].x, y: 0 })
      }, (cells: string[], zone: number) => `${zone}_${cells.join('')}`)
    }
    .width('100%')
    .height(EMOJI_CELL_HEIGHT_VP)
  }

  private gridTransition(): TransitionEffect {
    return this.slideFrom === 0 ? TransitionEffect.IDENTITY : slideInTransition(this.slideFrom);
  }

  // 网格按分类整体构建，切换分类时旧网格立即移除，新网格从顶部开始显示
  build() {
    Stack() {
      ForEach([this.state.emojiCategory], (category: number) => {
        Stack() {
          if (this.items().length === 0) {
            Text('还没有最近使用的表情')
              .fontSize(14)
              .maxFontScale(1.2)
              .fontColor($r('app.color.key_hint_text'))
              .margin({ bottom: this.bottomInset })
          } else {
            List({ space: EMOJI_ROW_GAP_VP }) {
              ForEach(this.rows, (row: EmojiRow) => {
                ListItem() {
                  this.emojiRow(row)
                }
              }, (row: EmojiRow) => row.key)
            }
            // 内容在横条下方继续显示，滚到底时最后一行停在横条上方
            .contentStartOffset(6)
            .contentEndOffset(this.bottomInset + 6)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .width('100%')
            .height('100%')
          }
        }
        .width('100%')
        .height('100%')
        .transition(this.gridTransition())
      }, (category: number) => `emoji_category_${category}`)
    }
    .width(this.areaWidth)
    .height(this.areaHeight)
    .backgroundColor($r('app.color.kb_background'))
  }
}
