// Aile 顶部栏与功能面板共用的控件：自绘线条图标、圆形图标按钮、分段标签和功能磁贴。
import { snapAnimation } from '../Motion';

export enum AileIcon {
  MARK = 'mark',
  EMOJI = 'emoji',
  CLIPBOARD = 'clipboard',
  TUNE = 'tune',
  TOOLBAR = 'toolbar',
  SPLIT = 'split',
  NORMAL = 'normal',
  LEARN = 'learn',
  CLEAR = 'clear',
  PROBE = 'probe',
  LEXICON = 'lexicon',
  CLIP_HISTORY = 'clipHistory',
  PHRASE = 'phrase',
  PICK = 'pick',
  ADD = 'add',
  CLOSE = 'close',
  FUZZY = 'fuzzy',
  KEYBOARD = 'keyboard',
  // 以下几类沿用键盘按键上的系统符号，保持与删除键、收起按钮一致
  DELETE = 'delete',
  CHEVRON_DOWN = 'chevronDown',
  CHEVRON_UP = 'chevronUp',
  CHEVRON_LEFT = 'chevronLeft'
}

export const ROUND_BUTTON_SIZE_VP: number = 36;
export const TILE_SIZE_VP: number = 64;

function isSymbolIcon(icon: AileIcon): boolean {
  return icon === AileIcon.DELETE || icon === AileIcon.CHEVRON_DOWN || icon === AileIcon.CHEVRON_UP ||
    icon === AileIcon.CHEVRON_LEFT;
}

/**
 * 图标资源名必须在编译期确定，这里逐项列出常态与点亮两种资源。
 */
export function iconResource(icon: AileIcon, on: boolean): Resource {
  switch (icon) {
    case AileIcon.MARK:
      return $r('app.media.aile_mark');
    case AileIcon.EMOJI:
      return on ? $r('app.media.ic_emoji_on') : $r('app.media.ic_emoji');
    case AileIcon.CLIPBOARD:
      return on ? $r('app.media.ic_clipboard_on') : $r('app.media.ic_clipboard');
    case AileIcon.TUNE:
      return on ? $r('app.media.ic_tune_on') : $r('app.media.ic_tune');
    case AileIcon.TOOLBAR:
      return on ? $r('app.media.ic_toolbar_on') : $r('app.media.ic_toolbar');
    case AileIcon.SPLIT:
      return on ? $r('app.media.ic_split_on') : $r('app.media.ic_split');
    case AileIcon.NORMAL:
      return on ? $r('app.media.ic_normal_on') : $r('app.media.ic_normal');
    case AileIcon.LEARN:
      return on ? $r('app.media.ic_learn_on') : $r('app.media.ic_learn');
    case AileIcon.CLEAR:
      return on ? $r('app.media.ic_clear_on') : $r('app.media.ic_clear');
    case AileIcon.PROBE:
      return on ? $r('app.media.ic_probe_on') : $r('app.media.ic_probe');
    case AileIcon.LEXICON:
      return on ? $r('app.media.ic_lexicon_on') : $r('app.media.ic_lexicon');
    case AileIcon.CLIP_HISTORY:
      return on ? $r('app.media.ic_clip_history_on') : $r('app.media.ic_clip_history');
    case AileIcon.PHRASE:
      return on ? $r('app.media.ic_phrase_on') : $r('app.media.ic_phrase');
    case AileIcon.PICK:
      return on ? $r('app.media.ic_pick_on') : $r('app.media.ic_pick');
    case AileIcon.ADD:
      return on ? $r('app.media.ic_add_on') : $r('app.media.ic_add');
    case AileIcon.CLOSE:
      return on ? $r('app.media.ic_close_on') : $r('app.media.ic_close');
    case AileIcon.FUZZY:
      return on ? $r('app.media.ic_fuzzy_on') : $r('app.media.ic_fuzzy');
    default:
      return on ? $r('app.media.ic_keyboard_on') : $r('app.media.ic_keyboard');
  }
}

function symbolResource(icon: AileIcon): Resource {
  switch (icon) {
    case AileIcon.DELETE:
      return $r('sys.symbol.delete_left');
    case AileIcon.CHEVRON_UP:
      return $r('sys.symbol.chevron_up');
    case AileIcon.CHEVRON_LEFT:
      return $r('sys.symbol.chevron_left');
    default:
      return $r('sys.symbol.chevron_down');
  }
}

