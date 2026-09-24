// 简体中文字体中，全角标点只占字框的一半：句读类与后置括号引号在左半边，前置括号引号在右半边。
// 按字框居中排版时字形会偏左或偏右，需要按字号移动 1/4 字宽回到视觉中心。
const LEFT_HALF_GLYPHS: string = '，。、：；？！）」』】》〉”’';
const RIGHT_HALF_GLYPHS: string = '（「『【《〈“‘';
const QUARTER_EM: number = 0.25;

// 数字与大写字母只占基线以上的高度，按行框居中时视觉上偏低，上移少量字号比例
const CAP_HEIGHT_GLYPHS: RegExp = /^[0-9A-Z@#%&?!$]$/;
const CAP_HEIGHT_LIFT_EM: number = 0.05;

/**
 * 返回字形水平修正量占字号的比例，正值向右，负值向左。
 */
export function glyphShiftXEm(text: string): number {
  if (text.length !== 1) {
    return 0;
  }
  if (LEFT_HALF_GLYPHS.indexOf(text) >= 0) {
    return QUARTER_EM;
  }
  if (RIGHT_HALF_GLYPHS.indexOf(text) >= 0) {
    return -QUARTER_EM;
  }
  return 0;
}

/**
 * 返回字形竖直修正量占字号的比例，负值向上。
 */
export function glyphShiftYEm(text: string): number {
  return CAP_HEIGHT_GLYPHS.test(text) ? -CAP_HEIGHT_LIFT_EM : 0;
}
