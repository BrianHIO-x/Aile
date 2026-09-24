import { hasSwipeAction, KeyDef, KeyType } from './KeyDefinitions';
import { distanceToCell, hitTest, KeyRect } from './LayoutEngine';

export const SWIPE_UP_THRESHOLD_VP: number = 24;
// 已触发上滑后，回退到阈值的该比例以下才取消，避免在临界点来回闪烁
export const SWIPE_RELEASE_RATIO: number = 0.6;
// 上滑进度变化小于该值时不通知界面，控制刷新频率
const PROGRESS_STEP: number = 0.04;
export const HIT_SLOP_VP: number = 20;
export const LONG_PRESS_MS: number = 350;
export const REPEAT_INTERVAL_MS: number = 80;
// 横向滑动移动光标：空格键稍一横移即进入，字母键与标点键需要更明显的横移，避免打字时误触
const CURSOR_START_SPACE_VP: number = 10;
const CURSOR_START_KEY_VP: number = 28;
// 横移距离至少是竖移距离的这个倍数，才算横向滑动
const CURSOR_DIRECTION_RATIO: number = 1.5;
// 每移动这么远光标走一个字；手指移动较快时步长减半，长距离移动更省力
const CURSOR_STEP_VP: number = 9;
const CURSOR_FAST_STEP_VP: number = 4.5;
const CURSOR_FAST_SPEED: number = 0.6;

export class TouchTrack {
  pointerId: number;
  rect: KeyRect;
  startX: number;
  startY: number;
  lastX: number;
  lastY: number;
  downTime: number;
  swipeUp: boolean = false;
  // 上滑进度 0～1，用于键帽内的跟手动画
  progress: number = 0;
  cancelled: boolean = false;
  // 越过阈值即执行的上滑动作已经触发，之后的移动与抬起不再产生任何动作
  swipeFired: boolean = false;
  // 横向滑动进入光标模式后，这次触摸只移动光标，抬起时不输入任何内容
  cursorMode: boolean = false;
  // 光标模式下尚未交给编辑框的移动字数，负数向左
  cursorSteps: number = 0;
  // 已经换算成光标移动的横坐标
  cursorOriginX: number = 0;
  lastTime: number = 0;

  constructor(pointerId: number, rect: KeyRect, x: number, y: number, time: number) {
    this.pointerId = pointerId;
    this.rect = rect;
    this.startX = x;
    this.startY = y;
    this.lastX = x;
    this.lastY = y;
    this.downTime = time;
    this.lastTime = time;
  }
}

export interface KeyPress {
  key: KeyDef;
  swipeUp: boolean;
  pointerId: number;
  // 按下的按键与手指落下的位置，字母键据此计算误触纠错
  rect: KeyRect;
  x: number;
  y: number;
}

/**
 * 删除键在按下时立即执行，其余按键在抬起时执行。
 */
export function firesOnDown(key: KeyDef): boolean {
  return key.type === KeyType.DELETE;
}

/**
 * 删除键上滑越过阈值的瞬间执行清空，不等手指抬起；字母键与逗号键的上滑仍在抬起时输出。
 */
export function firesSwipeOnCommit(key: KeyDef): boolean {
  return key.type === KeyType.DELETE;
}

function cursorStartDistance(key: KeyDef): number {
  switch (key.type) {
    case KeyType.SPACE:
      return CURSOR_START_SPACE_VP;
    case KeyType.LETTER:
    case KeyType.CHAR:
    case KeyType.PUNCT:
      return CURSOR_START_KEY_VP;
    default:
      return -1;
  }
}

function cancelTolerance(rect: KeyRect): number {
  if (hasSwipeAction(rect.key)) {
    return rect.cellH * 2;
  }
  if (rect.key.type === KeyType.SPACE) {
    return rect.cellH * 0.8;
  }
  return Math.min(rect.cellW, rect.cellH) * 0.6;
}

/**
 * 纯逻辑触摸路由，按 pointerId 独立跟踪每根手指，坐标为键盘区域局部 vp。
 */
export class TouchRouter {
  private rects: KeyRect[] = [];
  private tracks: Map<number, TouchTrack> = new Map<number, TouchTrack>();

  setRects(rects: KeyRect[]): void {
    this.rects = rects;
    this.tracks.clear();
  }

  getRects(): KeyRect[] {
    return this.rects;
  }

  down(pointerId: number, x: number, y: number, time: number): TouchTrack | undefined {
    const rect = hitTest(this.rects, x, y, HIT_SLOP_VP);
    if (rect === undefined) {
      this.tracks.delete(pointerId);
      return undefined;
    }
    const track = new TouchTrack(pointerId, rect, x, y, time);
    this.tracks.set(pointerId, track);
    return track;
  }

