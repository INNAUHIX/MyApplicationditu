/**
 * TrackDatabase.ets —— 本地轨迹数据库服务（ArkData RdbStore）
 *
 * 从 Index 原 initDatabase / queryTrackPointsByRange / loadTrackPoints /
 * saveTrackPoint / flushBatch 抽取，封装为独立服务类：
 *   - 建表 + 旧表不兼容时删表重建
 *   - 批量缓冲落库（达到批大小即写，定时落库定时器降低写入频率）
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
  BATCH_SIZE,
  FLUSH_INTERVAL,
  TAG
} from '../model/TrackTypes';

export class TrackDatabase {
  private rdbStore: relationalStore.RdbStore | null = null;
  // 待写入数据库的轨迹点缓冲（批量落库，降低 DB 写入频率）
  private pendingPoints: TrackPointRecord[] = [];
  private flushTimer: number | null = null;

  get store(): relationalStore.RdbStore | null {
    return this.rdbStore;
  }

  get pendingCount(): number {
    return this.pendingPoints.length;
  }

  // 初始化本地关系型数据库：获取 RdbStore、建表，并处理旧表不兼容升级
  async init(context: common.UIAbilityContext): Promise<void> {
    try {
      let config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      this.rdbStore = await relationalStore.getRdbStore(context, config);
      await this.rdbStore.executeSql(CREATE_TABLE_SQL);
      // 不兼容旧轨迹：尝试访问新字段 timestamp，失败说明是旧表（仅2列），直接删表重建丢弃旧数据
      try {
        let probe = new relationalStore.RdbPredicates(TABLE_NAME);
        await this.rdbStore.query(probe, ['timestamp']);
      } catch (e) {
        console.info(TAG, 'Old schema detected, dropping table to rebuild (old data discarded)');
        await this.rdbStore.executeSql(DROP_TABLE_SQL);
        await this.rdbStore.executeSql(CREATE_TABLE_SQL);
      }
      await this.rdbStore.executeSql(CREATE_INDEX_SQL);
      console.info(TAG, 'TrackDatabase initialized');
    } catch (err) {
      let error = err as BusinessError;
      console.error(`initDatabase failed, code: ${error.code}, message: ${error.message}`);
    }
  }

  // 按时间范围从数据库查询轨迹点（命中 idx_ts 索引），返回含 timestamp 的完整记录（accuracy/speed 旧数据补 0）
  async queryByRange(startTs: number, endTs: number): Promise<TrackPointRecord[]> {
    let records: TrackPointRecord[] = [];
    if (!this.rdbStore) {
      return records;
    }
    try {
      let predicates = new relationalStore.RdbPredicates(TABLE_NAME);
      predicates.between('timestamp', startTs, endTs).orderByAsc('id');
      let resultSet = await this.rdbStore.query(predicates,
        ['latitude', 'longitude', 'timestamp']);
      while (resultSet.goToNextRow()) {
        records.push({
          latitude: resultSet.getDouble(resultSet.getColumnIndex('latitude')),
          longitude: resultSet.getDouble(resultSet.getColumnIndex('longitude')),
          timestamp: resultSet.getLong(resultSet.getColumnIndex('timestamp')),
          accuracy: 0,
          speed: 0
        });
      }
      resultSet.close();
    } catch (err) {
      let error = err as BusinessError;
      console.error(`queryTrackPointsByRange failed, code: ${error.code}, message: ${error.message}`);
    }
    return records;
  }

  // 从数据库全量载入轨迹点（0~now），作为 allTrackPoints 唯一全量缓存
  async loadAll(): Promise<TrackPointRecord[]> {
    if (!this.rdbStore) {
      return [];
    }
    try {
      let records = await this.queryByRange(0, Number.MAX_SAFE_INTEGER);
      console.info(TAG, `Loaded ${records.length} track points from database`);
      return records;
    } catch (err) {
      let error = err as BusinessError;
      console.error(`loadTrackPoints failed, code: ${error.code}, message: ${error.message}`);
      return [];
    }
  }

  // 将轨迹点推入缓冲（含精度/速度/时间戳），达到批大小即触发批量落库
  enqueue(rec: TrackPointRecord): void {
    this.pendingPoints.push(rec);
    if (this.pendingPoints.length >= BATCH_SIZE) {
      this.flushBatch();
    }
  }

  // 启动批量落库定时器：每 FLUSH_INTERVAL 毫秒把缓冲中的轨迹点一次性写入数据库
  startFlushTimer(): void {
    if (this.flushTimer !== null) {
      return;
    }
    this.flushTimer = setInterval(() => {
      this.flushBatch();
    }, FLUSH_INTERVAL);
  }

  // 页面销毁：清除落库定时器并补齐未落库的点，避免后台持续定位与内存泄漏
  stopFlushTimer(): void {
    if (this.flushTimer !== null) {
      clearInterval(this.flushTimer);
      this.flushTimer = null;
    }
    this.flushBatch();
  }

  // 批量落库：用 batchInsert 一次性写入缓冲中的全部轨迹点，降低 DB 写入频率
  private flushBatch(): void {
    if (!this.rdbStore || this.pendingPoints.length === 0) {
      return;
    }
    let values: relationalStore.ValuesBucket[] = [];
    for (let p of this.pendingPoints) {
      values.push({
        latitude: p.latitude,
        longitude: p.longitude,
        timestamp: p.timestamp,
        accuracy: p.accuracy,
        speed: p.speed
      });
    }
    this.rdbStore.batchInsert(TABLE_NAME, values)
      .then((count: number) => {
        console.info(TAG, `flushBatch inserted ${count} points`);
      })
      .catch((err: BusinessError) => {
        console.error(`flushBatch failed, code: ${err.code}, message: ${err.message}`);
      });
    this.pendingPoints = [];
  }

  // 清空数据库中的全部轨迹记录（内存数组由调用方负责重置）
  async clear(): Promise<void> {
    if (this.rdbStore) {
      try {
        let predicates = new relationalStore.RdbPredicates(TABLE_NAME);
        await this.rdbStore.delete(predicates);
      } catch (err) {
        let error = err as BusinessError;
        console.error(`clearTrack DB failed, code: ${error.code}, message: ${error.message}`);
      }
    }
    this.pendingPoints = [];
  }
}