/**
 * 顶部栏圆形图标按钮。filled 为灰底实心按钮，否则为透明底、按下时显示灰底。
 * repeat 为 true 时长按连续触发，用于删除。rotation 变化时图标以弹簧动画转到新角度。
 */
@ComponentV2
export struct RoundIconButton {
  @Param icon: AileIcon = AileIcon.KEYBOARD;
  @Param iconSize: number = 22;
  @Param filled: boolean = false;
  @Param available: boolean = true;
  @Param accessibility: string = '';
  @Event action: () => void = () => {
  };
  @Event longAction: () => void = () => {
  };
  @Param repeat: boolean = false;
  @Param rotation: number = 0;

  @Styles
  clearNormal() {
    .backgroundColor(Color.Transparent)
  }

  @Styles
  filledNormal() {
    .backgroundColor($r('app.color.key_function_background'))
  }

  @Styles
  pressedStyle() {
    .backgroundColor($r('app.color.key_pressed_background'))
  }

  @Builder
  content() {
    if (isSymbolIcon(this.icon)) {
      // 动画只作用于其前面的属性，旋转写在最前面，尺寸与颜色的变化不做动画
      SymbolGlyph(symbolResource(this.icon))
        .rotate({ angle: this.rotation })
        .animation(snapAnimation())
        .fontSize(this.iconSize - 2)
        .fontColor([$r('app.color.key_text')])
    } else {
      Image(iconResource(this.icon, false))
        .rotate({ angle: this.rotation })
        .animation(snapAnimation())
        .width(this.iconSize)
        .height(this.iconSize)
        .objectFit(ImageFit.Contain)
        .draggable(false)
    }
  }

  private tap(): void {
    if (this.available) {
      this.action();
    }
  }

  private hold(): void {
    if (this.available) {
      this.longAction();
    }
  }

  // stateStyles 只接受固定的样式函数，实心与透明两种外观分支构建
  build() {
    if (this.filled) {
      Stack() {
        this.content()
      }
      .width(ROUND_BUTTON_SIZE_VP)
      .height(ROUND_BUTTON_SIZE_VP)
      .borderRadius(ROUND_BUTTON_SIZE_VP / 2)
      .stateStyles({ normal: this.filledNormal, pressed: this.pressedStyle })
      .opacity(this.available ? 1 : 0.35)
      .accessibilityText(this.accessibility)
      .onClick(() => this.tap())
      .gesture(LongPressGesture({ repeat: this.repeat }).onAction(() => this.hold()))
    } else {
      Stack() {
        this.content()
      }
      .width(ROUND_BUTTON_SIZE_VP)
      .height(ROUND_BUTTON_SIZE_VP)
      .borderRadius(ROUND_BUTTON_SIZE_VP / 2)
      .stateStyles({ normal: this.clearNormal, pressed: this.pressedStyle })
      .opacity(this.available ? 1 : 0.35)
      .accessibilityText(this.accessibility)
      .onClick(() => this.tap())
      .gesture(LongPressGesture({ repeat: this.repeat }).onAction(() => this.hold()))
    }
  }
}

/**
 * 分段标签：灰色轨道内的白色滑块标出当前项，切换时滑块以弹簧动画移到新位置并同步改变宽度。
 * selected 为 -1 表示本组没有选中项，滑块移到 parkAt 指定的项并淡出，分成两组的标签由此形成交接效果。
 * 各项文字统一使用中等字重，切换时宽度不变，滑块位置由各项实际布局宽度累加得到。
 */
@ComponentV2
export struct SegmentedTabs {
  @Param items: string[] = [];
  @Param selected: number = 0;
  @Param itemPadding: number = 16;
  @Param parkAt: number = 0;
  // 轨道底色，键盘内使用默认值，应用页面放在白色卡片上时换成更浅的灰色
  @Param trackColor: ResourceColor = $r('app.color.kb_segment_track');
  @Event select: (index: number) => void = () => {
  };
  @Local itemWidths: number[] = [];

