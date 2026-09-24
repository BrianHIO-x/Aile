import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x3a01;
const TAG: string = 'ThumbIME';

// 日志只记录状态、错误码、尺寸与耗时，禁止写入输入文本、拼音和候选正文
export class Log {
  static info(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', message);
  }

  static warn(message: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', message);
  }

  static error(message: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', message);
  }
}
