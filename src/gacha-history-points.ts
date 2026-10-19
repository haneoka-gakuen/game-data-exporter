/** Current point balances and redemption counters, separate from draw history. */
export const HISTORY_ACCOUNT_STATE_SCHEMA = "haneoka-gacha-account-state-v1";
export const HISTORY_ACCOUNT_STATE_BYTES = 4 * 1024 * 1024;
export type GachaPointRegion = "jp" | "global-hmt" | "global-en" | "global-kr";
export type GachaPointResetType = 1 | 2 | 3 | 4;
export interface HistoryGachaPoint {
  gachaId: string;
  balance: number | null;
}
export interface HistoryExchangeCounter {
  exchangeProductId: string;
  count: number | null;
  resetType: GachaPointResetType | null;
  counterUpdatedAt: string | null;
}
export interface HistoryAccountState {
  schema: typeof HISTORY_ACCOUNT_STATE_SCHEMA;
  source: { server: GachaPointRegion };
  collectedAt: string;
  gachaPoints: HistoryGachaPoint[];
  exchanges: HistoryExchangeCounter[];
}
export interface HistoryAccountStateOptions {
  server: GachaPointRegion;
  /** ISO 8601 instant with an explicit time-zone offset. */
  collectedAt: string;
}
export type GachaPointDate = (number | null)[] | null;
export interface GachaTargetProgress {
  gachaId: string;
  exchangeId: string;
  exchangeProductId: string;
  gachaProductId: string;
  reward: Record<string, unknown>;
  /** True when the published rule supplies a fixed, non-stepped price. */
  supported: boolean;
  basePointCost: number;
  pointCost: number | null;
  pointBalance: number | null;
  pointsNeeded: number | null;
  pointGain: number;
  productUsesNeeded: number | null;
  additionalDrawsNeeded: number | null;
  limitCount: number;
  resetType: GachaPointResetType | null;
  /** Counter value within its recorded reset scope, including periodic counters. */
  recordedExchangeCount: number | null;
  counterResetType: GachaPointResetType | null;
  counterUpdatedAt: string | null;
  /** Lifetime redemption counts require a matching NoReset counter. */
  redeemedCount: number | null;
  redeemedQuantity: number | null;
  remainingExchangeLimit: number | null;
  exchangeStartAt: GachaPointDate;
  exchangeEndAt: GachaPointDate;
  startAt: GachaPointDate;
  endAt: GachaPointDate;
}
const REGIONS: readonly unknown[] = ["jp", "global-hmt", "global-en", "global-kr"];
const MAX_ROWS = 100000;
const invalid = (): never => {
  throw new Error("history_account_state_invalid");
};
const map = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : invalid();
const list = (value: unknown, optional = false): unknown[] => {
  if (optional && value == null) return [];
  return Array.isArray(value) && value.length <= MAX_ROWS ? value : invalid();
};
function integer(value: unknown, nullable = false): number | null {
  if (nullable && value == null) return null;
  const n = typeof value === "number" ? value : typeof value === "string" && /^\d+$/u.test(value) ? Number(value) : NaN;
  return Number.isSafeInteger(n) && n >= 0 ? n : invalid();
}
function identity(value: unknown): string {
  if (typeof value === "number" && !Number.isSafeInteger(value)) return invalid();
  const result = String(value);
  return /^[1-9][0-9]{0,18}$/u.test(result) && BigInt(result) <= 9223372036854775807n ? result : invalid();
}
function resetType(value: unknown, nullable = false): GachaPointResetType | null {
  const n = integer(value, nullable);
  return n === null || (n >= 1 && n <= 4) ? (n as GachaPointResetType | null) : invalid();
}
function region(value: unknown): GachaPointRegion {
  return REGIONS.includes(value) ? (value as GachaPointRegion) : invalid();
}
/** Validate calendar fields before parsing; JS and Dart both normalize invalid dates. */
function timeText(value: unknown, instant: boolean): string | null {
  if (!instant && (value == null || value === "")) return null;
  if (typeof value !== "string") return invalid();
  const match = /^(\d{4})([-/])(\d{2})\2(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,7}))?(Z|[+-]\d{2}:?\d{2})?$/u.exec(
    value,
  );
  if (!match || (instant && (match[2] !== "-" || value[10] !== "T" || !match[9]))) return invalid();
  const [year, month, day, hour, minute, second] = [match[1], match[3], match[4], match[5], match[6], match[7]].map(
    Number,
  );
  const days = [
    31,
    year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
  ];
  if (
    year < 1 ||
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > days[month - 1] ||
    hour > 23 ||
    minute > 59 ||
    second > 59
  )
    return invalid();
  if (match[9] && match[9] !== "Z") {
    const offset = match[9].slice(1).replace(":", "");
    if (Number(offset.slice(0, 2)) > 23 || Number(offset.slice(2)) > 59) return invalid();
  }
  if (instant && !Number.isFinite(Date.parse(value))) return invalid();
  return value;
}
function onlyKeys(row: Record<string, unknown>, allowed: readonly string[]): void {
  if (Object.keys(row).some((key) => !allowed.includes(key))) invalid();
}
function unique<T>(rows: T[], key: (row: T) => string): T[] {
  const seen = new Set<string>();
  for (const row of rows) {
    const id = key(row);
    if (seen.has(id)) invalid();
    seen.add(id);
  }
  return rows;
}

