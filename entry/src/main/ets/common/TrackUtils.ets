/**
 * TrackUtils.ets —— 轨迹相关的纯函数工具集
 *
 * 全部为无副作用的纯函数（输入出结果），不依赖任何组件状态，
 * 便于单测与复用。从 Index 原 private 方法 calculateDistance / formatDistance /
 * formatStatDate / getDayStartTs / getDayEndTs / getDayKey / computeStats 抽取。
 */

import { mapCommon } from '@kit.MapKit';
import { TrackPointRecord, StatDayItem, StatResult } from '../model/TrackTypes';

// 日期边界辅助：当天 0 点 / 当天 23:59:59.999 / 日期 key(YYYY-M-D)
export function getDayStartTs(ts: number): number {
  const d: Date = new Date(ts);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

export function getDayEndTs(ts: number): number {
  const d: Date = new Date(ts);
  d.setHours(23, 59, 59, 999);
  return d.getTime();
}

export function getDayKey(ts: number): string {
  const d: Date = new Date(ts);
  return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
}

// 使用 Haversine 公式估算两点间地表距离(米)
export function calculateDistance(from: mapCommon.LatLng, to: mapCommon.LatLng): number {
  const R: number = 6371000;
  const dLat: number = (to.latitude - from.latitude) * Math.PI / 180;
  const dLon: number = (to.longitude - from.longitude) * Math.PI / 180;
  const a: number = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(from.latitude * Math.PI / 180) * Math.cos(to.latitude * Math.PI / 180) *
    Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c: number = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

// 将米格式化为易读里程：不足 1 公里显示「米」，否则显示「公里（保留两位）」
export function formatDistance(meters: number): string {
  if (meters < 1000) {
    return `${Math.round(meters)} 米`;
  }
  return `${(meters / 1000).toFixed(2)} 公里`;
}

// 将时间戳格式化为「YYYY-MM-DD」用于统计面板展示（补零对齐标准格式）
export function formatStatDate(ts: number): string {
  if (!ts) {
    return '—';
  }
  const d: Date = new Date(ts);
  const m: number = d.getMonth() + 1;
  const day: number = d.getDate();
  return `${d.getFullYear()}-${m < 10 ? '0' + m : m}-${day < 10 ? '0' + day : day}`;
}

// 基于全量 points 派生统计指标：累计里程 / 足迹点 / 活跃天数 / 日均 / 最长单日 / 首末记录 / 最近7天分布
// 纯函数版本：输入完整记录数组，输出 StatResult，调用方自行写入组件 @State。
export function computeStats(pts: TrackPointRecord[]): StatResult {
  if (!pts || pts.length === 0) {
    return {
      totalDistance: 0,
      trackCount: 0,
      activeDays: 0,
      avgDailyDist: 0,
      maxDailyDist: 0,
      firstTs: 0,
      lastTs: 0,
      recent7: []
    };
  }

  let totalDist: number = 0;
  const dailyDist: Map<string, number> = new Map();
  const dailyCount: Map<string, number> = new Map();
  let prev: mapCommon.LatLng | null = null;
  let prevKey: string = '';
  for (let i = 0; i < pts.length; i++) {
    const rec: TrackPointRecord = pts[i];
    const key: string = getDayKey(rec.timestamp);
    const latLng: mapCommon.LatLng = { latitude: rec.latitude, longitude: rec.longitude };
    if (prev && prevKey === key) {
      const d: number = calculateDistance(prev, latLng);
      totalDist += d;
      dailyDist.set(key, (dailyDist.get(key) ?? 0) + d);
    }
    prev = latLng;
    prevKey = key;
    dailyCount.set(key, (dailyCount.get(key) ?? 0) + 1);
  }

  const activeDays: number = dailyCount.size;
  let maxDaily: number = 0;
  dailyDist.forEach((v: number) => {
    if (v > maxDaily) {
      maxDaily = v;
    }
  });

  // 最近 7 天（含今天）每日里程与点数分布
  const recent: StatDayItem[] = [];
  const now: Date = new Date();
  for (let i = 6; i >= 0; i--) {
    const d: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i);
    const key: string = `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
    recent.push({
      label: `${d.getMonth() + 1}/${d.getDate()}`,
      distance: dailyDist.get(key) ?? 0,
      count: dailyCount.get(key) ?? 0
    });
  }

  return {
    totalDistance: totalDist,
    trackCount: pts.length,
    activeDays: activeDays,
    avgDailyDist: activeDays > 0 ? totalDist / activeDays : 0,
    maxDailyDist: maxDaily,
    firstTs: pts[0].timestamp,
    lastTs: pts[pts.length - 1].timestamp,
    recent7: recent
  };
}