  /**
   * 返回状态发生变化的触点，状态保持不变时返回 undefined。
   * swipeFired 由 false 变为 true 的那次移动只返回一次，调用方据此执行上滑动作。
   * 进入光标模式的那次移动，以及之后产生光标移动的每次移动，都返回触点，移动字数记在 cursorSteps 中。
   */
  move(pointerId: number, x: number, y: number, time: number): TouchTrack | undefined {
    const track = this.tracks.get(pointerId);
    if (track === undefined || track.cancelled) {
      return undefined;
    }
    const previousX = track.lastX;
    const previousTime = track.lastTime;
    track.lastX = x;
    track.lastY = y;
    track.lastTime = time;
    if (track.swipeFired) {
      return undefined;
    }
    if (track.cursorMode) {
      return this.stepCursor(track, x, Math.abs(x - previousX) / Math.max(1, time - previousTime)) ? track :
        undefined;
    }
    if (this.startsCursor(track, x, y)) {
      track.cursorMode = true;
      track.cursorOriginX = x;
      track.swipeUp = false;
      track.progress = 0;
      return track;
    }
    let changed = false;
    if (hasSwipeAction(track.rect.key)) {
      const lift = track.startY - y;
      const limit = track.swipeUp ? SWIPE_UP_THRESHOLD_VP * SWIPE_RELEASE_RATIO : SWIPE_UP_THRESHOLD_VP;
      const swipeUp = lift >= limit;
      const progress = swipeUp ? 1 : Math.max(0, Math.min(1, lift / SWIPE_UP_THRESHOLD_VP));
      if (swipeUp !== track.swipeUp) {
        track.swipeUp = swipeUp;
        changed = true;
      }
      if (Math.abs(progress - track.progress) >= PROGRESS_STEP || (progress === 0) !== (track.progress === 0) ||
        (progress === 1) !== (track.progress === 1)) {
        track.progress = progress;
        changed = true;
      }
      if (swipeUp && firesSwipeOnCommit(track.rect.key)) {
        track.swipeFired = true;
        return track;
      }
    }
    if (distanceToCell(track.rect, x, y) > cancelTolerance(track.rect)) {
      track.cancelled = true;
      changed = true;
    }
    return changed ? track : undefined;
  }

  // 横移明显大于竖移且越过起始距离时进入光标模式；已经触发上滑的按键不再进入
  private startsCursor(track: TouchTrack, x: number, y: number): boolean {
    const distance = cursorStartDistance(track.rect.key);
    if (distance < 0 || track.swipeUp) {
      return false;
    }
    const dx = Math.abs(x - track.startX);
    return dx >= distance && dx >= Math.abs(y - track.startY) * CURSOR_DIRECTION_RATIO;
  }

  // 把新增的横移换算成光标移动字数，不足一步的部分留到下次
  private stepCursor(track: TouchTrack, x: number, speed: number): boolean {
    const step = speed >= CURSOR_FAST_SPEED ? CURSOR_FAST_STEP_VP : CURSOR_STEP_VP;
    const steps = Math.trunc((x - track.cursorOriginX) / step);
    if (steps === 0) {
      return false;
    }
    track.cursorOriginX += steps * step;
    track.cursorSteps += steps;
    return true;
  }

  up(pointerId: number, x: number, y: number, time: number): KeyPress | undefined {
    const track = this.tracks.get(pointerId);
    if (track === undefined) {
      return undefined;
    }
    this.move(pointerId, x, y, time);
    this.tracks.delete(pointerId);
    if (track.cancelled || track.swipeFired || track.cursorMode || firesOnDown(track.rect.key)) {
      return undefined;
    }
    const press: KeyPress = {
      key: track.rect.key,
      swipeUp: track.swipeUp,
      pointerId: pointerId,
      rect: track.rect,
      x: track.startX,
      y: track.startY
    };
    return press;
  }

  cancel(pointerId: number): TouchTrack | undefined {
    const track = this.tracks.get(pointerId);
    if (track !== undefined) {
      track.cancelled = true;
      this.tracks.delete(pointerId);
    }
    return track;
  }

  cancelAll(): void {
    this.tracks.clear();
  }

  getTrack(pointerId: number): TouchTrack | undefined {
    return this.tracks.get(pointerId);
  }

  activeTracks(): TouchTrack[] {
    const result: TouchTrack[] = [];
    this.tracks.forEach((track: TouchTrack) => {
      if (!track.cancelled) {
        result.push(track);
      }
    });
    return result;
  }
}
