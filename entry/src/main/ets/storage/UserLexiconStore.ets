import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../ime/Log';

const FILE_NAME: string = 'user_lexicon.json';

/**
 * 用户数据文件读写：临时文件写入、同步落盘后重命名替换，损坏文件改名备份。
 * 默认读写用户词库，按键偏移等其他学习数据传入各自的文件名。
 */
export class UserLexiconStore {
  private readonly path: string;
  private readonly tempPath: string;
  private readonly name: string;

  constructor(filesDir: string, fileName: string = FILE_NAME) {
    this.name = fileName;
    this.path = `${filesDir}/${fileName}`;
    this.tempPath = `${filesDir}/${fileName}.tmp`;
  }

  read(): string | undefined {
    try {
      if (!fs.accessSync(this.path)) {
        return undefined;
      }
      return fs.readTextSync(this.path);
    } catch (error) {
      Log.error(`${this.name} read failed, code=${(error as BusinessError).code}`);
      return undefined;
    }
  }

  write(text: string): boolean {
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(this.tempPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
      fs.fsyncSync(file.fd);
      fs.closeSync(file);
      file = undefined;
      fs.renameSync(this.tempPath, this.path);
      return true;
    } catch (error) {
      Log.error(`${this.name} write failed, code=${(error as BusinessError).code}`);
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (closeError) {
          Log.error(`${this.name} close failed, code=${(closeError as BusinessError).code}`);
        }
      }
      return false;
    }
  }

  backupCorrupted(): void {
    try {
      if (fs.accessSync(this.path)) {
        fs.renameSync(this.path, `${this.path}.corrupt-${Date.now()}`);
      }
    } catch (error) {
      Log.error(`${this.name} backup failed, code=${(error as BusinessError).code}`);
    }
  }
}
