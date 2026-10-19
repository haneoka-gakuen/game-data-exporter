export const HISTORY_SCHEMA = "haneoka-gacha-history-v1";
export const HISTORY_BYTES = 16 * 1024 * 1024;
export const HISTORY_REGIONS = ["jp", "global-hmt", "global-en", "global-kr"] as const;
export type HistoryRegion = (typeof HISTORY_REGIONS)[number];
export const historyOffsetMinutes = (server: HistoryRegion): number =>
  ({ jp: 540, "global-hmt": 480, "global-en": 0, "global-kr": 540 })[server];
export interface HistoryPrize {
  prizeId: string;
  converted: boolean;
}
export interface HistoryExecution {
  poolId: string | null;
  productId: string | null;
  executedAt: number | null;
  freeGems: number | null;
  paidGems: number | null;
  tickets: number | null;
  prizes: HistoryPrize[];
}
export interface HistorySnapshot {
  schema: typeof HISTORY_SCHEMA;
  source: { server: HistoryRegion; clientVersion: string; accountKey?: string };
  queriedAt: string;
  historyKind: string;
  legacyOmittedCount: number;
  coverage: { scope: string; retentionDays: null; orderWithinBatch: null };
  batches: HistoryExecution[];
}
export const historyObject = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
function amount(value: unknown, maximum = 2147483647): number | null {
  if (value == null) return null;
  const result = typeof value === "number" ? value : /^\d+$/u.test(String(value)) ? Number(value) : NaN;
  if (!Number.isSafeInteger(result) || result < 0 || result > maximum) throw new Error("history_import_invalid");
  return result;
}
function id(value: unknown, nullable = false): string | null {
  if (value == null && nullable) return null;
  if (typeof value === "number" && !Number.isSafeInteger(value)) throw new Error("history_import_invalid");
  const text = String(value);
  if (!/^[1-9][0-9]{0,18}$/u.test(text) || BigInt(text) > 9223372036854775807n)
    throw new Error("history_import_invalid");
  return text;
}
/** Projects the portable contract; credentials and unrelated save fields never enter history storage. */
export function parseHistory(value: unknown): HistorySnapshot {
  const root = historyObject(value),
    source = historyObject(root.source),
    coverage = historyObject(root.coverage);
  if (root.schema !== HISTORY_SCHEMA && !(root.format === "otonote-gacha-history" && root.schemaVersion === 1))
    throw new Error("history_import_invalid");
  const server = source.server ?? source.serverId;
  if (
    !(HISTORY_REGIONS as readonly unknown[]).includes(server) ||
    !Array.isArray(root.batches) ||
    root.batches.length > 100000
  )
    throw new Error("history_import_invalid");
  if (typeof root.queriedAt !== "string" || !Number.isFinite(Date.parse(root.queriedAt)))
    throw new Error("history_import_invalid");
  if (
    source.accountKey != null &&
    (typeof source.accountKey !== "string" || !/^[a-f0-9]{64}$/u.test(source.accountKey))
  )
    throw new Error("history_import_invalid");
  let count = 0;
  const batches = root.batches.map((value): HistoryExecution => {
    const row = historyObject(value);
    if (!Array.isArray(row.prizes) || !row.prizes.length) throw new Error("history_import_invalid");
    return {
      poolId: id(row.poolId, true),
      productId: id(row.productId, true),
      executedAt: amount(row.executedAt, 253402271999),
      freeGems: amount(row.freeGems),
      paidGems: amount(row.paidGems),
      tickets: amount(row.tickets),
      prizes: row.prizes.map((value): HistoryPrize => {
        const prize = historyObject(value);
        if (++count > 250000 || typeof prize.converted !== "boolean") throw new Error("history_import_invalid");
        return { prizeId: id(prize.prizeId)!, converted: prize.converted };
      }),
    };
  });
  return {
    schema: HISTORY_SCHEMA,
    source: {
      server: server as HistoryRegion,
      clientVersion: String(source.clientVersion ?? "").slice(0, 32),
      ...(typeof source.accountKey === "string" ? { accountKey: source.accountKey } : {}),
    },
    queriedAt: new Date(root.queriedAt).toISOString(),
    historyKind: String(root.historyKind ?? coverage.historyKind ?? "execution").slice(0, 32),
    legacyOmittedCount: amount(root.legacyOmittedCount ?? coverage.legacyOmittedCount) ?? 0,
    coverage: {
      scope: ["server-returned", "local-collected", "selected-records"].includes(String(coverage.scope))
        ? String(coverage.scope)
        : "server-returned",
      retentionDays: null,
      orderWithinBatch: null,
    },
    batches,
  };
}

/** Union snapshots of one known account, preserving repeated identical draws. */
export function mergeHistory(newer: HistorySnapshot, older: HistorySnapshot): HistorySnapshot {
  if (newer.source.server !== older.source.server) throw new Error("history_import_invalid");
  if (newer.source.accountKey && older.source.accountKey && newer.source.accountKey !== older.source.accountKey)
    throw new Error("history_import_invalid");
  if (!newer.source.accountKey && older.source.accountKey)
    newer = { ...newer, source: { ...newer.source, accountKey: older.source.accountKey } };
  if (!newer.batches.length && older.batches.length)
    return {
      ...newer,
      batches: older.batches,
      historyKind: older.historyKind,
      coverage: { ...newer.coverage, scope: "local-collected" },
    };
  if (newer.historyKind !== older.historyKind) return newer;
  const identity = (row: HistoryExecution) =>
    JSON.stringify([
      row.poolId,
      row.productId,
      row.executedAt,
      row.freeGems,
      row.paidGems,
      row.tickets,
      row.prizes.map((prize) => `${prize.prizeId}:${prize.converted}`).sort(),
    ]);
  const remaining = new Map<string, number>(),
    batches = [...newer.batches];
  for (const row of newer.batches) remaining.set(identity(row), (remaining.get(identity(row)) ?? 0) + 1);
  for (const row of older.batches) {
    const key = identity(row),
      count = remaining.get(key) ?? 0;
    if (count) remaining.set(key, count - 1);
    else batches.push(row);
  }
  return batches.length === newer.batches.length
    ? newer
    : { ...newer, batches, coverage: { ...newer.coverage, scope: "local-collected" } };
}

export function mergeHistoryCollection(
  stored: readonly HistorySnapshot[],
  incoming: HistorySnapshot,
): HistorySnapshot[] {
  for (const history of stored) {
    if (
      history.source.server !== incoming.source.server ||
      (history.source.accountKey &&
        incoming.source.accountKey &&
        history.source.accountKey !== incoming.source.accountKey)
    )
      throw new Error("history_import_invalid");
  }
  if (!incoming.batches.length && stored.some((history) => history.batches.length)) {
    return stored.map((history) =>
      Date.parse(incoming.queriedAt) >= Date.parse(history.queriedAt) ? mergeHistory(incoming, history) : history,
    );
  }
  const previous = stored.find((history) => history.historyKind === incoming.historyKind);
  const history = previous
    ? Date.parse(incoming.queriedAt) >= Date.parse(previous.queriedAt)
      ? mergeHistory(incoming, previous)
      : mergeHistory(previous, incoming)
    : incoming;
  return [
    ...stored.filter((row) => row.historyKind !== incoming.historyKind && row.historyKind !== "empty"),
    history,
  ].sort((a, b) =>
    a.historyKind === "execution"
      ? -1
      : b.historyKind === "execution"
        ? 1
        : Date.parse(b.queriedAt) - Date.parse(a.queriedAt),
  );
}
