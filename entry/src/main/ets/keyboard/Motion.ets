import { curves } from '@kit.ArkUI';

/**
 * 键盘内切换动效的统一参数。
 * 只对透明度、位移、缩放和旋转做动画，这几类属性由渲染服务直接插值，不会触发重新布局。
 * 大块内容切换时旧内容立即移除，新内容淡入，同一时刻只绘制一份内容。
 * TransitionEffect.OPACITY 是共享实例，调用 animation 或 combine 会改写所有使用处，这里一律用工厂方法新建。
 */

// 调试动效时临时放大全部时长，发布时保持为 1
const MOTION_SCALE: number = 1;

// 进入曲线起步快、收尾长，退出曲线逐渐加速
const ENTER_CURVE: curves.ICurve = curves.cubicBezierCurve(0.2, 0, 0, 1);
const EXIT_CURVE: curves.ICurve = curves.cubicBezierCurve(0.4, 0, 1, 1);

// 面板淡入完成、完全盖住按键所需的时间，之后按键停止绘制
export const PANEL_SETTLE_MS: number = Math.round(320 * MOTION_SCALE);

function scaled(duration: number): number {
  return Math.round(duration * MOTION_SCALE);
}

export function enterAnimation(duration: number): AnimateParam {
  return { duration: scaled(duration), curve: ENTER_CURVE };
}

export function exitAnimation(duration: number): AnimateParam {
  return { duration: scaled(duration), curve: EXIT_CURVE };
}

// 标签滑块、箭头旋转这类小幅运动使用高阻尼弹簧，几乎没有回弹
export function snapAnimation(): AnimateParam {
  return { curve: curves.springMotion(0.32 * MOTION_SCALE, 0.9) };
}

// 浮层弹出使用略带回弹的弹簧
function popAnimation(): AnimateParam {
  return { curve: curves.springMotion(0.3 * MOTION_SCALE, 0.78) };
}

/**
 * 整块面板：淡入并上移少许，退出时原地淡出，露出下方按键。
 */
export function panelTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.opacity(0).animation(enterAnimation(200))
      .combine(TransitionEffect.translate({ y: 16 }).animation(enterAnimation(280))),
    TransitionEffect.opacity(0).animation(exitAnimation(140))
  );
}

/**
 * 面板底色：面板之间互相切换时垫在下方，按键不会透出。
 */
export function backdropTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.opacity(0).animation(enterAnimation(200)),
    TransitionEffect.opacity(0).animation(exitAnimation(140))
  );
}

/**
 * 顶部栏整组内容：旧内容立即移除，新内容淡入。面板标题额外上移少许，与面板进入的方向一致。
 */
export function headerTransition(rise: boolean): TransitionEffect {
  if (!rise) {
    return TransitionEffect.asymmetric(TransitionEffect.opacity(0).animation(enterAnimation(140)),
      TransitionEffect.IDENTITY);
  }
  return TransitionEffect.asymmetric(
    TransitionEffect.opacity(0).animation(enterAnimation(200))
      .combine(TransitionEffect.translate({ y: 6 }).animation(enterAnimation(260))),
    TransitionEffect.IDENTITY
  );
}

/**
 * 标签页和分类切换：新内容沿切换方向滑入少许并淡入。direction 为 1 时从右侧进入，为 -1 时从左侧进入，为 0 时只淡入。
 */
export function slideInTransition(direction: number): TransitionEffect {
  const fade = TransitionEffect.opacity(0).animation(enterAnimation(180));
  if (direction === 0) {
    return TransitionEffect.asymmetric(fade, TransitionEffect.IDENTITY);
  }
  return TransitionEffect.asymmetric(
    fade.combine(TransitionEffect.translate({ x: 24 * direction }).animation(enterAnimation(260))),
    TransitionEffect.IDENTITY
  );
}

/**
 * 进入下一级内容，例如从剪贴板卡片进入滑动选字：淡入并从略小的尺寸展开。
 */
export function drillInTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.opacity(0).animation(enterAnimation(200))
      .combine(TransitionEffect.scale({ x: 0.97, y: 0.97 }).animation(enterAnimation(280))),
    TransitionEffect.IDENTITY
  );
}

/**
 * 操作按钮、提示胶囊这类小浮层：淡入并弹出，退出时快速淡出。
 */
export function popTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.opacity(0).animation(enterAnimation(160))
      .combine(TransitionEffect.scale({ x: 0.9, y: 0.9 }).animation(popAnimation())),
    TransitionEffect.opacity(0).animation(exitAnimation(100))
  );
}

/**
 * 浮在按键上方的卡片，例如布局校准：淡入并从略小的尺寸弹出，退出时淡出。
 */
export function cardTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.opacity(0).animation(enterAnimation(180))
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }).animation(popAnimation())),
    TransitionEffect.opacity(0).animation(exitAnimation(120))
  );
}
