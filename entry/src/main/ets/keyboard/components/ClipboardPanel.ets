import { ImeController } from '../../ime/ImeController';
import { ClipTab, ImeState } from '../../ime/ImeState';
import { drillInTransition, popTransition, slideInTransition } from '../Motion';
import { PanelZone, zoneColumns, zoneRows } from '../PanelZones';
import { AileIcon, iconResource } from './AileControls';
import { PickPanel } from './PickPanel';

const CLIP_CARD_MIN_WIDTH_VP: number = 140;
const CLIP_CARD_HEIGHT_VP: number = 60;
const CLIP_GAP_VP: number = 8;
const CLIP_MIN_COLUMNS: number = 2;
// 卡片最窄 140vp，四个操作按钮并排时仍能放下
const ACTION_WIDTH_VP: number = 34;
const ACTION_ICON_VP: number = 18;
// 显示操作按钮时其余卡片变淡，表示点按别处会先收起按钮
const DIMMED_CARD_OPACITY: number = 0.4;

interface ClipRow {
  key: string;
  zones: number[][];
}

interface ClipAction {
  icon: AileIcon;
  label: string;
  action: () => void;
}

// 下一次重建内容时使用的动效
enum ContentMotion {
  NONE = 0,
  FROM_LEFT = 1,
  FROM_RIGHT = 2,
  FADE = 3
}

/**
 * 剪贴板面板：剪贴板与常用语两个标签页共用卡片列表，点按上屏，长按显示操作按钮。
 * 分离布局下卡片分成左右两块，每行先排左手区再排右手区。进入滑动选字后整块区域换成选字界面。
 * 未授权读取时剪贴板页左手区顶部给出说明和粘贴控件，控件点击后系统放行一次读取。
 */
@ComponentV2
export struct ClipboardPanel {
  @Local state: ImeState = ImeState.get();
  @Param areaWidth: number = 0;
  @Param areaHeight: number = 0;
  // 底部手势横条高度，列表延伸到横条下方并在末尾留出同样的滚动余量
  @Param bottomInset: number = 0;
  @Param zones: PanelZone[] = [];
  private controller: ImeController = ImeController.get();
  private contentMotion: ContentMotion = ContentMotion.NONE;

  // 面板刚打开时内容随面板整体进入，只有切换标签页或进出选字时才给内容单独加动效
  @Monitor('state.clipTab')
  onClipTabChanged(monitor: IMonitor): void {
    this.contentMotion = this.state.clipTab === ClipTab.PHRASES ? ContentMotion.FROM_RIGHT : ContentMotion.FROM_LEFT;
  }

  @Monitor('state.pickTokens')
  onPickChanged(monitor: IMonitor): void {
    this.contentMotion = ContentMotion.FADE;
  }

  @Computed
  get columns(): number {
    return zoneColumns(this.zones, CLIP_CARD_MIN_WIDTH_VP, CLIP_GAP_VP, CLIP_MIN_COLUMNS);
  }

  // 删除一条后后续卡片的序号会前移，键值包含每条内容的摘要，行会随之重新构建
  @Computed
  get rows(): ClipRow[] {
    const items = this.state.currentClipItems();
    const geometry = this.zones.map((zone: PanelZone) => `${zone.x.toFixed(1)}_${zone.width.toFixed(1)}`).join('_');
    return zoneRows(items.length, this.columns, this.zones.length).map((zones: number[][], index: number) => {
      const digest = zones.map((indices: number[]) => indices.map((i: number) =>
      `${i}:${items[i].length}:${items[i].substring(0, 24)}`).join(',')).join('|');
      const row: ClipRow = {
        key: `${this.state.clipTab}_${this.columns}_${geometry}_${index}_${digest}`,
        zones: zones
      };
      return row;
    });
  }

  private cardWidth(zone: number): number {
    return Math.max(0, (this.zones[zone].width - CLIP_GAP_VP * (this.columns - 1)) / this.columns);
  }

  private itemText(index: number): string {
    const items = this.state.currentClipItems();
    return index >= 0 && index < items.length ? items[index] : '';
  }

  private isPhrases(): boolean {
    return this.state.clipTab === ClipTab.PHRASES;
  }

  private showNotice(): boolean {
    return !this.isPhrases() && !this.state.clipboardGranted && this.zones.length > 0;
  }

