// 表情以 Unicode 字符输入编辑框。面板中的图案使用 Noto Color Emoji 的 72px PNG（Apache 2.0），
// 图片位于 rawfile/emoji，许可文件随图片放置，文件名为去掉 U+FE0F 后的码位序列。

export interface EmojiCategory {
  name: string;
  emojis: string[];
}

function list(text: string): string[] {
  return text.split(' ').filter((item: string) => item.length > 0);
}

export const RECENT_EMOJI_LIMIT: number = 32;

const VARIATION_SELECTOR_16: number = 0xfe0f;

/**
 * 表情对应的 Noto 图片路径，例如 😀 为 emoji/emoji_u1f600.png，0️⃣ 为 emoji/emoji_u0030_20e3.png。
 */
export function emojiAssetPath(emoji: string): string {
  const parts: string[] = [];
  for (let i = 0; i < emoji.length; i++) {
    const codePoint = emoji.codePointAt(i) ?? 0;
    if (codePoint > 0xffff) {
      i++;
    }
    if (codePoint !== VARIATION_SELECTOR_16) {
      parts.push(codePoint.toString(16).padStart(4, '0'));
    }
  }
  return `emoji/emoji_u${parts.join('_')}.png`;
}

// 第 0 项为“最近”，内容来自使用记录
export const EMOJI_CATEGORIES: EmojiCategory[] = [
  { name: '最近', emojis: [] },
  {
    name: '笑脸',
    emojis: list('😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😙 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🤫 🤔 ' +
      '🤐 🤨 😐 😑 😶 😏 😒 🙄 😬 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🥵 🥶 🥴 😵 🤯 🤠 🥳 😎 🤓 🧐 😕 ' +
      '😟 🙁 😮 😯 😲 😳 🥺 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 😡 😠 🤬 😈 👿 💀 💩 ' +
      '🤡 👻 👽 🤖 😺 😸 😹 😻 😼 😽 🙀 😿 😾')
  },
  {
    name: '手势',
    emojis: list('👋 🤚 🖐️ ✋ 🖖 👌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 👐 🤲 🤝 🙏 ✍️ ' +
      '💪 👀 👂 👃 👅 👄 🧠 👶 🧒 👦 👧 🧑 👨 👩 🧓 👴 👵 🙍 🙎 🙅 🙆 💁 🙋 🙇 🤦 🤷 👮 👷 💂 🕵️ ' +
      '👸 🤴 👰 🤵 🤰 🎅 🧙 🧚 🧛 🧜 🧝 💃 🕺 👯 🧘 🛀 👫 👭 👬 💏 💑 👪')
  },
  {
    name: '自然',
    emojis: list('🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐔 🐧 🐦 🐤 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 ' +
      '🐝 🐛 🦋 🐌 🐞 🐜 🐢 🐍 🦎 🐙 🦑 🦐 🦀 🐡 🐠 🐟 🐬 🐳 🐋 🦈 🐊 🐅 🐆 🦓 🦍 🐘 🦏 🐪 🦒 🦘 ' +
      '🐄 🐎 🐖 🐑 🐐 🦌 🐕 🐈 🐓 🦚 🦜 🦢 🐇 🦔 🐾 🐉 🌵 🎄 🌲 🌳 🌴 🌱 🌿 🍀 🍁 🍂 🍃 🌷 🌹 🥀 ' +
      '🌺 🌸 🌼 🌻 🌞 🌝 🌛 🌙 🌎 ⭐ 🌟 ✨ ⚡ 🔥 🌈 ☀️ ⛅ ☁️ 🌧️ ⛄ ❄️ 💧 🌊')
  },
  {
    name: '食物',
    emojis: list('🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🥦 🥬 🥒 🌶️ 🌽 🥕 🥔 🍠 🥐 🍞 🥖 ' +
      '🥨 🧀 🥚 🍳 🥞 🥓 🥩 🍗 🍖 🌭 🍔 🍟 🍕 🥪 🌮 🌯 🥗 🍝 🍜 🍲 🍛 🍣 🍱 🥟 🍤 🍙 🍚 🍘 🍥 🥮 ' +
      '🍢 🍡 🍧 🍨 🍦 🥧 🧁 🍰 🎂 🍮 🍭 🍬 🍫 🍿 🍩 🍪 🥛 ☕ 🍵 🥤 🍶 🍺 🍻 🥂 🍷 🥃 🍸 🍹 🥢 🍴')
  },
  {
    name: '活动',
    emojis: list('⚽ 🏀 🏈 ⚾ 🎾 🏐 🏉 🎱 🏓 🏸 🏒 🏏 ⛳ 🏹 🎣 🥊 🥋 🎽 🛹 ⛸️ 🎿 🏂 🏋️ 🤸 🤺 🤾 🏇 🧗 🚴 🏊 ' +
      '🏄 🏆 🥇 🥈 🥉 🏅 🎫 🎪 🎭 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🎷 🎺 🎸 🎻 🎲 🎯 🎳 🎮 🧩 🎉 🎊 🎈 🎁 🎀 ' +
      '🧧 🎃 🎆 🎇 🧨 🎐 🎑 🏮')
  },
  {
    name: '旅行',
    emojis: list('🚗 🚕 🚙 🚌 🚎 🏎️ 🚓 🚑 🚒 🚐 🚚 🚛 🚜 🛵 🏍️ 🚲 🛴 🚨 🚍 🚘 🚖 🚡 🚠 🚃 🚋 🚄 🚅 🚂 🚆 🚇 ' +
      '✈️ 🛫 🛬 🚀 🛸 🚁 ⛵ 🚤 🚢 ⚓ ⛽ 🚧 🚦 🗺️ 🗿 🗽 🗼 🏰 🏯 🎡 🎢 🎠 ⛲ 🏖️ 🏝️ 🏜️ 🌋 ⛰️ 🗻 🏕️ ' +
      '⛺ 🏠 🏡 🏭 🏢 🏬 🏥 🏦 🏨 🏪 🏫 💒 🏛️ ⛪ 🌁 🌃 🏙️ 🌄 🌅 🌆 🌇 🌉')
  },
  {
    name: '物品',
    emojis: list('⌚ 📱 💻 ⌨️ 🖥️ 🖨️ 🖱️ 💾 💿 📷 📸 📹 🎥 📞 ☎️ 📺 📻 🎙️ ⏰ ⏳ 📡 🔋 🔌 💡 🔦 🧯 💸 💵 💴 💰 ' +
      '💳 💎 ⚖️ 🔧 🔨 🛠️ 🔩 ⚙️ 🧱 💣 🔪 🛡️ 🔮 🔭 🔬 💊 💉 🧬 🧪 🌡️ 🧹 🧺 🧻 🚿 🛁 🧼 🔑 🚪 🛋️ 🛏️ ' +
      '🧸 🖼️ 🛍️ 🛒 📦 📫 📮 📜 📄 📊 📈 📉 📅 📋 📁 📂 📰 📓 📕 📗 📘 📙 📚 📖 🔖 🔗 📎 📐 📏 📌 ' +
      '📍 ✂️ 🖊️ 🖌️ 🖍️ 📝 ✏️ 🔍 🔒 🔓')
  },
  {
    name: '符号',
    emojis: list('❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💟 💯 💢 💥 💫 💦 💨 💤 💬 💭 ♈ ♉ ' +
      '♊ ♋ ♌ ♍ ♎ ♏ ♐ ♑ ♒ ♓ 🆗 🆒 🆕 🆓 🆙 🆘 ❌ ⭕ 🛑 ⛔ 🚫 ❗ ❓ ‼️ ⁉️ ⚠️ ♻️ ✅ ❎ 🌀 ' +
      '🎵 🎶 ➕ ➖ ➗ ✖️ 💲 ©️ ®️ ™️ ✔️ ☑️ 🔴 🟠 🟡 🟢 🔵 🟣 ⚫ ⚪ 🔺 🔻 🔶 🔷 ⬛ ⬜ 🔔 🔕 📣 ♠️ ' +
      '♣️ ♥️ ♦️ 🃏 🀄')
  }
];
