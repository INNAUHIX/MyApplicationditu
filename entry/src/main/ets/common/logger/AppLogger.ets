import hilog from '@ohos.hilog';
import { LogLevel, LogEntry } from './LogEntry';

const APP_DOMAIN: number = 0x0001;
const APP_TAG: string = 'Footprint';
const MAX_BUFFER_SIZE: number = 500;

export class AppLogger {
  private static buffer: LogEntry[] = [];
  private static listeners: (() => void)[] = [];

  static debug(tag: string, message: string): void {
    AppLogger.log(LogLevel.DEBUG, tag, message);
  }

  static info(tag: string, message: string): void {
    AppLogger.log(LogLevel.INFO, tag, message);
  }

  static warn(tag: string, message: string): void {
    AppLogger.log(LogLevel.WARN, tag, message);
  }

  static error(tag: string, message: string): void {
    AppLogger.log(LogLevel.ERROR, tag, message);
  }

  static keyInfo(tag: string, message: string): void {
    AppLogger.log(LogLevel.INFO, tag, message, true);
  }

  static getEntries(): LogEntry[] {
    return AppLogger.buffer;
  }

  static clear(): void {
    AppLogger.buffer = [];
    AppLogger.notifyListeners();
  }

  static addListener(fn: () => void): void {
    AppLogger.listeners.push(fn);
  }

  static removeListener(fn: () => void): void {
    AppLogger.listeners = AppLogger.listeners.filter(f => f !== fn);
  }

  private static log(level: LogLevel, tag: string, message: string, key: boolean = false): void {
    const entry: LogEntry = {
      timestamp: Date.now(),
      level: level,
      tag: tag,
      message: message,
      key: key
    };
    AppLogger.buffer.push(entry);
    if (AppLogger.buffer.length > MAX_BUFFER_SIZE) {
      AppLogger.buffer.shift();
    }

    const fullMsg: string = `[${tag}] ${message}`;
    switch (level) {
      case LogLevel.DEBUG:
        hilog.debug(APP_DOMAIN, APP_TAG, fullMsg);
        break;
      case LogLevel.INFO:
        hilog.info(APP_DOMAIN, APP_TAG, fullMsg);
        break;
      case LogLevel.WARN:
        hilog.warn(APP_DOMAIN, APP_TAG, fullMsg);
        break;
      case LogLevel.ERROR:
        hilog.error(APP_DOMAIN, APP_TAG, fullMsg);
        break;
    }

    AppLogger.notifyListeners();
  }

  private static notifyListeners(): void {
    for (const fn of AppLogger.listeners) {
      fn();
    }
  }
}