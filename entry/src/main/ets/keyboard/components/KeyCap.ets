import { glyphShiftXEm } from '../GlyphMetrics';
import { KeyRect } from '../LayoutEngine';
import { snapAnimation } from '../Motion';

export enum KeyIcon {
  NONE = 'none',
  ENTER = 'enter',
  DELETE = 'delete',
  SHIFT_OFF = 'shiftOff',
  SHIFT_ONCE = 'shiftOnce',
  SHIFT_LOCK = 'shiftLock',
  LANG_ZH = 'langZh',
  LANG_EN = 'langEn'
}

// 上方小符号与主字符使用按键高度的固定比例定位，所有按键内的对齐完全一致
export const HINT_TOP_RATIO: number = 0.07;
export const HINT_HEIGHT_RATIO: number = 0.24;
export const LABEL_TOP_RATIO: number = 0.30;
export const LABEL_HEIGHT_RATIO: number = 0.60;

export function letterFontSize(w: number, h: number): number {
  return Math.max(14, Math.min(h * 0.42, w * 0.46, 26));
}

@ComponentV2
export struct KeyCap {
  @Require @Param rect: KeyRect;
  @Param label: string = '';
  @Param hint: string = '';
  @Param icon: KeyIcon = KeyIcon.NONE;
  @Param pressed: boolean = false;
  @Param functional: boolean = false;
  @Param accent: boolean = false;
  // 上滑进度 0～1 与是否已触发，用于键帽内的跟手动画
  @Param flickProgress: number = 0;
  @Param flickCommitted: boolean = false;
  // 中文逗号句号键：句号放大，逗号与句号相互靠近
  @Param punctZh: boolean = false;
  // 横向滑动移动光标时键帽上的文字与图标隐去，只留下空白键帽
  @Param muted: boolean = false;

  private textSize(): number {
    if (this.label.length >= 3) {
      return Math.max(12, Math.min(this.rect.h * 0.3, 16));
    }
    if (this.label.length === 2) {
      return Math.max(12, Math.min(this.rect.h * 0.32, 18));
    }
    return letterFontSize(this.rect.w, this.rect.h);
  }

  private hintSize(): number {
    const base = Math.max(10, Math.min(this.rect.h * 0.2, 13));
    return this.punctZh ? base * 1.25 : base;
  }

  // 全角标点按字形所在半边修正到视觉中心；句号下移、逗号上移，使两者略微靠近
  private hintOffsetX(): number {
    return glyphShiftXEm(this.hint) * this.hintSize();
  }

  private hintOffsetY(): number {
    const lift = -this.rect.h * 0.05 * this.flickProgress;
    return (this.punctZh ? 2 : 0) + lift;
  }

  private labelOffsetX(): number {
    return glyphShiftXEm(this.label) * this.textSize();
  }

  private labelOffsetY(): number {
    const sink = this.rect.h * 0.04 * this.flickProgress;
    return (this.punctZh ? -2 : 0) + sink;
  }

  private hintScale(): number {
    return 1 + 0.3 * this.flickProgress;
  }

  private labelOpacity(): number {
    return this.flickCommitted ? 0.18 : 1 - 0.45 * this.flickProgress;
  }

  private capBackground(): ResourceColor {
    if (this.flickProgress > 0) {
      return $r('app.color.key_flick_background');
    }
    if (this.pressed) {
      return $r('app.color.key_pressed_background');
    }
    if (this.accent) {
      return $r('app.color.kb_accent');
    }
    return this.functional ? $r('app.color.key_function_background') : $r('app.color.key_background');
  }

  private foreground(): ResourceColor {
    if (this.accent && !this.pressed) {
      return $r('app.color.kb_accent_text');
    }
    return $r('app.color.key_text');
  }

  private iconSize(): number {
    return Math.max(18, Math.min(this.rect.h * 0.4, 26));
  }

  private zhSelected(): boolean {
    return this.icon === KeyIcon.LANG_ZH;
  }

  // 两个字都按大号排版，未选中的一个用缩放变小。缩放由渲染服务插值，切换语言时两字平滑地交换大小
  private langScale(selected: boolean): number {
    return selected ? 1 : this.langSmall() / this.langLarge();
  }