/** Reads only the named Player branches. Missing rows and amounts retain their unknown state. */
export function projectHistoryAccountState(player: unknown, options: HistoryAccountStateOptions): HistoryAccountState {
  const root = map(player),
    server = region(options.server),
    collectedAt = timeText(options.collectedAt, true)!;
  const gachaPoints = unique(
    list(root._gachaRecords, true).map((value): HistoryGachaPoint => {
      const row = map(value);
      return { gachaId: identity(row._id), balance: integer(row._gachaPoint, true) };
    }),
    (row) => row.gachaId,
  );
  const exchange = root._exchange == null ? {} : map(root._exchange);
  const exchanges = unique(
    list(exchange._products, true).map((value): HistoryExchangeCounter => {
      const row = map(value),
        counter = row._timeResettableCounter == null ? {} : map(row._timeResettableCounter);
      return {
        exchangeProductId: identity(row._productId),
        count: integer(counter._count, true),
        resetType: resetType(counter._resetType, true),
        counterUpdatedAt: timeText(counter._lastUpdateTimeStr, false),
      };
    }),
    (row) => row.exchangeProductId,
  );
  return { schema: HISTORY_ACCOUNT_STATE_SCHEMA, source: { server }, collectedAt, gachaPoints, exchanges };
}

/** Portable JSON boundary. expectedServer binds an import to the caller's selected server. */
export function parseHistoryAccountState(value: unknown, expectedServer?: GachaPointRegion): HistoryAccountState {
  if (typeof value === "string") {
    if (new TextEncoder().encode(value).byteLength > HISTORY_ACCOUNT_STATE_BYTES) return invalid();
    try {
      value = JSON.parse(value);
    } catch {
      return invalid();
    }
  }
  const root = map(value),
    source = map(root.source);
  onlyKeys(root, ["schema", "source", "collectedAt", "gachaPoints", "exchanges"]);
  onlyKeys(source, ["server"]);
  if (root.schema !== HISTORY_ACCOUNT_STATE_SCHEMA) return invalid();
  const server = region(source.server);
  if (expectedServer !== undefined && server !== region(expectedServer))
    throw new Error("history_account_state_server_mismatch");
  const gachaPoints = unique(
    list(root.gachaPoints).map((value): HistoryGachaPoint => {
      const row = map(value);
      onlyKeys(row, ["gachaId", "balance"]);
      if (!("balance" in row)) return invalid();
      return { gachaId: identity(row.gachaId), balance: integer(row.balance, true) };
    }),
    (row) => row.gachaId,
  );
  const exchanges = unique(
    list(root.exchanges).map((value): HistoryExchangeCounter => {
      const row = map(value);
      onlyKeys(row, ["exchangeProductId", "count", "resetType", "counterUpdatedAt"]);
      if (!["count", "resetType", "counterUpdatedAt"].every((key) => key in row)) return invalid();
      return {
        exchangeProductId: identity(row.exchangeProductId),
        count: integer(row.count, true),
        resetType: resetType(row.resetType, true),
        counterUpdatedAt: timeText(row.counterUpdatedAt, false),
      };
    }),
    (row) => row.exchangeProductId,
  );
  return {
    schema: HISTORY_ACCOUNT_STATE_SCHEMA,
    source: { server },
    collectedAt: timeText(root.collectedAt, true)!,
    gachaPoints,
    exchanges,
  };
}

