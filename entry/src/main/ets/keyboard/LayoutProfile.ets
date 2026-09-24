import { LayoutForm } from './KeyDefinitions';

export enum ProfileOrientation {
  LANDSCAPE = 'landscape',
  PORTRAIT = 'portrait'
}

export interface LayoutProfile {
  form: LayoutForm;
  keyboardHeightVp: number;
  leftPaneWidthVp: number;
  rightPaneWidthVp: number;
  outerMarginLeftVp: number;
  outerMarginRightVp: number;
  keyGapVp: number;
  spaceWeight: number;
  bottomLiftVp: number;
}

export interface NumberRange {
  min: number;
  max: number;
}

export const CANDIDATE_BAR_HEIGHT_VP: number = 46;

// 面板底部为系统手势横条保留的空白，不计入键盘高度，按键尺寸保持不变。
// 小艺输入法在 MatePad Pro 12 模拟器（密度 2.25）上最下排按键白色底边距屏幕底边 66px，约 29vp；
// 按键矩形自带半个键间距（默认 3vp），面板底部留 27vp 时实测为 65px，与小艺相差 1px。
export const KEYBOARD_BOTTOM_INSET_VP: number = 27;

export const RANGE_KEYBOARD_HEIGHT: NumberRange = { min: 200, max: 480 };
export const RANGE_PANE_WIDTH: NumberRange = { min: 220, max: 560 };
export const RANGE_OUTER_MARGIN: NumberRange = { min: 0, max: 160 };
export const RANGE_KEY_GAP: NumberRange = { min: 2, max: 12 };
export const RANGE_SPACE_WEIGHT: NumberRange = { min: 1.5, max: 4 };
export const RANGE_BOTTOM_LIFT: NumberRange = { min: 0, max: 80 };

export function defaultProfile(orientation: ProfileOrientation): LayoutProfile {
  if (orientation === ProfileOrientation.LANDSCAPE) {
    const landscape: LayoutProfile = {
      form: LayoutForm.SPLIT,
      keyboardHeightVp: 300,
      leftPaneWidthVp: 330,
      rightPaneWidthVp: 300,
      outerMarginLeftVp: 12,
      outerMarginRightVp: 12,
      keyGapVp: 6,
      spaceWeight: 2.5,
      bottomLiftVp: 0
    };
    return landscape;
  }
  const portrait: LayoutProfile = {
    form: LayoutForm.NORMAL,
    keyboardHeightVp: 300,
    leftPaneWidthVp: 300,
    rightPaneWidthVp: 272,
    outerMarginLeftVp: 6,
    outerMarginRightVp: 6,
    keyGapVp: 6,
    spaceWeight: 2.5,
    bottomLiftVp: 0
  };
  return portrait;
}

export function clampNumber(value: number, range: NumberRange, fallback: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return fallback;
  }
  return Math.max(range.min, Math.min(range.max, value));
}

export function sanitizeProfile(raw: LayoutProfile | undefined | null, orientation: ProfileOrientation): LayoutProfile {
  const base = defaultProfile(orientation);
  if (raw === undefined || raw === null) {
    return base;
  }
  const form = raw.form === LayoutForm.SPLIT || raw.form === LayoutForm.NORMAL ? raw.form : base.form;
  const result: LayoutProfile = {
    form: form,
    keyboardHeightVp: clampNumber(raw.keyboardHeightVp, RANGE_KEYBOARD_HEIGHT, base.keyboardHeightVp),
    leftPaneWidthVp: clampNumber(raw.leftPaneWidthVp, RANGE_PANE_WIDTH, base.leftPaneWidthVp),
    rightPaneWidthVp: clampNumber(raw.rightPaneWidthVp, RANGE_PANE_WIDTH, base.rightPaneWidthVp),
    outerMarginLeftVp: clampNumber(raw.outerMarginLeftVp, RANGE_OUTER_MARGIN, base.outerMarginLeftVp),
    outerMarginRightVp: clampNumber(raw.outerMarginRightVp, RANGE_OUTER_MARGIN, base.outerMarginRightVp),
    keyGapVp: clampNumber(raw.keyGapVp, RANGE_KEY_GAP, base.keyGapVp),
    spaceWeight: clampNumber(raw.spaceWeight, RANGE_SPACE_WEIGHT, base.spaceWeight),
    bottomLiftVp: clampNumber(raw.bottomLiftVp, RANGE_BOTTOM_LIFT, base.bottomLiftVp)
  };
  return result;
}

export function copyProfile(profile: LayoutProfile): LayoutProfile {
  const copy: LayoutProfile = {
    form: profile.form,
    keyboardHeightVp: profile.keyboardHeightVp,
    leftPaneWidthVp: profile.leftPaneWidthVp,
    rightPaneWidthVp: profile.rightPaneWidthVp,
    outerMarginLeftVp: profile.outerMarginLeftVp,
    outerMarginRightVp: profile.outerMarginRightVp,
    keyGapVp: profile.keyGapVp,
    spaceWeight: profile.spaceWeight,
    bottomLiftVp: profile.bottomLiftVp
  };
  return copy;
}

/**
 * 解析保存的档案文本，内容损坏时回退为默认档案。
 */
export function parseProfile(text: string, orientation: ProfileOrientation): LayoutProfile {
  if (text.length === 0) {
    return sanitizeProfile(undefined, orientation);
  }
  try {
    const raw = JSON.parse(text) as LayoutProfile;
    return sanitizeProfile(raw, orientation);
  } catch (error) {
    return sanitizeProfile(undefined, orientation);
  }
}