  private cardOpacity(index: number): number {
    const active = this.state.clipActionIndex;
    return active >= 0 && active !== index ? DIMMED_CARD_OPACITY : 1;
  }

  private tabTransition(): TransitionEffect {
    if (this.contentMotion === ContentMotion.FROM_LEFT) {
      return slideInTransition(-1);
    }
    if (this.contentMotion === ContentMotion.FROM_RIGHT) {
      return slideInTransition(1);
    }
    return TransitionEffect.IDENTITY;
  }

  private listTransition(): TransitionEffect {
    return this.contentMotion === ContentMotion.FADE ? slideInTransition(0) : TransitionEffect.IDENTITY;
  }

  private actions(index: number): ClipAction[] {
    const pick: ClipAction = { icon: AileIcon.PICK, label: '选字', action: () => this.controller.openPick(index) };
    const remove: ClipAction = {
      icon: AileIcon.CLEAR, label: '删除', action: () => this.controller.removeClipItem(index)
    };
    const cancel: ClipAction = {
      icon: AileIcon.CLOSE, label: '取消', action: () => this.controller.hideClipActions()
    };
    if (this.isPhrases()) {
      return [pick, remove, cancel];
    }
    const phrase: ClipAction = {
      icon: AileIcon.PHRASE, label: '常用语', action: () => this.controller.addClipToPhrases(index)
    };
    return [pick, phrase, remove, cancel];
  }

  @Styles
  cardNormal() {
    .backgroundColor($r('app.color.key_background'))
  }

  @Styles
  cardPressed() {
    .backgroundColor($r('app.color.key_pressed_background'))
  }

  @Styles
  actionNormal() {
    .backgroundColor(Color.Transparent)
  }

  @Styles
  actionPressed() {
    .backgroundColor($r('app.color.key_pressed_background'))
  }

  @Builder
  notice() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('尚未允许读取剪贴板')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .maxFontScale(1.2)
          .fontColor($r('app.color.key_text'))
        Text('在桌面打开 Aile 并允许读取剪贴板后，复制的文字会自动收录在这里')
          .fontSize(12)
          .maxFontScale(1.2)
          .fontColor($r('app.color.key_hint_text'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      PasteButton({ text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
        .fontSize(14)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.kb_accent'))
        .padding({ left: 18, right: 18, top: 8, bottom: 8 })
        .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
          if (result === PasteButtonOnClickResult.SUCCESS) {
            this.controller.pasteOnce();
          }
        })
    }
    .width(this.zones[0].width)
    .margin({ left: this.zones[0].x })
    .padding({ left: 16, right: 12, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor($r('app.color.key_background'))
  }

  @Builder
  actionButton(item: ClipAction) {
    Column({ space: 2 }) {
      Image(iconResource(item.icon, false))
        .width(ACTION_ICON_VP)
        .height(ACTION_ICON_VP)
        .objectFit(ImageFit.Contain)
        .draggable(false)
      Text(item.label)
        .fontSize(10)
        .maxFontScale(1.1)
        .maxLines(1)
        .fontColor($r('app.color.key_text'))
    }
    .justifyContent(FlexAlign.Center)
    .width(ACTION_WIDTH_VP)
    .height(CLIP_CARD_HEIGHT_VP - 12)
    .borderRadius(8)
    .stateStyles({ normal: this.actionNormal, pressed: this.actionPressed })
    .accessibilityText(item.label)
    .onClick(() => item.action())
  }

  // 动画只作用于其前面的属性，透明度写在最前面，按下态与尺寸变化不做动画
  @Builder
  clipCard(index: number, cardWidth: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      Text(this.itemText(index))
        .opacity(this.state.clipActionIndex === index ? 0 : 1)
        .animation({ duration: 120, curve: Curve.FastOutSlowIn })
        .fontSize(13)
        .maxFontScale(1.2)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor($r('app.color.key_text'))
        .align(Alignment.TopStart)
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .width('100%')
        .height('100%')
      if (this.state.clipActionIndex === index) {
        Row() {
          ForEach(this.actions(index), (item: ClipAction) => {
            this.actionButton(item)
          }, (item: ClipAction) => `${index}_${item.label}`)
        }
        .justifyContent(FlexAlign.SpaceEvenly)
        .width('100%')
        .height('100%')
        .transition(popTransition())
      }
    }
    .opacity(this.cardOpacity(index))
    .animation({ duration: 180, curve: Curve.FastOutSlowIn })
    .width(cardWidth)
    .height(CLIP_CARD_HEIGHT_VP)
    .borderRadius(10)
    .shadow({ radius: 1, color: $r('app.color.key_shadow'), offsetY: 1 })
    .stateStyles({ normal: this.cardNormal, pressed: this.cardPressed })
    .accessibilityText(`${this.isPhrases() ? '常用语' : '剪贴板'}第 ${index + 1} 条，点按输入，长按显示更多操作`)
    .onClick(() => this.controller.tapClipItem(index))
    .gesture(LongPressGesture({ repeat: false }).onAction(() => this.controller.showClipActions(index)))
  }

  @Builder
  clipRow(row: ClipRow) {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(row.zones, (indices: number[], zone: number) => {
        Row({ space: CLIP_GAP_VP }) {
          ForEach(indices, (index: number) => {
            this.clipCard(index, this.cardWidth(zone))
          }, (index: number) => `${index}`)
        }
        .width(this.zones[zone].width)
        .height(CLIP_CARD_HEIGHT_VP)
        .position({ x: this.zones[zone].x, y: 0 })
      }, (indices: number[], zone: number) => `${zone}_${indices.join('_')}`)
    }
    .width('100%')
    .height(CLIP_CARD_HEIGHT_VP)
  }

