// 滑动选字的切分规则：汉字、标点与表情各占一格，连续的英文字母或数字合为一格，连续空白合为一格。

// 选字界面最多展示的字符数，超出部分不参与切分
export const PICK_TEXT_LIMIT: number = 2000;

const ZERO_WIDTH_JOINER: number = 0x200d;

function isAsciiLetter(code: number): boolean {
  return (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);
}

function isAsciiDigit(code: number): boolean {
  return code >= 0x30 && code <= 0x39;
}

function isWhitespace(code: number): boolean {
  return code === 0x20 || code === 0x09 || code === 0x0a || code === 0x0d || code === 0x3000 || code === 0xa0;
}

// 附着在前一个字符上的码位：变体选择符、组合用键帽、肤色修饰与组合附加符号
function isAttached(code: number): boolean {
  return (code >= 0xfe00 && code <= 0xfe0f) || code === 0x20e3 || (code >= 0x1f3fb && code <= 0x1f3ff) ||
    (code >= 0x0300 && code <= 0x036f) || (code >= 0xe0020 && code <= 0xe007f);
}

function isRegionalIndicator(code: number): boolean {
  return code >= 0x1f1e6 && code <= 0x1f1ff;
}

function codePointAt(text: string, index: number): number {
  return text.codePointAt(index) ?? 0;
}

function codeUnits(code: number): number {
  return code > 0xffff ? 2 : 1;
}

/**
 * 从 start 开始取一个完整的显示字符，返回结束位置。表情的组合序列与国旗保持完整。
 */
function symbolEnd(text: string, start: number): number {
  const first = codePointAt(text, start);
  let end = start + codeUnits(first);
  if (isRegionalIndicator(first) && end < text.length && isRegionalIndicator(codePointAt(text, end))) {
    return end + 2;
  }
  while (end < text.length) {
    const code = codePointAt(text, end);
    if (isAttached(code)) {
      end += codeUnits(code);
    } else if (code === ZERO_WIDTH_JOINER && end + 1 < text.length) {
      end += 1;
      end += codeUnits(codePointAt(text, end));
    } else {
      break;
    }
  }
  return end;
}

export function splitPickTokens(text: string): string[] {
  const tokens: string[] = [];
  let i = 0;
  while (i < text.length) {
    const code = text.charCodeAt(i);
    let end = i + 1;
    if (isAsciiLetter(code)) {
      while (end < text.length && isAsciiLetter(text.charCodeAt(end))) {
        end++;
      }
    } else if (isAsciiDigit(code)) {
      // 数字中间的小数点随数字一起
      while (end < text.length && (isAsciiDigit(text.charCodeAt(end)) ||
        (text.charCodeAt(end) === 0x2e && end + 1 < text.length && isAsciiDigit(text.charCodeAt(end + 1))))) {
        end++;
      }
    } else if (isWhitespace(code)) {
      while (end < text.length && isWhitespace(text.charCodeAt(end))) {
        end++;
      }
    } else {
      end = symbolEnd(text, i);
    }
    tokens.push(text.substring(i, end));
    i = end;
  }
  return tokens;
}

export function isWhitespaceToken(token: string): boolean {
  return token.length > 0 && isWhitespace(token.charCodeAt(0));
}

/**
 * 英文单词、数字和空白按文字宽度排布，其余片段占一个方格。
 */
export function isWideToken(token: string): boolean {
  if (token.length === 0) {
    return false;
  }
  const code = token.charCodeAt(0);
  return isAsciiLetter(code) || isAsciiDigit(code) || isWhitespace(code);
}

// 空白在格子里显示为符号，换行显示为回车符
export function pickTokenLabel(token: string): string {
  if (!isWhitespaceToken(token)) {
    return token;
  }
  return token.indexOf('\n') >= 0 || token.indexOf('\r') >= 0 ? '↵' : '␣';
}

export function countCodePoints(text: string): number {
  let count = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      i++;
    }
    count++;
  }
  return count;
}
