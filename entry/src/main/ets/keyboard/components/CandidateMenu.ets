import { ImeController } from '../../ime/ImeController';
import { CandidateAnchor, ImeState } from '../../ime/ImeState';
import { popTransition } from '../Motion';

const MENU_ITEM_WIDTH_VP: number = 88;
export const MENU_HEIGHT_VP: number = 40;
// 菜单与候选之间、菜单与键盘边缘之间留的空隙
const MENU_GAP_VP: number = 6;
const MENU_EDGE_VP: number = 8;
const MENU_DIVIDER_VP: number = 0.5;
export const NOTICE_FONT_VP: number = 14;
export const NOTICE_PADDING_VP: number = 14;
export const NOTICE_SPACE_VP: number = 12;
// 撤销提示里的词超过这么多个字时只显示开头一段
const NOTICE_WORD_CHARS: number = 8;

export interface MenuPoint {
  x: number;
  y: number;
}

/**
 * 菜单与撤销提示贴着候选弹出：横向以候选中线居中，碰到键盘边缘时收回来；下方放得下就放在下方，否则放在上方。
 */
export function popupPoint(anchor: CandidateAnchor, width: number, height: number, areaWidth: number,
  areaHeight: number): MenuPoint {
  const centered = anchor.x + anchor.w / 2 - width / 2;
  const x = Math.max(MENU_EDGE_VP, Math.min(centered, areaWidth - width - MENU_EDGE_VP));
  const below = anchor.y + anchor.h + MENU_GAP_VP;
  const y = below + height <= areaHeight - MENU_EDGE_VP ? below : Math.max(0, anchor.y - MENU_GAP_VP - height);
  const point: MenuPoint = { x: x, y: y };
  return point;
}

export function menuWidth(): number {
  return MENU_ITEM_WIDTH_VP * 2 + MENU_DIVIDER_VP;
}

export function noticeText(word: string): string {
  const shown = word.length > NOTICE_WORD_CHARS ? `${word.substring(0, NOTICE_WORD_CHARS)}…` : word;
  return `已删除“${shown}”`;
}

/**
 * 长按候选弹出的菜单：固定首位（已固定时为取消固定）与删除。
 * 只在菜单打开时挂到键盘页面最上层，整块键盘铺一层透明遮罩。点按菜单以外的地方只关闭菜单，这次按下不输入。
 */
@ComponentV2
export struct CandidateMenu {
  @Local state: ImeState = ImeState.get();
  // 挂上以后再把菜单弹出来，遮罩本身没有外观，不需要动画
  @Local shown: boolean = false;
  @Param areaWidth: number = 0;
  @Param areaHeight: number = 0;
  private controller: ImeController = ImeController.get();

  private point(): MenuPoint {
    return popupPoint(this.state.menuAnchor, menuWidth(), MENU_HEIGHT_VP, this.areaWidth, this.areaHeight);
  }

  @Styles
  itemNormal() {
    .backgroundColor(Color.Transparent)
  }

  @Styles
  itemPressed() {
    .backgroundColor($r('app.color.key_pressed_background'))
  }

  @Builder
  menuItem(label: string, danger: boolean, action: () => void) {
    Text(label)
      .fontSize(14)
      .maxFontScale(1.2)
      .maxLines(1)
      .fontColor(danger ? $r('app.color.kb_danger') : $r('app.color.key_text'))
      .textAlign(TextAlign.Center)
      .width(MENU_ITEM_WIDTH_VP)
      .height('100%')
      .stateStyles({ normal: this.itemNormal, pressed: this.itemPressed })
      .accessibilityText(label)
      .onClick(() => action())
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.controller.closeCandidateMenu();
          }
        })
      if (this.shown) {
        Row() {
          this.menuItem(this.state.menuPinned ? '取消固定' : '固定首位', false,
            () => this.controller.togglePinCandidate())
          Column()
            .width(MENU_DIVIDER_VP)
            .height(MENU_HEIGHT_VP / 2)
            .backgroundColor($r('app.color.kb_divider'))
          this.menuItem('删除', true, () => this.controller.removeCandidate())
        }
        .height(MENU_HEIGHT_VP)
        .borderRadius(MENU_HEIGHT_VP / 2)
        .clip(true)
        .backgroundColor($r('app.color.key_background'))
        .shadow({ radius: 12, color: $r('app.color.key_popup_shadow'), offsetY: 3 })
        .position({ x: this.point().x, y: this.point().y })
        .transition(popTransition())
      }
    }
    .width('100%')
    .height('100%')
    .onAppear(() => {
      this.shown = true;
    })
  }
}

/**
 * 删除候选以后的撤销提示，整块胶囊点按即撤销。键盘页面按文字宽度把它放在原来的候选旁边。
 */
@ComponentV2
export struct RemovedNotice {
  @Param word: string = '';
  private controller: ImeController = ImeController.get();

  @Styles
  noticeNormal() {
    .opacity(1)
  }

  @Styles
  noticePressed() {
    .opacity(0.72)
  }

  build() {
    Row({ space: NOTICE_SPACE_VP }) {
      Text(noticeText(this.word))
        .fontSize(NOTICE_FONT_VP)
        .maxFontScale(1)
        .maxLines(1)
        .fontColor($r('app.color.kb_accent_text'))
      Text('撤销')
        .fontSize(NOTICE_FONT_VP)
        .maxFontScale(1)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.kb_accent_text'))
    }
    .height(MENU_HEIGHT_VP)
    .padding({ left: NOTICE_PADDING_VP, right: NOTICE_PADDING_VP })
    .borderRadius(MENU_HEIGHT_VP / 2)
    .backgroundColor($r('app.color.kb_accent'))
    .shadow({ radius: 12, color: $r('app.color.key_popup_shadow'), offsetY: 3 })
    .stateStyles({ normal: this.noticeNormal, pressed: this.noticePressed })
    .accessibilityText(`${noticeText(this.word)}，点按撤销`)
    .onClick(() => this.controller.undoRemoveCandidate())
  }
}
