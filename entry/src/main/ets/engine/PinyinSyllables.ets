// 标准音节表取自基础词库实际使用的拼写，ü 统一写作 v，lue 与 nue 保留词库拼写
// m、n、ng、hm、hng 只在整串等于该音节时参与切分，避免拆出大量噪声路径
export const STANDARD_SYLLABLES: string[] = [
  'a', 'ai', 'an', 'ang', 'ao', 'ba', 'bai', 'ban', 'bang', 'bao', 'bei', 'ben', 'beng', 'bi',
  'bian', 'biao', 'bie', 'bin', 'bing', 'bo', 'bu', 'ca', 'cai', 'can', 'cang', 'cao', 'ce', 'cen',
  'ceng', 'cha', 'chai', 'chan', 'chang', 'chao', 'che', 'chen', 'cheng', 'chi', 'chong', 'chou', 'chu', 'chua',
  'chuai', 'chuan', 'chuang', 'chui', 'chun', 'chuo', 'ci', 'cong', 'cou', 'cu', 'cuan', 'cui', 'cun', 'cuo',
  'da', 'dai', 'dan', 'dang', 'dao', 'de', 'dei', 'den', 'deng', 'di', 'dia', 'dian', 'diao', 'die',
  'ding', 'diu', 'dong', 'dou', 'du', 'duan', 'dui', 'dun', 'duo', 'e', 'ei', 'en', 'eng', 'er',
  'fa', 'fan', 'fang', 'fei', 'fen', 'feng', 'fiao', 'fo', 'fou', 'fu', 'ga', 'gai', 'gan', 'gang',
  'gao', 'ge', 'gei', 'gen', 'geng', 'gong', 'gou', 'gu', 'gua', 'guai', 'guan', 'guang', 'gui', 'gun',
  'guo', 'ha', 'hai', 'han', 'hang', 'hao', 'he', 'hei', 'hen', 'heng', 'hong', 'hou', 'hu', 'hua',
  'huai', 'huan', 'huang', 'hui', 'hun', 'huo', 'ji', 'jia', 'jian', 'jiang', 'jiao', 'jie', 'jin', 'jing',
  'jiong', 'jiu', 'ju', 'juan', 'jue', 'jun', 'ka', 'kai', 'kan', 'kang', 'kao', 'ke', 'kei', 'ken',
  'keng', 'kong', 'kou', 'ku', 'kua', 'kuai', 'kuan', 'kuang', 'kui', 'kun', 'kuo', 'la', 'lai', 'lan',
  'lang', 'lao', 'le', 'lei', 'leng', 'li', 'lia', 'lian', 'liang', 'liao', 'lie', 'lin', 'ling', 'liu',
  'lo', 'long', 'lou', 'lu', 'luan', 'lue', 'lun', 'luo', 'lv', 'ma', 'mai', 'man', 'mang', 'mao',
  'me', 'mei', 'men', 'meng', 'mi', 'mian', 'miao', 'mie', 'min', 'ming', 'miu', 'mo', 'mou', 'mu',
  'na', 'nai', 'nan', 'nang', 'nao', 'ne', 'nei', 'nen', 'neng', 'ni', 'nian', 'niang', 'niao', 'nie',
  'nin', 'ning', 'niu', 'nong', 'nou', 'nu', 'nuan', 'nue', 'nuo', 'nv', 'o', 'ou', 'pa', 'pai',
  'pan', 'pang', 'pao', 'pei', 'pen', 'peng', 'pi', 'pian', 'piao', 'pie', 'pin', 'ping', 'po', 'pou',
  'pu', 'qi', 'qia', 'qian', 'qiang', 'qiao', 'qie', 'qin', 'qing', 'qiong', 'qiu', 'qu', 'quan', 'que',
  'qun', 'ran', 'rang', 'rao', 're', 'ren', 'reng', 'ri', 'rong', 'rou', 'ru', 'ruan', 'rui', 'run',
  'ruo', 'sa', 'sai', 'san', 'sang', 'sao', 'se', 'sen', 'seng', 'sha', 'shai', 'shan', 'shang', 'shao',
  'she', 'shei', 'shen', 'sheng', 'shi', 'shou', 'shu', 'shua', 'shuai', 'shuan', 'shuang', 'shui', 'shun', 'shuo',
  'si', 'song', 'sou', 'su', 'suan', 'sui', 'sun', 'suo', 'ta', 'tai', 'tan', 'tang', 'tao', 'te',
  'tei', 'teng', 'ti', 'tian', 'tiao', 'tie', 'ting', 'tong', 'tou', 'tu', 'tuan', 'tui', 'tun', 'tuo',
  'wa', 'wai', 'wan', 'wang', 'wei', 'wen', 'weng', 'wo', 'wu', 'xi', 'xia', 'xian', 'xiang', 'xiao',
  'xie', 'xin', 'xing', 'xiong', 'xiu', 'xu', 'xuan', 'xue', 'xun', 'ya', 'yan', 'yang', 'yao', 'ye',
  'yi', 'yin', 'ying', 'yo', 'yong', 'you', 'yu', 'yuan', 'yue', 'yun', 'za', 'zai', 'zan', 'zang',
  'zao', 'ze', 'zei', 'zen', 'zeng', 'zha', 'zhai', 'zhan', 'zhang', 'zhao', 'zhe', 'zhei', 'zhen', 'zheng',
  'zhi', 'zhong', 'zhou', 'zhu', 'zhua', 'zhuai', 'zhuan', 'zhuang', 'zhui', 'zhun', 'zhuo', 'zi', 'zong', 'zou',
  'zu', 'zuan', 'zui', 'zun', 'zuo'
];

