/**
 * TypeScript port of FastDTW for server-side anti-cheat re-verification.
 * Mirrors the Swift implementation in ios/MistyLemur/Motion/FastDTW.swift
 * so pass/fail decisions are consistent across client and server.
 */

export interface MotionSample {
  ax: number; ay: number; az: number;
  gx: number; gy: number; gz: number;
}

const GYRO_WEIGHT = 1.5;

export function fastDTWDistance(
  x: MotionSample[], y: MotionSample[], radius = 10,
): number {
  if (x.length === 0 || y.length === 0) throw new Error("non-empty required");
  return fastDTW(x, y, Math.max(1, radius)).cost;
}

interface DTWResult { cost: number; path: [number, number][]; }

function fastDTW(x: MotionSample[], y: MotionSample[], radius: number): DTWResult {
  const minSize = radius + 2;
  if (x.length <= minSize || y.length <= minSize) return fullDTW(x, y);
  const xLow = downsample(x);
  const yLow = downsample(y);
  const lower = fastDTW(xLow, yLow, radius);
  const window = expandWindow(lower.path, x.length, y.length, radius);
  return constrainedDTW(x, y, window);
}

function downsample(s: MotionSample[]): MotionSample[] {
  const out: MotionSample[] = [];
  for (let i = 0; i < s.length; i += 2) {
    if (i + 1 < s.length) {
      const a = s[i]!; const b = s[i + 1]!;
      out.push({
        ax: (a.ax + b.ax) * 0.5, ay: (a.ay + b.ay) * 0.5, az: (a.az + b.az) * 0.5,
        gx: (a.gx + b.gx) * 0.5, gy: (a.gy + b.gy) * 0.5, gz: (a.gz + b.gz) * 0.5,
      });
    } else out.push(s[i]!);
  }
  return out;
}

function expandWindow(
  path: [number, number][], nx: number, ny: number, radius: number,
): Set<number> {
  const projected = new Set<number>();
  for (const [i, j] of path) {
    for (let xi = 2 * i; xi <= 2 * i + 1 && xi < nx; xi++) {
      for (let yj = 2 * j; yj <= 2 * j + 1 && yj < ny; yj++) {
        projected.add(xi * ny + yj);
      }
    }
  }
  const expanded = new Set<number>();
  for (const key of projected) {
    const pi = Math.floor(key / ny); const pj = key % ny;
    const iLo = Math.max(0, pi - radius), iHi = Math.min(nx - 1, pi + radius);
    const jLo = Math.max(0, pj - radius), jHi = Math.min(ny - 1, pj + radius);
    for (let xi = iLo; xi <= iHi; xi++) {
      for (let yj = jLo; yj <= jHi; yj++) {
        expanded.add(xi * ny + yj);
      }
    }
  }
  expanded.add(0);
  expanded.add((nx - 1) * ny + (ny - 1));
  return expanded;
}

function localCost(a: MotionSample, b: MotionSample): number {
  const dax = a.ax - b.ax, day = a.ay - b.ay, daz = a.az - b.az;
  const dgx = a.gx - b.gx, dgy = a.gy - b.gy, dgz = a.gz - b.gz;
  const accel = dax * dax + day * day + daz * daz;
  const gyro  = dgx * dgx + dgy * dgy + dgz * dgz;
  return Math.sqrt(accel + GYRO_WEIGHT * GYRO_WEIGHT * gyro);
}

function fullDTW(x: MotionSample[], y: MotionSample[]): DTWResult {
  const nx = x.length, ny = y.length;
  const cost: number[][] = Array.from({ length: nx }, () => new Array(ny).fill(Infinity));
  cost[0]![0] = localCost(x[0]!, y[0]!);
  for (let i = 1; i < nx; i++) cost[i]![0] = cost[i - 1]![0]! + localCost(x[i]!, y[0]!);
  for (let j = 1; j < ny; j++) cost[0]![j] = cost[0]![j - 1]! + localCost(x[0]!, y[j]!);
  for (let i = 1; i < nx; i++) {
    for (let j = 1; j < ny; j++) {
      const m = Math.min(cost[i - 1]![j]!, cost[i]![j - 1]!, cost[i - 1]![j - 1]!);
      cost[i]![j] = m + localCost(x[i]!, y[j]!);
    }
  }
  return { cost: cost[nx - 1]![ny - 1]!, path: backtrace(cost) };
}

function constrainedDTW(
  x: MotionSample[], y: MotionSample[], window: Set<number>,
): DTWResult {
  const nx = x.length, ny = y.length;
  const cost: number[][] = Array.from({ length: nx }, () => new Array(ny).fill(Infinity));
  cost[0]![0] = localCost(x[0]!, y[0]!);
  for (let i = 0; i < nx; i++) {
    for (let j = 0; j < ny; j++) {
      if (i === 0 && j === 0) continue;
      if (!window.has(i * ny + j)) continue;
      const up = i > 0 ? cost[i - 1]![j]! : Infinity;
      const left = j > 0 ? cost[i]![j - 1]! : Infinity;
      const diag = (i > 0 && j > 0) ? cost[i - 1]![j - 1]! : Infinity;
      const m = Math.min(up, left, diag);
      if (Number.isFinite(m)) cost[i]![j] = m + localCost(x[i]!, y[j]!);
    }
  }
  return { cost: cost[nx - 1]![ny - 1]!, path: backtrace(cost) };
}

function backtrace(cost: number[][]): [number, number][] {
  const path: [number, number][] = [];
  let i = cost.length - 1, j = cost[0]!.length - 1;
  while (i > 0 || j > 0) {
    path.push([i, j]);
    if (i === 0) j--;
    else if (j === 0) i--;
    else {
      const up = cost[i - 1]![j]!, left = cost[i]![j - 1]!, diag = cost[i - 1]![j - 1]!;
      if (diag <= up && diag <= left) { i--; j--; }
      else if (up <= left) i--;
      else j--;
    }
  }
  path.push([0, 0]);
  return path.reverse();
}
