import { ImeController } from '../../ime/ImeController';
import { ImeState } from '../../ime/ImeState';
import { LayoutForm } from '../KeyDefinitions';
import {
  copyProfile,
  LayoutProfile,
  NumberRange,
  RANGE_BOTTOM_LIFT,
  RANGE_KEY_GAP,
  RANGE_KEYBOARD_HEIGHT,
  RANGE_OUTER_MARGIN,
  RANGE_PANE_WIDTH,
  RANGE_SPACE_WEIGHT
} from '../LayoutProfile';
import { SegmentedTabs } from './AileControls';

enum TunerField {
  HEIGHT = 'height',
  LEFT_WIDTH = 'leftWidth',
  RIGHT_WIDTH = 'rightWidth',
  LEFT_MARGIN = 'leftMargin',
  RIGHT_MARGIN = 'rightMargin',
  KEY_GAP = 'keyGap',
  SPACE_WEIGHT = 'spaceWeight',
  BOTTOM_LIFT = 'bottomLift'
}

interface TunerItem {
  field: TunerField;
  title: string;
  range: NumberRange;
  step: number;
  splitOnly: boolean;
}

const TUNER_ITEMS: TunerItem[] = [
  { field: TunerField.HEIGHT, title: '键盘高度', range: RANGE_KEYBOARD_HEIGHT, step: 2, splitOnly: false },
  { field: TunerField.BOTTOM_LIFT, title: '底部抬升', range: RANGE_BOTTOM_LIFT, step: 1, splitOnly: false },
  { field: TunerField.LEFT_WIDTH, title: '左区宽度', range: RANGE_PANE_WIDTH, step: 2, splitOnly: true },
  { field: TunerField.RIGHT_WIDTH, title: '右区宽度', range: RANGE_PANE_WIDTH, step: 2, splitOnly: true },
  { field: TunerField.LEFT_MARGIN, title: '左侧边距', range: RANGE_OUTER_MARGIN, step: 1, splitOnly: false },
  { field: TunerField.RIGHT_MARGIN, title: '右侧边距', range: RANGE_OUTER_MARGIN, step: 1, splitOnly: false },
  { field: TunerField.SPACE_WEIGHT, title: '空格宽度', range: RANGE_SPACE_WEIGHT, step: 0.1, splitOnly: true },
  { field: TunerField.KEY_GAP, title: '键间距', range: RANGE_KEY_GAP, step: 1, splitOnly: false }
];

function readField(profile: LayoutProfile, field: TunerField): number {
  switch (field) {
    case TunerField.HEIGHT:
      return profile.keyboardHeightVp;
    case TunerField.LEFT_WIDTH:
      return profile.leftPaneWidthVp;
    case TunerField.RIGHT_WIDTH:
      return profile.rightPaneWidthVp;
    case TunerField.LEFT_MARGIN:
      return profile.outerMarginLeftVp;
    case TunerField.RIGHT_MARGIN:
      return profile.outerMarginRightVp;
    case TunerField.KEY_GAP:
      return profile.keyGapVp;
    case TunerField.SPACE_WEIGHT:
      return profile.spaceWeight;
    default:
      return profile.bottomLiftVp;
  }
}

function writeField(profile: LayoutProfile, field: TunerField, value: number): void {
  switch (field) {
    case TunerField.HEIGHT:
      profile.keyboardHeightVp = value;
      break;
    case TunerField.LEFT_WIDTH:
      profile.leftPaneWidthVp = value;
      break;
    case TunerField.RIGHT_WIDTH:
      profile.rightPaneWidthVp = value;
      break;
    case TunerField.LEFT_MARGIN:
      profile.outerMarginLeftVp = value;
      break;
    case TunerField.RIGHT_MARGIN:
      profile.outerMarginRightVp = value;
      break;
    case TunerField.KEY_GAP:
      profile.keyGapVp = value;
      break;
    case TunerField.SPACE_WEIGHT:
      profile.spaceWeight = value;
      break;
    default:
      profile.bottomLiftVp = value;
      break;
  }
}

@ComponentV2
export struct LayoutTuner {
  @Local state: ImeState = ImeState.get();
  private controller: ImeController = ImeController.get();

  private change(field: TunerField, value: number, mode: SliderChangeMode): void {
    const orientation = this.state.currentOrientation();
    const profile = copyProfile(this.state.currentProfile());
    writeField(profile, field, value);
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.controller.updateProfile(orientation, profile);
    } else {
      this.controller.previewProfile(orientation, profile);
    }
  }

  private setForm(form: LayoutForm): void {
    const profile = copyProfile(this.state.currentProfile());
    profile.form = form;
    this.controller.updateProfile(this.state.currentOrientation(), profile);
  }

  private formatValue(item: TunerItem, value: number): string {
    return item.step < 1 ? value.toFixed(1) : `${Math.round(value)}`;
  }

  // 白色卡片悬浮在按键区中央，两侧按键保持可见，拖动滑块时实时预览布局
  build() {
    Column({ space: 6 }) {
      Row() {
        Text('布局形态')
          .tunerLabel()
          .layoutWeight(1)
        SegmentedTabs({
          items: ['分离', '常规'],
          selected: this.state.currentForm() === LayoutForm.SPLIT ? 0 : 1,
          itemPadding: 20,
          select: (index: number) => this.setForm(index === 0 ? LayoutForm.SPLIT : LayoutForm.NORMAL)
        })
      }
      .width('100%')
      .height(44)

      Divider()
        .strokeWidth(0.5)
        .color($r('app.color.kb_divider'))

      Scroll() {
        Column() {
          ForEach(TUNER_ITEMS, (item: TunerItem) => {
            if (!item.splitOnly || this.state.currentForm() === LayoutForm.SPLIT) {
              Row({ space: 10 }) {
                Text(item.title)
                  .tunerLabel()
                  .width(64)
                Slider({
                  value: readField(this.state.currentProfile(), item.field),
                  min: item.range.min,
                  max: item.range.max,
                  step: item.step
                })
                  .selectedColor($r('app.color.kb_accent'))
                  .trackColor($r('app.color.kb_segment_track'))
                  .blockColor(Color.White)
                  .trackThickness(4)
                  .layoutWeight(1)
                  .onChange((value: number, mode: SliderChangeMode) => this.change(item.field, value, mode))
                Text(this.formatValue(item, readField(this.state.currentProfile(), item.field)))
                  .fontSize(13)
                  .maxFontScale(1.2)
                  .fontColor($r('app.color.key_hint_text'))
                  .width(40)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .height(40)
            }
          }, (item: TunerItem) => item.field)
        }
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .padding({ left: 18, right: 18, top: 4, bottom: 8 })
    .backgroundColor($r('app.color.key_background'))
    .borderRadius(18)
    .shadow({ radius: 14, color: $r('app.color.key_popup_shadow'), offsetY: 4 })
  }
}

@Extend(Text)
function tunerLabel() {
  .fontSize(14)
  .maxFontScale(1.2)
  .fontColor($r('app.color.key_text'))
}