export const STANDALONE_SYLLABLES: string[] = ['m', 'n', 'ng', 'hm', 'hng'];

// 简拼声母，zh、ch、sh 作为整体声母
export const INITIALS: string[] = ['b', 'p', 'm', 'f', 'd', 't', 'n', 'l', 'g', 'k', 'h', 'j', 'q', 'x', 'zh', 'ch',
  'sh', 'r', 'z', 'c', 's', 'y', 'w'];

export const MAX_SYLLABLE_LENGTH: number = 6;

const syllableSet: Set<string> = new Set<string>(STANDARD_SYLLABLES);
const standaloneSet: Set<string> = new Set<string>(STANDALONE_SYLLABLES);
const initialSet: Set<string> = new Set<string>(INITIALS);
const prefixSet: Set<string> = buildPrefixSet();

function buildPrefixSet(): Set<string> {
  const prefixes = new Set<string>();
  for (const syllable of STANDARD_SYLLABLES) {
    for (let i = 1; i < syllable.length; i++) {
      prefixes.add(syllable.substring(0, i));
    }
  }
  return prefixes;
}

/**
 * 输入习惯写法到词库拼写的映射，lve、nve 对应词库中的 lue、nue。
 */
export function canonicalSyllable(text: string): string {
  if (text === 'lve') {
    return 'lue';
  }
  if (text === 'nve') {
    return 'nue';
  }
  return text;
}

export function isSyllable(text: string): boolean {
  return syllableSet.has(canonicalSyllable(text));
}

export function isStandaloneSyllable(text: string): boolean {
  return standaloneSet.has(text);
}

// 是否为某个标准音节的真前缀
export function isSyllablePrefix(text: string): boolean {
  return prefixSet.has(text) || text === 'lv' || text === 'nv';
}

export function isInitial(text: string): boolean {
  return initialSet.has(text);
}

/**
 * 简拼可以用的首字母：全部声母，以及能直接起头的 a、e、o，例如 aq 对应安全，eq 对应而且。
 */
export function isAbbreviationLetter(text: string): boolean {
  return initialSet.has(text) || text === 'a' || text === 'e' || text === 'o';
}
