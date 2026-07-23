import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  LogRecord, LogLevel,
  LOG_TABLE_NAME, CREATE_LOG_TABLE_SQL, CREATE_LOG_INDEX_SQL
} from '../model/TrackTypes';
import { getDayKey } from '../common/TrackUtils';

const TAG_LOG: string = 'LogSvc';

export class LogService {
  private rdbStore: relationalStore.RdbStore | null = null;
  private insertBuffer: LogRecord[] = [];
  private static readonly FLUSH_SIZE: number = 10;
  private flushTimerId: number | null = null;

  init(store: relationalStore.RdbStore): void {
    this.rdbStore = store;
    if (this.rdbStore !== null) {
      this.rdbStore.executeSql(CREATE_LOG_TABLE_SQL).then(() => {
        return this.rdbStore!.executeSql(CREATE_LOG_INDEX_SQL);
      }).then(() => {
        hilog.info(0x0000, TAG_LOG, 'LogService initialized');
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, TAG_LOG, 'LogService init failed: %{public}s', err.message);
      });
    }
  }

  log(level: LogLevel, tag: string, message: string): void {
    const record: LogRecord = {
      timestamp: Date.now(),
      level: level,
      tag: tag,
      message: message
    };
    this.insertBuffer.push(record);
    if (this.insertBuffer.length >= LogService.FLUSH_SIZE) {
      this.flush();
    } else if (this.flushTimerId === null) {
      this.flushTimerId = setTimeout(() => {
        this.flushTimerId = null;
        this.flush();
      }, 5000);
    }
  }

  async queryByDate(dateKey: string): Promise<LogRecord[]> {
    const records: LogRecord[] = [];
    if (this.rdbStore === null) {
      return records;
    }
    try {
      const parts: string[] = dateKey.split('-');
      const year: number = parseInt(parts[0]);
      const month: number = parseInt(parts[1]);
      const day: number = parseInt(parts[2]);
      const startTs: number = new Date(year, month - 1, day, 0, 0, 0, 0).getTime();
      const endTs: number = new Date(year, month - 1, day, 23, 59, 59, 999).getTime();
      const predicates = new relationalStore.RdbPredicates(LOG_TABLE_NAME);
      predicates.between('timestamp', startTs, endTs).orderByAsc('timestamp');
      const resultSet = await this.rdbStore.query(predicates, ['id', 'timestamp', 'level', 'tag', 'message']);
      while (resultSet.goToNextRow()) {
        records.push({
          id: resultSet.getLong(resultSet.getColumnIndex('id')),
          timestamp: resultSet.getLong(resultSet.getColumnIndex('timestamp')),
          level: resultSet.getLong(resultSet.getColumnIndex('level')) as LogLevel,
          tag: resultSet.getString(resultSet.getColumnIndex('tag')),
          message: resultSet.getString(resultSet.getColumnIndex('message'))
        });
      }
      resultSet.close();
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'queryByDate failed: %{public}s', error.message);
    }
    return records;
  }

  async queryDates(): Promise<string[]> {
    const dates: string[] = [];
    if (this.rdbStore === null) {
      return dates;
    }
    try {
      const sql: string = `SELECT DISTINCT strftime('%Y-%m-%d', timestamp / 1000, 'unixepoch', 'localtime') as dk FROM ${LOG_TABLE_NAME} ORDER BY dk DESC`;
      const resultSet = await this.rdbStore.querySql(sql);
      while (resultSet.goToNextRow()) {
        const dk: string = resultSet.getString(resultSet.getColumnIndex('dk'));
        dates.push(dk);
      }
      resultSet.close();
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'queryDates failed: %{public}s', error.message);
    }
    return dates;
  }

  async clearAll(): Promise<void> {
    if (this.rdbStore === null) {
      return;
    }
    try {
      await this.rdbStore.executeSql(`DELETE FROM ${LOG_TABLE_NAME}`);
      hilog.info(0x0000, TAG_LOG, 'All logs cleared');
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'clearAll failed: %{public}s', error.message);
    }
  }

  private flush(): void {
    if (this.rdbStore === null || this.insertBuffer.length === 0) {
      return;
    }
    if (this.flushTimerId !== null) {
      clearTimeout(this.flushTimerId);
      this.flushTimerId = null;
    }
    const batch: LogRecord[] = this.insertBuffer.splice(0, this.insertBuffer.length);
    for (const record of batch) {
      try {
        this.rdbStore.insert(LOG_TABLE_NAME, {
          timestamp: record.timestamp,
          level: record.level,
          tag: record.tag,
          message: record.message
        });
      } catch (err) {
        const error = err as BusinessError;
        hilog.error(0x0000, TAG_LOG, 'flush insert failed: %{public}s', error.message);
      }
    }
  }
}