  // 按值传入 @Builder 的参数变化不会刷新界面，语言状态必须在构建函数内读取 this.icon
  @Builder
  langContent() {
    // 中字在左上，英字在右下，当前语言黑色粗体放大，另一个灰色缩小
    Text('中')
      .scale({ x: this.langScale(this.zhSelected()), y: this.langScale(this.zhSelected()) })
      .animation(snapAnimation())
      .fontSize(this.langLarge())
      .fontWeight(this.zhSelected() ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.zhSelected() ? $r('app.color.key_text') : $r('app.color.key_hint_text'))
      .maxFontScale(1.1)
      .textAlign(TextAlign.Center)
      .width(this.rect.w * 0.4)
      .height(this.rect.h * 0.42)
      .position({ x: this.rect.w * 0.14, y: this.rect.h * 0.1 })
    Column()
      .width(this.rect.w * 0.09)
      .height(this.rect.h * 0.13)
      .border({
        width: { top: 1.2, right: 1.2 },
        color: $r('app.color.key_hint_text'),
        radius: { topRight: 4 }
      })
      .position({ x: this.rect.w * 0.56, y: this.rect.h * 0.25 })
    Column()
      .width(this.rect.w * 0.09)
      .height(this.rect.h * 0.13)
      .border({
        width: { left: 1.2, bottom: 1.2 },
        color: $r('app.color.key_hint_text'),
        radius: { bottomLeft: 4 }
      })
      .position({ x: this.rect.w * 0.35, y: this.rect.h * 0.62 })
    Text('英')
      .scale({ x: this.langScale(!this.zhSelected()), y: this.langScale(!this.zhSelected()) })
      .animation(snapAnimation())
      .fontSize(this.langLarge())
      .fontWeight(this.zhSelected() ? FontWeight.Normal : FontWeight.Bold)
      .fontColor(this.zhSelected() ? $r('app.color.key_hint_text') : $r('app.color.key_text'))
      .maxFontScale(1.1)
      .textAlign(TextAlign.Center)
      .width(this.rect.w * 0.4)
      .height(this.rect.h * 0.42)
      .position({ x: this.rect.w * 0.46, y: this.rect.h * 0.48 })
  }

  private langLarge(): number {
    return Math.max(13, Math.min(this.rect.h * 0.34, this.rect.w * 0.32, 22));
  }

  private langSmall(): number {
    return Math.max(10, Math.min(this.rect.h * 0.24, this.rect.w * 0.22, 15));
  }

  @Builder
  iconContent() {
    if (this.icon === KeyIcon.ENTER) {
      SymbolGlyph($r('sys.symbol.return_down_left'))
        .fontSize(this.iconSize())
        .fontColor([this.foreground()])
    } else if (this.icon === KeyIcon.DELETE) {
      // 删除键上滑清空时图标跟随淡出，与字母键的上滑动画一致
      SymbolGlyph($r('sys.symbol.delete_left'))
        .fontSize(this.iconSize())
        .fontColor([this.foreground()])
        .opacity(this.labelOpacity())
        .animation({ duration: 110, curve: Curve.FastOutSlowIn })
    } else if (this.icon === KeyIcon.SHIFT_ONCE) {
      SymbolGlyph($r('sys.symbol.arrowshape_up_fill'))
        .fontSize(this.iconSize())
        .fontColor([this.foreground()])
    } else if (this.icon === KeyIcon.SHIFT_LOCK) {
      SymbolGlyph($r('sys.symbol.arrowshape_up_to_line_fill'))
        .fontSize(this.iconSize())
        .fontColor([this.foreground()])
    } else {
      SymbolGlyph($r('sys.symbol.arrowshape_up'))
        .fontSize(this.iconSize())
        .fontColor([this.foreground()])
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 键帽内容放在同尺寸的内层容器里，光标模式时整体淡出，不影响上滑提示自身的动画
      Stack({ alignContent: Alignment.Center }) {
        if (this.icon === KeyIcon.LANG_ZH || this.icon === KeyIcon.LANG_EN) {
          this.langContent()
        } else if (this.icon !== KeyIcon.NONE) {
          this.iconContent()
        } else if (this.hint.length > 0) {
          Text(this.hint)
            .fontSize(this.hintSize())
            .fontColor($r('app.color.key_hint_text'))
            .maxFontScale(1.1)
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .width(this.rect.w)
            .height(this.rect.h * HINT_HEIGHT_RATIO)
            .position({ x: 0, y: this.rect.h * HINT_TOP_RATIO })
            .translate({ x: this.hintOffsetX(), y: this.hintOffsetY() })
            .scale({ x: this.hintScale(), y: this.hintScale(), centerX: '50%', centerY: '50%' })
            .opacity(this.flickCommitted ? 0 : 1)
            .animation({ duration: 110, curve: Curve.FastOutSlowIn })
          Text(this.label)
            .fontSize(this.textSize())
            .fontWeight(FontWeight.Medium)
            .fontColor(this.foreground())
            .maxFontScale(1.2)
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .width(this.rect.w)
            .height(this.rect.h * LABEL_HEIGHT_RATIO)
            .position({ x: 0, y: this.rect.h * LABEL_TOP_RATIO })
            .translate({ x: this.labelOffsetX(), y: this.labelOffsetY() })
            .opacity(this.labelOpacity())
            .animation({ duration: 110, curve: Curve.FastOutSlowIn })
        } else {
          Text(this.label)
            .fontSize(this.textSize())
            .fontWeight(FontWeight.Medium)
            .fontColor(this.foreground())
            .maxFontScale(1.2)
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .translate({ x: this.labelOffsetX() })
        }
      }
      .opacity(this.muted ? 0 : 1)
      .animation({ duration: 150, curve: Curve.FastOutSlowIn })
      .width(this.rect.w)
      .height(this.rect.h)
    }
    .position({ x: this.rect.x, y: this.rect.y })
    .width(this.rect.w)
    .height(this.rect.h)
    .borderRadius(8)
    .backgroundColor(this.capBackground())
    .shadow({ radius: 1, color: $r('app.color.key_shadow'), offsetY: 1 })
    .hitTestBehavior(HitTestMode.None)
  }
}
