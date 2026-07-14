/**
 * TrackDatabase.ets —— 本地轨迹数据库服务（ArkData RdbStore）
 *
 * 从 Index 原 initDatabase / queryTrackPointsByRange / loadTrackPoints /
 * saveTrackPoint 抽取，封装为独立服务类：
 *   - 建表 + 旧表不兼容时删表重建
 *   - 逐条即时落库，无缓冲，确保不丢点
 *   - 按时间范围查询 / 全量载入 / 清空
 * 组件只持有实例并在生命周期中调用，不再关心 SQL 细节。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  TrackPointRecord,
  DB_NAME,
  TABLE_NAME,
  CREATE_TABLE_SQL,
  DROP_TABLE_SQL,
  CREATE_INDEX_SQL,
  TAG
} from '../model/TrackTypes';

export class TrackDatabase {
  private rdbStore: relationalStore.RdbStore | null = null;

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
        console.info(TAG, 'Old schema detected, dropping table to rebuild (old data discarded)');
        await this.rdbStore.executeSql(DROP_TABLE_SQL);
        await this.rdbStore.executeSql(CREATE_TABLE_SQL);
      }
      await this.rdbStore.executeSql(CREATE_INDEX_SQL);
      console.info(TAG, 'TrackDatabase initialized');
    } catch (err) {
        const error = err as BusinessError;
        console.error(`initDatabase failed, code: ${error.code}, message: ${error.message}`);
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
        console.error(`queryTrackPointsByRange failed, code: ${error.code}, message: ${error.message}`);
    }
    return records;
  }

  async loadAll(): Promise<TrackPointRecord[]> {
    if (!this.rdbStore) {
      return [];
    }
    try {
      const records = await this.queryByRange(0, Number.MAX_SAFE_INTEGER);
      console.info(TAG, `Loaded ${records.length} track points from database`);
      return records;
    } catch (err) {
        const error = err as BusinessError;
        console.error(`loadTrackPoints failed, code: ${error.code}, message: ${error.message}`);
      return [];
    }
  }

  async insert(rec: TrackPointRecord): Promise<void> {
    if (!this.rdbStore) {
      return;
    }
    try {
      const values: relationalStore.ValuesBucket = {
        latitude: rec.latitude,
        longitude: rec.longitude,
        timestamp: rec.timestamp,
        accuracy: rec.accuracy,
        speed: rec.speed
      };
      await this.rdbStore.insert(TABLE_NAME, values);
    } catch (err) {
        const error = err as BusinessError;
        console.error(`insert track point failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  async clear(): Promise<void> {
    if (this.rdbStore) {
      try {
        const predicates = new relationalStore.RdbPredicates(TABLE_NAME);
        await this.rdbStore.delete(predicates);
      } catch (err) {
        const error = err as BusinessError;
        console.error(`clearTrack DB failed, code: ${error.code}, message: ${error.message}`);
      }
    }
  }
}
