"""Aile 30s promo renderer: composes emulator screenshots into 1920x1080 frames, writes MJPEG AVI."""
import math
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

from avi_writer import MjpegAviWriter

W, H, FPS, DUR = 1920, 1080, 30, 30.0
RAW = 'raw'
ACCENT = (10, 89, 247)
INK = (22, 24, 29)
SUB = (96, 101, 112)
FONT_BOLD = 'C:/Windows/Fonts/msyhbd.ttc'
FONT_REG = 'C:/Windows/Fonts/msyh.ttc'
FONT_LATIN = 'C:/Windows/Fonts/segoeuib.ttf'


# ---------- easing ----------

def clamp01(x):
    return max(0.0, min(1.0, x))


def prog(t, a, b):
    return clamp01((t - a) / (b - a))


def ease_out(x):
    x = clamp01(x)
    return 1 - (1 - x) ** 3


def ease_in_out(x):
    x = clamp01(x)
    return 4 * x ** 3 if x < 0.5 else 1 - (-2 * x + 2) ** 3 / 2


def ease_back(x):
    x = clamp01(x)
    c1 = 1.70158
    return 1 + (c1 + 1) * (x - 1) ** 3 + c1 * (x - 1) ** 2


def with_alpha(img, a):
    if a >= 0.999:
        return img
    r, g, b, al = img.split()
    al = al.point(lambda v: int(v * a))
    return Image.merge('RGBA', (r, g, b, al))


def rounded_mask(w, h, r, ss=3):
    m = Image.new('L', (w * ss, h * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w * ss - 1, h * ss - 1), r * ss, fill=255)
    return m.resize((w, h), Image.LANCZOS)


def soft_shadow(w, h, r, blur, opacity, pad):
    m = Image.new('L', (w + pad * 2, h + pad * 2), 0)
    ImageDraw.Draw(m).rounded_rectangle((pad, pad, pad + w, pad + h), r, fill=int(255 * opacity))
    m = m.filter(ImageFilter.GaussianBlur(blur))
    shadow = Image.new('RGBA', m.size, (20, 32, 64, 0))
    shadow.putalpha(m)
    return shadow


# ---------- text ----------

_fonts = {}


def font(path, size):
    key = (path, size)
    if key not in _fonts:
        _fonts[key] = ImageFont.truetype(path, size)
    return _fonts[key]


_text_cache = {}