const REWARD_FIELDS = [
  "id",
  "kind",
  "resourceType",
  "resourceId",
  "count",
  "name",
  "secondary",
  "image",
  "href",
  "rarity",
  "cardType",
  "characterId",
  "characterIds",
  "characterDetails",
  "musicId",
  "musicTitle",
  "jacketThumbUrl",
  "jacketUrl",
  "bandId",
  "bandIds",
  "musicType",
  "musicCategories",
  "bandName",
  "artistName",
  "bandDetails",
] as const;
function rewardProjection(value: unknown): Record<string, unknown> {
  const row = map(value),
    result: Record<string, unknown> = {};
  integer(row.resourceType);
  identity(row.resourceId);
  integer(row.count);
  for (const key of REWARD_FIELDS) if (row[key] !== undefined) result[key] = JSON.parse(JSON.stringify(row[key]));
  return result;
}
function dateProjection(value: unknown): GachaPointDate {
  if (value == null) return null;
  return list(value).map((stamp) => integer(stamp, true));
}
function safeProduct(a: number | null, b: number): number | null {
  const result = a === null ? null : a * b;
  return result !== null && Number.isSafeInteger(result) ? result : null;
}

/**
 * Projects fixed-price targets joined by ResourceType 7 + gachaId.
 * The supplied catalog must belong to options.server. Dates retain normalized
 * locale slots. Periodic counters preserve their recorded scope; current reset
 * boundaries require a separate verified reset calendar.
 */
export function gachaTargetProgress(
  pool: Readonly<Record<string, unknown>>,
  exchanges: Readonly<Record<string, unknown>>,
  state: HistoryAccountState | null,
  options: { server: GachaPointRegion; gachaProductId: string },
): GachaTargetProgress[] {
  const server = region(options.server),
    snapshot = state === null ? null : parseHistoryAccountState(state, server);
  const gachaId = identity(pool.id),
    selectedId = identity(options.gachaProductId);
  const drawOptions = list(pool.drawOptions).map(map);
  const selected = drawOptions.filter((row) => identity(row.id) === selectedId);
  if (selected.length !== 1) throw new Error("gacha_point_product_not_found");
  const option = selected[0],
    drawCount = integer(option.drawCount)!,
    pointGain = integer(option.gachaPoint)!;
  if (drawCount === 0) return invalid();
  const balance = snapshot?.gachaPoints.find((row) => row.gachaId === gachaId)?.balance ?? null;
  const counters = new Map(snapshot?.exchanges.map((row) => [row.exchangeProductId, row]) ?? []);
  const result: GachaTargetProgress[] = [],
    seen = new Set<string>();
  for (const [entryId, value] of Object.entries(map(exchanges.entries))) {
    const exchange = map(value),
      currency = map(exchange.currency);
    if (integer(currency.resourceType) !== 7 || identity(currency.resourceId) !== gachaId) continue;
    const exchangeId = identity(exchange.id ?? entryId);
    for (const value of list(exchange.products)) {
      const target = map(value),
        exchangeProductId = identity(target.id);
      if (seen.has(exchangeProductId)) return invalid();
      seen.add(exchangeProductId);
      const reward = rewardProjection(target.reward),
        basePointCost = integer(target.cost)!,
        limitCount = integer(target.limit)!;
      const targetReset = resetType(target.resetType, true),
        counter = counters.get(exchangeProductId);
      const supported =
        Array.isArray(target.paymentSteps) &&
        Array.isArray(target.paymentStepResourceCounts) &&
        target.paymentSteps.length === 0 &&
        target.paymentStepResourceCounts.length === 0;
      const pointCost = supported ? basePointCost : null;
      const pointsNeeded = pointCost === null || balance === null ? null : Math.max(0, pointCost - balance);
      const productUsesNeeded = pointsNeeded === null || pointGain === 0 ? null : Math.ceil(pointsNeeded / pointGain);
      const recordedExchangeCount = counter?.count ?? null;
      const redeemedCount = targetReset === 1 && counter?.resetType === 1 ? recordedExchangeCount : null;
      result.push({
        gachaId,
        exchangeId,
        exchangeProductId,
        gachaProductId: selectedId,
        reward,
        supported,
        basePointCost,
        pointCost,
        pointBalance: balance,
        pointsNeeded,
        pointGain,
        productUsesNeeded,
        additionalDrawsNeeded: safeProduct(productUsesNeeded, drawCount),
        limitCount,
        resetType: targetReset,
        recordedExchangeCount,
        counterResetType: counter?.resetType ?? null,
        counterUpdatedAt: counter?.counterUpdatedAt ?? null,
        redeemedCount,
        redeemedQuantity: safeProduct(redeemedCount, integer(reward.count)!),
        remainingExchangeLimit:
          limitCount > 0 && redeemedCount !== null ? Math.max(0, limitCount - redeemedCount) : null,
        exchangeStartAt: dateProjection(exchange.startAt),
        exchangeEndAt: dateProjection(exchange.endAt),
        startAt: dateProjection(target.startAt),
        endAt: dateProjection(target.endAt),
      });
    }
  }
  return result;
}