  private setItemWidth(index: number, width: number): void {
    const widths = this.itemWidths.length === this.items.length ? this.itemWidths.slice() :
      this.items.map((): number => 0);
    if (index >= widths.length || Math.abs(widths[index] - width) < 0.5) {
      return;
    }
    widths[index] = width;
    this.itemWidths = widths;
  }

  private measured(): boolean {
    return this.items.length > 0 && this.itemWidths.length === this.items.length &&
      this.itemWidths.every((width: number) => width > 0);
  }

  private shownIndex(): number {
    const index = this.selected >= 0 ? this.selected : this.parkAt;
    return Math.max(0, Math.min(this.items.length - 1, index));
  }

  private sliderX(): number {
    let x = 0;
    for (let i = 0; i < this.shownIndex() && i < this.itemWidths.length; i++) {
      x += this.itemWidths[i];
    }
    return x;
  }

  private sliderWidth(): number {
    const index = this.shownIndex();
    return index < this.itemWidths.length ? this.itemWidths[index] : 0;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 滑块在所有宽度测得后才创建，首次出现时直接停在目标位置
      if (this.measured()) {
        Column()
          .width(this.sliderWidth())
          .height(30)
          .borderRadius(15)
          .backgroundColor($r('app.color.key_background'))
          .shadow({ radius: 2, color: $r('app.color.key_shadow'), offsetY: 1 })
          .translate({ x: this.sliderX() })
          .animation(snapAnimation())
          .opacity(this.selected >= 0 ? 1 : 0)
          .animation({ duration: 140, curve: Curve.FastOutSlowIn })
      }
      Row() {
        ForEach(this.items, (item: string, index: number) => {
          Text(item)
            .fontSize(14)
            .maxFontScale(1.2)
            .maxLines(1)
            .fontWeight(FontWeight.Medium)
            .fontColor(index === this.selected ? $r('app.color.key_text') : $r('app.color.key_hint_text'))
            .padding({ left: this.itemPadding, right: this.itemPadding })
            .height(30)
            .accessibilityText(item)
            .accessibilitySelected(index === this.selected)
            .onSizeChange((oldValue: SizeOptions, newValue: SizeOptions) =>
            this.setItemWidth(index, Number(newValue.width ?? 0)))
            .onClick(() => this.select(index))
        }, (item: string, index: number) => `${index}_${item}`)
      }
    }
    .padding(3)
    .height(36)
    .borderRadius(18)
    .backgroundColor(this.trackColor)
  }
}

/**
 * 功能磁贴：白色圆角方块，图标在上、文字在下；点亮时图标与文字变为强调色。
 * 外层占满一个网格列宽，磁贴在列内居中。
 */
@ComponentV2
export struct HubTile {
  @Param icon: AileIcon = AileIcon.KEYBOARD;
  @Param label: string = '';
  @Param active: boolean = false;
  @Param interactive: boolean = true;
  @Param cellWidth: number = TILE_SIZE_VP;
  @Event action: () => void = () => {
  };

  @Styles
  tileNormal() {
    .backgroundColor($r('app.color.key_background'))
  }

  @Styles
  tilePressed() {
    .backgroundColor($r('app.color.key_pressed_background'))
  }

  build() {
    Column() {
      Column({ space: 5 }) {
        Image(iconResource(this.icon, this.active))
          .width(24)
          .height(24)
          .objectFit(ImageFit.Contain)
          .draggable(false)
        Text(this.label)
          .fontSize(11)
          .maxFontScale(1.2)
          .maxLines(1)
          .fontColor(this.active ? $r('app.color.kb_accent') : $r('app.color.key_text'))
      }
      .justifyContent(FlexAlign.Center)
      .width(TILE_SIZE_VP)
      .height(TILE_SIZE_VP)
      .borderRadius(14)
      .shadow({ radius: 1, color: $r('app.color.key_shadow'), offsetY: 1 })
      .stateStyles({ normal: this.tileNormal, pressed: this.tilePressed })
      .accessibilityText(this.active ? `${this.label}，已开启` : this.label)
      .onClick(() => {
        if (this.interactive) {
          this.action();
        }
      })
    }
    .width(this.cellWidth)
    .alignItems(HorizontalAlign.Center)
  }
}
