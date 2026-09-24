import { curves } from '@kit.ArkUI';
import { glyphShiftXEm, glyphShiftYEm } from '../GlyphMetrics';

// 提示块相对按键的尺寸比例，平板上提示块小于按键
export const FLICK_PREVIEW_SCALE: number = 0.8;
// 提示块底边与按键顶边的间距
export const FLICK_PREVIEW_GAP_VP: number = 8;

/**
 * 上滑提示块：越过触发阈值时从按键顶部弹性升起，未触发时保持缩小透明。
 * 外层负责位置、背景与弹性动画，内层文字只做字形位置修正，两者互不影响。
 * 坐标为键盘页面根容器坐标，单位 vp。
 */
@ComponentV2
export struct FlickPreview {
  @Param keyX: number = 0;
  @Param keyY: number = 0;
  @Param keyW: number = 0;
  @Param keyH: number = 0;
  @Param text: string = '';
  @Param committed: boolean = false;
  // 清空这类一次删除大量内容的动作用警示色显示
  @Param danger: boolean = false;

  private boxW(): number {
    return this.keyW * FLICK_PREVIEW_SCALE;
  }

  private boxH(): number {
    return this.keyH * FLICK_PREVIEW_SCALE;
  }

  private boxX(): number {
    return this.keyX + (this.keyW - this.boxW()) / 2;
  }

  private boxY(): number {
    return Math.max(2, this.keyY - this.boxH() - FLICK_PREVIEW_GAP_VP);
  }

  // 多字提示按提示块宽度缩小，保证两侧留有边距
  private fontSize(): number {
    const size = Math.max(18, Math.min(this.boxH() * 0.6, 30));
    if (this.text.length <= 1) {
      return size;
    }
    return Math.max(14, Math.min(size * 0.8, this.boxW() * 0.8 / this.text.length));
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.text)
        .fontSize(this.fontSize())
        .fontWeight(FontWeight.Medium)
        .fontColor(this.danger ? $r('app.color.kb_danger') : $r('app.color.key_text'))
        .maxFontScale(1.1)
        .maxLines(1)
        .textAlign(TextAlign.Center)
        .translate({
          x: glyphShiftXEm(this.text) * this.fontSize(),
          y: glyphShiftYEm(this.text) * this.fontSize()
        })
    }
    .width(this.boxW())
    .height(this.boxH())
    .position({ x: this.boxX(), y: this.boxY() })
    .backgroundColor($r('app.color.key_background'))
    .borderRadius(10)
    .border({ width: 0.5, color: $r('app.color.kb_divider') })
    .shadow({ radius: 18, color: $r('app.color.key_popup_shadow'), offsetY: 6 })
    .scale({
      x: this.committed ? 1 : 0.7,
      y: this.committed ? 1 : 0.7,
      centerX: '50%',
      centerY: '100%'
    })
    .translate({ y: this.committed ? 0 : this.boxH() * 0.3 })
    .opacity(this.committed ? 1 : 0)
    .animation({ curve: curves.springMotion(0.28, 0.78) })
    .hitTestBehavior(HitTestMode.None)
  }
}