def text_image(text, path, size, fill):
    key = (text, path, size, fill)
    if key in _text_cache:
        return _text_cache[key]
    f = font(path, size)
    l, t, r, b = f.getbbox(text)
    pad = 8
    img = Image.new('RGBA', (r - l + pad * 2, b - t + pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(img).text((pad - l, pad - t), text, font=f, fill=fill)
    _text_cache[key] = img
    return img


def chip_image(text):
    key = ('chip', text)
    if key in _text_cache:
        return _text_cache[key]
    label = text_image(text, FONT_BOLD, 26, ACCENT + (255,))
    w, h = label.width + 36, 54
    img = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle((0, 0, w - 1, h - 1), h // 2, fill=(223, 232, 255, 255))
    img.alpha_composite(label, ((w - label.width) // 2, (h - label.height) // 2))
    _text_cache[key] = img
    return img


def draw_centered(frame, img, cx, cy, alpha=1.0):
    x = int(round(cx - img.width / 2))
    y = int(round(cy - img.height / 2))
    frame.alpha_composite(with_alpha(img, alpha), (x, y))


def draw_caption(frame, chip, title, local, alpha, top=112):
    appear = ease_out(prog(local, 0.05, 0.6))
    a = alpha * appear
    if a <= 0.003:
        return
    rise = (1 - appear) * 26
    draw_centered(frame, chip_image(chip), W / 2, top + rise, a)
    draw_centered(frame, text_image(title, FONT_BOLD, 54, INK + (255,)), W / 2, top + 86 + rise * 1.4, a)


# ---------- brand mark ----------

def render_mark(size, bar=1.0, ss=4):
    k = size * ss / 48.0
    img = Image.new('RGBA', (size * ss, size * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def stroke(p0, p1, width, color):
        d.line((p0[0] * k, p0[1] * k, p1[0] * k, p1[1] * k), fill=color, width=int(width * k))
        rr = width * k / 2
        for p in (p0, p1):
            d.ellipse((p[0] * k - rr, p[1] * k - rr, p[0] * k + rr, p[1] * k + rr), fill=color)

    ink = (27, 28, 30, 255)
    stroke((20, 8.5), (9.5, 39.5), 6.5, ink)
    stroke((28, 8.5), (38.5, 39.5), 6.5, ink)
    if bar > 0.01:
        half = 4.6 * bar
        stroke((24 - half, 32.5), (24 + half, 32.5), 5, ACCENT + (255,))
    return img.resize((size, size), Image.LANCZOS)


_mark_cache = {}


def mark(size, bar):
    q = round(bar * 20) / 20
    key = (size, q)
    if key not in _mark_cache:
        _mark_cache[key] = render_mark(size, q)
    return _mark_cache[key]


# ---------- background ----------

def make_background():
    y = np.linspace(0, 1, H)[:, None]
    top = np.array([248, 249, 252], dtype=np.float32)
    bottom = np.array([231, 235, 243], dtype=np.float32)
    grad = top + (bottom - top) * y[..., None]
    arr = np.repeat(grad, W, axis=1)
    bg = Image.fromarray(arr.astype(np.uint8), 'RGB').convert('RGBA')
    glow = Image.new('L', (W, H), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse((-260, -320, 760, 520), fill=90)
    gd.ellipse((1260, 620, 2260, 1400), fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(160))
    tint = Image.new('RGBA', (W, H), (190, 210, 255, 0))
    tint.putalpha(glow)
    bg.alpha_composite(tint)
    return bg


# ---------- screenshots ----------

STRIP_Y0, STRIP_H = 960, 880
CARD_W = 1680
S = CARD_W / 2800
CARD_H = round(STRIP_H * S)
CARD_X = (W - CARD_W) // 2
CARD_Y = 392
CARD_MASK = rounded_mask(CARD_W, CARD_H, 30)
CARD_SHADOW = soft_shadow(CARD_W, CARD_H, 30, 28, 0.22, 80)


def load(name):
    return Image.open(f'{RAW}/{name}.jpeg').convert('RGB')


def strip(img):
    """Native-resolution strip; the camera crops and scales it per frame."""
    return img.crop((0, STRIP_Y0, 2800, STRIP_Y0 + STRIP_H))


class Camera:
    """zoom >= 1, focus in screenshot px. Window is clamped inside the strip."""

    def __init__(self, zoom=1.0, fx=1400.0, fy=STRIP_Y0 + STRIP_H / 2):
        vw = 2800 / zoom
        vh = STRIP_H / zoom
        self.x0 = min(max(fx - vw / 2, 0), 2800 - vw)
        self.y0 = min(max(fy - vh / 2, STRIP_Y0), STRIP_Y0 + STRIP_H - vh)
        self.vw = vw
        self.vh = vh
        self.scale = CARD_W / vw

    def view(self, content):
        box = (self.x0, self.y0 - STRIP_Y0, self.x0 + self.vw, self.y0 - STRIP_Y0 + self.vh)
        return content.resize((CARD_W, CARD_H), Image.LANCZOS, box=box)

    def xy(self, px, py):
        return (px - self.x0) * self.scale, (py - self.y0) * self.scale


CAM = Camera()


def lerp(a, b, x):
    return a + (b - a) * x


def camera_path(local, keys):
    """keys: list of (time, zoom, fx, fy); eased interpolation between consecutive keys."""
    if local <= keys[0][0]:
        k = keys[0]
        return Camera(k[1], k[2], k[3])
    for a, b in zip(keys, keys[1:]):
        if local <= b[0]:
            x = ease_in_out(prog(local, a[0], b[0]))
            return Camera(lerp(a[1], b[1], x), lerp(a[2], b[2], x), lerp(a[3], b[3], x))
    k = keys[-1]
    return Camera(k[1], k[2], k[3])


def card_xy(px, py, cam=None):
    return (cam or CAM).xy(px, py)


def blend_states(states, t):
    """states: list of (switch_time, image, fade). Returns blended image at time t."""
    current = states[0][1]
    for switch, img, fade in states[1:]:
        if t < switch:
            break
        a = ease_in_out(prog(t, switch, switch + fade))
        current = img if a >= 0.999 else Image.blend(current, img, a)
    return current


def draw_card(frame, content, alpha, overlay=None, dy=0.0, cam=None):
    card = (cam or CAM).view(content).convert('RGBA')
    if overlay is not None:
        card.alpha_composite(overlay)
    card.putalpha(CARD_MASK)
    y = int(round(CARD_Y + dy))
    frame.alpha_composite(with_alpha(CARD_SHADOW, alpha), (CARD_X - 80, y - 80 + 20))
    frame.alpha_composite(with_alpha(card, alpha), (CARD_X, y))


def touch(d, x, y, a, pressed=0.0, trail_from=None):
    """Touch indicator in overlay coordinates: translucent ring so the UI underneath stays readable."""
    if a <= 0.01:
        return
    r = 28 - 5 * pressed
    if trail_from is not None:
        tx, ty = trail_from
        w = int(r * 1.2)
        d.line((tx, ty, x, y), fill=ACCENT + (int(60 * a),), width=w)
        d.ellipse((tx - w / 2, ty - w / 2, tx + w / 2, ty + w / 2), fill=ACCENT + (int(60 * a),))
    d.ellipse((x - r - 4, y - r - 4, x + r + 4, y + r + 4), outline=(255, 255, 255, int(170 * a)), width=4)
    d.ellipse((x - r, y - r, x + r, y + r), fill=ACCENT + (int((70 + 60 * pressed) * a),),
              outline=ACCENT + (int(235 * a),), width=4)


SWIPE_LIFT_PX = 45


def swipe_touch(d, cam, px, py, local, appear, move_start, move_end, lift_start, lift_end):
    x, y0 = cam.xy(px, py)
    a = ease_out(prog(local, appear, appear + 0.15)) * (1 - ease_out(prog(local, lift_start, lift_end)))
    m = ease_in_out(prog(local, move_start, move_end))
    y = y0 - SWIPE_LIFT_PX * cam.scale * m
    touch(d, x, y, a, pressed=0.0, trail_from=(x, y0) if m > 0.02 else None)


def highlight_box(d, box_px, a, pulse=0.0, radius=18, width=5, cam=None):
    if a <= 0.01:
        return
    x0, y0 = card_xy(box_px[0], box_px[1], cam)
    x1, y1 = card_xy(box_px[2], box_px[3], cam)
    grow = 6 * pulse
    d.rounded_rectangle((x0 - grow, y0 - grow, x1 + grow, y1 + grow), radius + grow,
                        outline=ACCENT + (int(255 * a),), width=width)


# ---------- assets ----------

BG = make_background()
IMG = {name: load(name) for name in (
    'idle_text', 'compose1', 'compose2', 'flick_letter', 'flick_punct',
    'clear_hold', 'clear_after', 'undo_done', 'emoji', 'hub')}

# 标点上滑前的画面：文字取自上滑截图（句号尚未输入），键盘区域取自空闲截图（没有提示块）
base_punct = IMG['flick_punct'].copy()
base_punct.paste(IMG['idle_text'].crop((0, 1100, 2800, 1840)), (0, 1100))

ST = {
    'idle': strip(IMG['idle_text']),
    'compose1': strip(IMG['compose1']),
    'compose2': strip(IMG['compose2']),
    'base_punct': strip(base_punct),
    'flick_punct': strip(IMG['flick_punct']),
    'flick_letter': strip(IMG['flick_letter']),
    'clear_hold': strip(IMG['clear_hold']),
    'clear_after': strip(IMG['clear_after']),
    'undo': strip(IMG['undo_done']),
    'emoji': strip(IMG['emoji']),
    'hub': strip(IMG['hub']),
}

# 片头与片尾之外的完整平板画面
SCREEN_W = 1096
HS = SCREEN_W / 2800
SCREEN_H = round(1840 * HS)
BEZEL = 22
DEV_W, DEV_H = SCREEN_W + BEZEL * 2, SCREEN_H + BEZEL * 2
DEV_X = (W - DEV_W) // 2
DEV_Y = 268
device_base = Image.new('RGBA', (DEV_W, DEV_H), (0, 0, 0, 0))
ImageDraw.Draw(device_base).rounded_rectangle((0, 0, DEV_W - 1, DEV_H - 1), 42, fill=(26, 27, 30, 255))
screen = IMG['idle_text'].resize((SCREEN_W, SCREEN_H), Image.LANCZOS).convert('RGBA')
screen.putalpha(rounded_mask(SCREEN_W, SCREEN_H, 20))
device_base.alpha_composite(screen, (BEZEL, BEZEL))
DEVICE_SHADOW = soft_shadow(DEV_W, DEV_H, 42, 34, 0.30, 90)


# ---------- scenes ----------

def scene_intro(frame, t, alpha):
    size = 176
    pop = ease_back(prog(t, 0.15, 0.85))
    bar = ease_out(prog(t, 0.55, 1.1))
    m_alpha = alpha * ease_out(prog(t, 0.15, 0.55))
    word = text_image('Aile', FONT_LATIN, 150, INK + (255,))
    group_w = size + 34 + word.width
    gx = (W - group_w) / 2
    cy = 468
    if m_alpha > 0.003:
        s = max(1, int(size * (0.7 + 0.3 * pop)))
        img = mark(size, bar).resize((s, s), Image.LANCZOS)
        draw_centered(frame, img, gx + size / 2, cy, m_alpha)
    w_in = ease_out(prog(t, 0.8, 1.4))
    if w_in > 0.003:
        draw_centered(frame, word, gx + size + 34 + word.width / 2 - (1 - w_in) * 40, cy + 4, alpha * w_in)
    tag_in = ease_out(prog(t, 1.35, 1.95))
    if tag_in > 0.003:
        tag = text_image('专为横握平板设计，左右拇指各管一边', FONT_REG, 44, SUB + (255,))
        draw_centered(frame, tag, W / 2, 640 + (1 - tag_in) * 22, alpha * tag_in)


def scene_hero(frame, t, alpha):
    local = t - 2.75
    draw_caption(frame, '分离键盘', '拇指停在屏幕两侧，就能按到各自的空格', local, alpha, top=100)
    rise = (1 - ease_out(prog(local, 0.0, 0.8))) * 60
    device = device_base.copy()
    layer = Image.new('RGBA', (SCREEN_W, SCREEN_H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    reach = ease_out(prog(local, 1.0, 1.8))
    spaces = [((440, 1645, 763, 1774), (0, SCREEN_H)), ((2104, 1645, 2429, 1774), (SCREEN_W, SCREEN_H))]
    for box, corner in spaces:
        cx = (box[0] + box[2]) / 2 * HS
        cy = (box[1] + box[3]) / 2 * HS
        dist = math.hypot(cx - corner[0], cy - corner[1]) + 40
        if reach > 0.003:
            rr = dist * reach
            d.ellipse((corner[0] - rr, corner[1] - rr, corner[0] + rr, corner[1] + rr),
                      fill=ACCENT + (int(34 * reach),))
        for k in range(3):
            phase = ((local - 1.2) / 1.6 + k / 3.0)
            if local < 1.2:
                continue
            phase -= math.floor(phase)
            rr = dist * phase
            a = (1 - phase) * 0.6 * reach
            d.ellipse((corner[0] - rr, corner[1] - rr, corner[0] + rr, corner[1] + rr),
                      outline=ACCENT + (int(255 * a),), width=4)
        glow = ease_out(prog(local, 1.6, 2.1))
        if glow > 0.003:
            pulse = 0.5 + 0.5 * math.sin((local - 1.6) * 4.2)
            pad = 6 + 4 * pulse
            d.rounded_rectangle((box[0] * HS - pad, box[1] * HS - pad, box[2] * HS + pad, box[3] * HS + pad),
                                10 + pad, outline=ACCENT + (int(255 * glow),), width=5)
    device.alpha_composite(layer, (BEZEL, BEZEL))
    y = int(round(DEV_Y + rise))
    frame.alpha_composite(with_alpha(DEVICE_SHADOW, alpha), (DEV_X - 90, y - 90 + 26))
    frame.alpha_composite(with_alpha(device, alpha), (DEV_X, y))


def scene_pinyin(frame, t, alpha):
    local = t - 7.75
    draw_caption(frame, '拼音输入', '候选词分布在左右两侧，按拇指位置就近排列', local, alpha)
    content = blend_states([(0, ST['compose1'], 0), (2.35, ST['compose2'], 0.35)], local)
    overlay = Image.new('RGBA', (CARD_W, CARD_H), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    pulse = 0.5 + 0.5 * math.sin(local * 4.0)
    highlight_box(d, (28, 1128, 780, 1216), ease_out(prog(local, 0.9, 1.3)), pulse)
    highlight_box(d, (2090, 1128, 2650, 1216), ease_out(prog(local, 1.3, 1.7)), pulse)
    rise = (1 - ease_out(prog(local, 0.0, 0.7))) * 40
    draw_card(frame, content, alpha, overlay, dy=rise)


def scene_flick(frame, t, alpha):
    local = t - 12.25
    draw_caption(frame, '上滑输入', '在字母键上向上一滑，就能输入数字和符号', local, alpha)
    content = blend_states([
        (0, ST['base_punct'], 0),
        (1.2, ST['flick_punct'], 0.12),
        (2.05, ST['idle'], 0.15),
        (3.15, ST['flick_letter'], 0.12),
    ], local)
    cam = camera_path(local, [
        (0.0, 1.0, 1400, 1400),
        (0.9, 1.22, 1100, 1470),
        (2.2, 1.22, 1100, 1470),
        (2.7, 1.22, 1700, 1320),
    ])
    overlay = Image.new('RGBA', (CARD_W, CARD_H), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    swipe_touch(d, cam, 364, 1708, local, appear=0.75, move_start=1.0, move_end=1.3, lift_start=1.9, lift_end=2.1)
    swipe_touch(d, cam, 2435, 1288, local, appear=2.75, move_start=2.95, move_end=3.25, lift_start=9, lift_end=9.1)
    rise = (1 - ease_out(prog(local, 0.0, 0.7))) * 40
    draw_card(frame, content, alpha, overlay, dy=rise, cam=cam)


def scene_clear(frame, t, alpha):
    local = t - 16.75
    switch = ease_in_out(prog(local, 3.05, 3.45))
    draw_caption(frame, '一键清空', '在删除键上向上一滑，就能立刻清空整段文字', local, alpha * (1 - switch))
    if switch > 0.003:
        draw_caption(frame, '撤销恢复', '清空之后，点一下撤销就能恢复原文', local - 3.05 + 0.05, alpha * switch)
    content = blend_states([
        (0, ST['idle'], 0),
        (1.35, ST['clear_hold'], 0.1),
        (2.45, ST['clear_after'], 0.12),
        (4.0, ST['undo'], 0.15),
    ], local)
    cam = camera_path(local, [
        (0.0, 1.0, 1400, 1400),
        (0.85, 1.25, 2300, 1310),
        (4.45, 1.25, 2300, 1310),
        (5.1, 1.0, 1400, 1400),
    ])
    overlay = Image.new('RGBA', (CARD_W, CARD_H), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    swipe_touch(d, cam, 2671, 1578, local, appear=0.95, move_start=1.2, move_end=1.5, lift_start=2.3, lift_end=2.5)
    pill = (2140, 1112, 2378, 1196)
    ring = ease_out(prog(local, 2.6, 3.0)) * (1 - ease_out(prog(local, 3.85, 4.05)))
    highlight_box(d, pill, ring, 0.5 + 0.5 * math.sin(local * 5.0), radius=40, width=5, cam=cam)
    # 点按落在按钮左侧的图标上，文字保持可读
    px, py = cam.xy(pill[0] + 46, (pill[1] + pill[3]) / 2)
    tap_a = ease_out(prog(local, 3.55, 3.7)) * (1 - ease_out(prog(local, 4.15, 4.35)))
    pressed = ease_out(prog(local, 3.8, 3.9)) * (1 - ease_out(prog(local, 3.95, 4.1)))
    touch(d, px, py, tap_a, pressed)
    rise = (1 - ease_out(prog(local, 0.0, 0.7))) * 40
    draw_card(frame, content, alpha, overlay, dy=rise, cam=cam)


def scene_panels(frame, t, alpha):
    local = t - 23.25
    draw_caption(frame, '功能面板', '表情、剪贴板和布局校准，都在拇指够得着的地方', local, alpha)
    content = blend_states([(0, ST['emoji'], 0), (2.05, ST['hub'], 0.35)], local)
    overlay = Image.new('RGBA', (CARD_W, CARD_H), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    tile_a = ease_out(prog(local, 2.6, 3.0))
    pulse = 0.5 + 0.5 * math.sin(local * 4.0)
    highlight_box(d, (22, 1238, 360, 1394), tile_a, pulse)
    highlight_box(d, (2440, 1238, 2778, 1394), tile_a, pulse)
    rise = (1 - ease_out(prog(local, 0.0, 0.7))) * 40
    draw_card(frame, content, alpha, overlay, dy=rise)


def scene_outro(frame, t, alpha):
    local = t - 27.05
    size = 132
    word = text_image('Aile', FONT_LATIN, 112, INK + (255,))
    group_w = size + 28 + word.width
    gx = (W - group_w) / 2
    cy = 430
    appear = ease_out(prog(local, 0.1, 0.7))
    a = alpha * appear
    if a > 0.003:
        draw_centered(frame, mark(size, 1.0), gx + size / 2, cy + (1 - appear) * 20, a)
        draw_centered(frame, word, gx + size + 28 + word.width / 2, cy + 4 + (1 - appear) * 20, a)
    tag_in = ease_out(prog(local, 0.45, 1.05))
    if tag_in > 0.003:
        tag = text_image('专为 HarmonyOS 平板打造，让横握打字更顺手', FONT_REG, 46, SUB + (255,))
        draw_centered(frame, tag, W / 2, 575 + (1 - tag_in) * 20, alpha * tag_in)
    feat_in = ease_out(prog(local, 0.8, 1.4))
    if feat_in > 0.003:
        feat = text_image('分离键盘  ·  中文拼音  ·  上滑输入  ·  一键清空', FONT_BOLD, 32, ACCENT + (255,))
        draw_centered(frame, feat, W / 2, 668 + (1 - feat_in) * 16, alpha * feat_in)


FADE = 0.45
SCENES = [
    (0.0, 3.2, scene_intro, False, True),
    (2.75, 8.2, scene_hero, True, True),
    (7.75, 12.7, scene_pinyin, True, True),
    (12.25, 17.2, scene_flick, True, True),
    (16.75, 23.7, scene_clear, True, True),
    (23.25, 27.5, scene_panels, True, True),
    (27.05, 30.0, scene_outro, True, False),
]


def render_frame(t):
    frame = BG.copy()
    for start, end, fn, fade_in, fade_out in SCENES:
        if t < start or t > end:
            continue
        a = 1.0
        if fade_in:
            a *= ease_in_out(prog(t, start, start + FADE))
        if fade_out:
            a *= 1 - ease_in_out(prog(t, end - FADE, end))
        if a > 0.003:
            fn(frame, t, a)
    return frame.convert('RGB')


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'preview':
        times = [float(v) for v in sys.argv[2:]]
        for tt in times:
            render_frame(tt).save(f'preview_{tt:05.2f}.png')
        print('preview done')
        return
    writer = MjpegAviWriter('aile_promo.avi', W, H, FPS, quality=94)
    total = int(DUR * FPS)
    for i in range(total):
        writer.add(render_frame(i / FPS))
        if i % 90 == 0:
            print(f'frame {i}/{total}', flush=True)
    writer.close()
    print('avi done')


if __name__ == '__main__':
    main()