  @Builder
  emptyHint() {
    Column({ space: 6 }) {
      Text(this.isPhrases() ? '还没有常用语' : '复制的文字会出现在这里')
        .fontSize(14)
        .maxFontScale(1.2)
        .fontColor($r('app.color.key_hint_text'))
      if (this.isPhrases()) {
        Text('长按剪贴板里的文字后点“常用语”，就能把它存到这里。')
          .fontSize(12)
          .maxFontScale(1.2)
          .fontColor($r('app.color.key_hint_text'))
        Text('点顶部栏的加号，可以保存输入框里的文字。')
          .fontSize(12)
          .maxFontScale(1.2)
          .fontColor($r('app.color.key_hint_text'))
      }
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .layoutWeight(1)
    .margin({ bottom: this.bottomInset })
  }

  /**
   * 卡片列表按标签页整体构建，切换标签页时旧列表立即移除，新列表沿切换方向滑入。
   * 点按卡片以外的空白处或开始滚动时，收起正在显示的操作按钮。
   */
  @Builder
  cardList() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach([this.state.clipTab], (tab: number) => {
        Column({ space: 8 }) {
          if (this.showNotice()) {
            this.notice()
          }
          if (this.state.currentClipItems().length === 0) {
            this.emptyHint()
          } else {
            List({ space: CLIP_GAP_VP }) {
              ForEach(this.rows, (row: ClipRow) => {
                ListItem() {
                  this.clipRow(row)
                }
              }, (row: ClipRow) => row.key)
            }
            .contentEndOffset(this.bottomInset + CLIP_GAP_VP)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .width('100%')
            .layoutWeight(1)
            .onScrollStart(() => this.controller.hideClipActions())
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 8 })
        .width('100%')
        .height('100%')
        .transition(this.tabTransition())
      }, (tab: number) => `clip_tab_${tab}`)
    }
    .width('100%')
    .height('100%')
    .onClick(() => this.controller.hideClipActions())
    .transition(this.listTransition())
  }

  // 面板内的状态提示，显示在内容区底部中间
  @Builder
  statusToast() {
    Text(this.state.statusMessage)
      .fontSize(13)
      .maxFontScale(1.2)
      .fontColor($r('app.color.kb_accent_text'))
      .backgroundColor('#CC202124')
      .borderRadius(16)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .margin({ bottom: this.bottomInset + 12 })
      .hitTestBehavior(HitTestMode.None)
      .transition(popTransition())
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.state.isPicking()) {
        PickPanel({
          areaWidth: this.areaWidth,
          areaHeight: this.areaHeight,
          bottomInset: this.bottomInset,
          zones: this.zones
        })
          .transition(drillInTransition())
      } else {
        this.cardList()
      }
      if (this.state.statusMessage.length > 0) {
        this.statusToast()
      }
    }
    .width(this.areaWidth)
    .height(this.areaHeight)
    .backgroundColor($r('app.color.kb_background'))
  }
}
