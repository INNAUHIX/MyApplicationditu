/**
 * TrackDatabase.ets —— 本地轨迹数据库服务（ArkData RdbStore）
 *
 * 从 Index 原 initDatabase / queryTrackPointsByRange / loadTrackPoints /
 * saveTrackPoint 抽取，封装为独立服务类：
 *   - 建表 + 旧表不兼容时删表重建
 *   - 缓冲批量落库（每10条或5秒自动刷新），确保不丢点
 *   - 按时间范围查询 / 全量载入
 * 组件只持有实例并在生命周期中调用，不再关心 SQL 细节。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  TrackPointRecord,
  DB_NAME,
  TABLE_NAME,
  CREATE_TABLE_SQL,
  DROP_TABLE_SQL,
  CREATE_INDEX_SQL
} from '../model/TrackTypes';

const TAG_LOG: string = 'TrackDB';

export class TrackDatabase {
  private rdbStore: relationalStore.RdbStore | null = null;
  private insertBuffer: TrackPointRecord[] = [];
  private static readonly FLUSH_INTERVAL: number = 10;
  private flushTimerId: number | null = null;

  get store(): relationalStore.RdbStore | null {
    return this.rdbStore;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    try {
      const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      this.rdbStore = await relationalStore.getRdbStore(context, config);
      await this.rdbStore.executeSql(CREATE_TABLE_SQL);
      try {
        const probe = new relationalStore.RdbPredicates(TABLE_NAME);
        await this.rdbStore.query(probe, ['timestamp']);
      } catch (e) {
        hilog.info(0x0000, TAG_LOG, 'Old schema detected, dropping table to rebuild (old data discarded)');
        await this.rdbStore.executeSql(DROP_TABLE_SQL);
        await this.rdbStore.executeSql(CREATE_TABLE_SQL);
      }
      await this.rdbStore.executeSql(CREATE_INDEX_SQL);
      hilog.info(0x0000, TAG_LOG, 'TrackDatabase initialized');
    } catch (err) {
        const error = err as BusinessError;
        hilog.error(0x0000, TAG_LOG, 'initDatabase failed, code: %{public}d, message: %{public}s',
          error.code, error.message);
    }
  }

  async queryByRange(startTs: number, endTs: number): Promise<TrackPointRecord[]> {
    const records: TrackPointRecord[] = [];
    if (!this.rdbStore) {
      return records;
    }
    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_NAME);
      predicates.between('timestamp', startTs, endTs).orderByAsc('id');
      const resultSet = await this.rdbStore.query(predicates,
        ['latitude', 'longitude', 'timestamp', 'accuracy', 'speed']);
      while (resultSet.goToNextRow()) {
        records.push({
          latitude: resultSet.getDouble(resultSet.getColumnIndex('latitude')),
          longitude: resultSet.getDouble(resultSet.getColumnIndex('longitude')),
          timestamp: resultSet.getLong(resultSet.getColumnIndex('timestamp')),
          accuracy: resultSet.getDouble(resultSet.getColumnIndex('accuracy')),
          speed: resultSet.getDouble(resultSet.getColumnIndex('speed'))
        });
      }
      resultSet.close();
    } catch (err) {
        const error = err as BusinessError;
        hilog.error(0x0000, TAG_LOG, 'queryTrackPointsByRange failed, code: %{public}d, message: %{public}s',
          error.code, error.message);
    }
    return records;
  }

  async loadAll(): Promise<TrackPointRecord[]> {
    if (!this.rdbStore) {
      return [];
    }
    try {
      const records = await this.queryByRange(0, Number.MAX_SAFE_INTEGER);
      hilog.info(0x0000, TAG_LOG, 'Loaded %{public}d track points from database', records.length);
      return records;
    } catch (err) {
        const error = err as BusinessError;
        hilog.error(0x0000, TAG_LOG, 'loadTrackPoints failed, code: %{public}d, message: %{public}s',
          error.code, error.message);
      return [];
    }
  }

  insert(rec: TrackPointRecord): void {
    this.insertBuffer.push(rec);
    if (this.insertBuffer.length >= TrackDatabase.FLUSH_INTERVAL) {
      this.flush();
    } else if (this.flushTimerId === null) {
      this.flushTimerId = setTimeout(() => {
        this.flush();
      }, 5000);
    }
  }

  async flush(): Promise<void> {
    if (this.insertBuffer.length === 0) {
      return;
    }
    if (!this.rdbStore) {
      return;
    }
    const batch: TrackPointRecord[] = [...this.insertBuffer];
    this.insertBuffer = [];
    if (this.flushTimerId !== null) {
      clearTimeout(this.flushTimerId);
      this.flushTimerId = null;
    }
    try {
      this.rdbStore.beginTransaction();
    } catch (e) {
      hilog.warn(0x0000, TAG_LOG, 'beginTransaction failed: %{public}s', JSON.stringify(e));
      return;
    }
    try {
      for (const rec of batch) {
        const values: relationalStore.ValuesBucket = {
          latitude: rec.latitude,
          longitude: rec.longitude,
          timestamp: rec.timestamp,
          accuracy: rec.accuracy,
          speed: rec.speed
        };
        await this.rdbStore!.insert(TABLE_NAME, values);
      }
      this.rdbStore.commit();
      hilog.info(0x0000, TAG_LOG, 'Flushed %{public}d track points to database', batch.length);
    } catch (err) {
      try {
        this.rdbStore.rollBack();
      } catch (rollbackErr) {
        hilog.warn(0x0000, TAG_LOG, 'rollBack failed: %{public}s', JSON.stringify(rollbackErr));
      }
      const error = err as BusinessError;
      hilog.error(0x0000, TAG_LOG, 'Batch insert failed, code: %{public}d, message: %{public}s',
        error.code, error.message);
    }
  }

  async flushIfNeeded(): Promise<void> {
    await this.flush();
  }

}
