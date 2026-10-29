/** Descriptive aggregation of projected records. Expected values are batch counts. */
export type GachaAnalysisKind = "member" | "support" | "item" | "unknown";
export type GachaAnalysisRarity = "SSR" | "EX" | "BD" | "SR" | "R" | "item" | "unknown";
export interface GachaAnalysisPrize {
  id: string;
  kind: GachaAnalysisKind;
  rarity: number | string | null;
  quantity: number;
  pickup?: boolean | null;
  converted?: boolean;
}
export interface GachaAnalysisCost {
  freeGems?: number | null;
  paidGems?: number | null;
  tickets?: number | null;
}
export interface GachaExpectedCounts {
  high: number;
  memberSsr: number;
  supportSsr: number;
  pickup: number;
}
export interface GachaAnalysisBatch {
  id: string;
  poolId: string | null;
  pulledAt: string | null;
  prizes: readonly GachaAnalysisPrize[];
  cost?: GachaAnalysisCost | null;
  expected?: GachaExpectedCounts | null;
}
export interface GachaPrizeCounts {
  count: number;
  pickup: number;
  nonPickup: number;
  pickupUnknown: number;
  converted: number;
}
export interface GachaRarityCounts extends GachaPrizeCounts {
  rarity: GachaAnalysisRarity;
}
export interface GachaDrawCounts {
  total: number;
  high: number;
  ssr: number;
  memberSsr: number;
  supportSsr: number;
  special: number;
  member: number;
  support: number;
  item: number;
  unknown: number;
  other: number;
  unknownRarity: number;
  pickup: number;
  nonPickup: number;
  pickupUnknown: number;
  converted: number;
}
export interface GachaCostAmount {
  /** Sum of known values; null when every batch omits this cost. */
  value: number | null;
  partial: boolean;
  knownBatches: number;
  unknownBatches: number;
}
export type GachaCostSummary = Record<"freeGems" | "paidGems" | "tickets", GachaCostAmount>;
export interface GachaExpectedSummary {
  value: number | null;
  observed: number;
  delta: number | null;
  knownDraws: number;
  unknownDraws: number;
}
export interface GachaAggregate extends GachaDrawCounts {
  batches: number;
  /** Fractions, from 0 to 1. */
  observedHighRate: number | null;
  observedSsrRate: number | null;
  pullsPerHigh: number | null;
  expected: Record<keyof GachaExpectedCounts, GachaExpectedSummary>;
  expectedHigh: number | null;
  delta: number | null;
  knownDraws: number;
  unknownDraws: number;
  cost: GachaCostSummary;
}
export interface GachaKindAnalysis extends GachaDrawCounts {
  kind: GachaAnalysisKind;
  observedHighRate: number | null;
  observedSsrRate: number | null;
  pullsPerHigh: number | null;
  distribution: GachaRarityCounts[];
}
export interface GachaPoolAnalysis extends GachaAggregate {
  poolId: string | null;
}
export interface GachaDayAnalysis extends GachaDrawCounts {
  day: string | null;
  batches: number;
}
export interface GachaCardAnalysis extends GachaPrizeCounts {
  key: string;
  id: string;
  kind: GachaAnalysisKind;
  /** Resource quantity; distinct from the number of recorded draws. */
  quantity: number;
}
export interface GachaHistoryAnalysis extends GachaAggregate {
  kinds: GachaKindAnalysis[];
  distribution: GachaRarityCounts[];
  pools: GachaPoolAnalysis[];
  days: GachaDayAnalysis[];
  cards: GachaCardAnalysis[];
  undated: number;
}
export interface GachaMoneyPrices {
  freeUnitGemPrice?: number | null;
  paidUnitGemPrice?: number | null;
}
export interface GachaMoneyAmount {
  value: number | null;
  partial: boolean;
  unitGemPrice: number | null;
}
export interface GachaMoneySummary {
  freeGems: GachaMoneyAmount;
  paidGems: GachaMoneyAmount;
  sum: number | null;
  partial: boolean;
}

const KINDS: GachaAnalysisKind[] = ["member", "support", "item", "unknown"];
const RARITIES: GachaAnalysisRarity[] = ["SSR", "EX", "BD", "SR", "R", "item", "unknown"];
const COSTS = ["freeGems", "paidGems", "tickets"] as const;
const EXPECTED = ["high", "memberSsr", "supportSsr", "pickup"] as const;
const RARITY_CODES: Record<string, GachaAnalysisRarity> = {
  "2": "R",
  "3": "SR",
  "4": "SSR",
  "10": "EX",
  "20": "BD",
  R: "R",
  SR: "SR",
  SSR: "SSR",
  EX: "EX",
  BD: "BD",
};
const finiteAmount = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : null);
const integerAmount = (v: unknown): number | null =>
  typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null;

/**
 * Expected draw counts from normalized group/prize weights and the executed product.
 * Returns null for SpecialLot, ensured-new, user-selected pickups or incomplete metadata.
 * A guaranteed product requires its complete nominal draw count.
 */
export function gachaHistoryExpectation(
  pool: Readonly<Record<string, unknown>>,
  option: Readonly<Record<string, unknown>>,
  actualDrawCount: number,
): GachaExpectedCounts | null {
  const n = integerAmount(actualDrawCount);
  const count = integerAmount(option.guaranteedCount);
  const rarity = integerAmount(option.guaranteedRarity);
  const type = integerAmount(option.guaranteedType);
  const selected = integerAmount(pool.pickUpSelectCount ?? 0);
  // GachaEnsureType: None=1, MemberCard=2, SupportCard=3, either card=4, SpecialLot=5.
  if (
    n === null ||
    count === null ||
    rarity === null ||
    type === null ||
    selected === null ||
    option.guaranteedNew !== false ||
    selected > 0 ||
    type < 1 ||
    type > 4 ||
    !Array.isArray(pool.rates)
  )
    return null;
  const guaranteed = count > 0 && (rarity > 0 || type !== 1);
  const g = Math.min(count, n);
  if (
    guaranteed &&
    (integerAmount(option.drawCount) !== n ||
      count > n ||
      (pool.guaranteeRule !== "slot" && pool.guaranteeRule !== "redraw"))
  )
    return null;
  const ordinary = [0, 0, 0, 0],
    eligible = [0, 0, 0, 0],
    ineligible = [0, 0, 0, 0];
  let total = 0,
    ensured = 0,
    rejected = 0;
  for (const rawGroup of pool.rates) {
    if (!rawGroup || typeof rawGroup !== "object" || Array.isArray(rawGroup)) return null;
    const group = rawGroup as Record<string, unknown>,
      weight = finiteAmount(group.rate);
    if (weight === null) return null;
    if (weight === 0) continue;
    if (!Array.isArray(group.prizes)) return null;
    const entries: { weight: number; flags: boolean[]; qualifies: boolean }[] = [];
    let inner = 0;
    for (const rawPrize of group.prizes) {
      if (!rawPrize || typeof rawPrize !== "object" || Array.isArray(rawPrize)) return null;
      const prize = rawPrize as Record<string, unknown>,
        p = finiteAmount(prize.rate);
      if (p === null) return null;
      if (p === 0) continue;
      const resource = integerAmount(prize.resourceType);
      const kind =
        resource !== null && resource > 0
          ? resource === 2
            ? "member"
            : resource === 3
              ? "support"
              : "item"
          : prize.kind === "MemberCard"
            ? "member"
            : prize.kind === "SupportCard"
              ? "support"
              : prize.kind === "Item"
                ? "item"
                : null;
      const card = kind === "member" || kind === "support";
      const r = integerAmount(prize.rarity ?? group.rarity ?? (card ? undefined : 0));
      if (kind === null || r === null || (card && ![2, 3, 4, 10, 20].includes(r)) || typeof prize.pickup !== "boolean")
        return null;
      entries.push({
        weight: p,
        flags: [
          card && [4, 10, 20].includes(r),
          kind === "member" && r === 4,
          kind === "support" && r === 4,
          prize.pickup,
        ],
        qualifies:
          r >= rarity &&
          (type === 1 ||
            (type === 2 && kind === "member") ||
            (type === 3 && kind === "support") ||
            (type === 4 && card)),
      });
      inner += p;
    }
    if (!(inner > 0) || !Number.isFinite(inner)) return null;
    total += weight;
    for (const entry of entries) {
      const mass = weight * (entry.weight / inner);
      if (entry.qualifies) ensured += mass;
      else rejected += mass;
      for (let j = 0; j < EXPECTED.length; j++)
        if (entry.flags[j]) {
          ordinary[j] += mass;
          (entry.qualifies ? eligible : ineligible)[j] += mass;
        }
    }
  }
  if (!(total > 0) || !Number.isFinite(total) || (guaranteed && !(ensured > 0))) return null;
  const q = Math.min(1, ensured / total);
  const redraws = guaranteed && pool.guaranteeRule === "redraw" && rejected > 0 ? expectedShortfall(n, g, q) : 0;
  const result: GachaExpectedCounts = { high: 0, memberSsr: 0, supportSsr: 0, pickup: 0 };
  for (let j = 0; j < EXPECTED.length; j++) {
    const p = ordinary[j] / total;
    const a = ensured > 0 ? eligible[j] / ensured : 0;
    const value = !guaranteed
      ? n * p
      : pool.guaranteeRule === "slot"
        ? (n - g) * p + g * a
        : n * p + redraws * (a - (rejected > 0 ? ineligible[j] / rejected : 0));
    result[EXPECTED[j]] = Math.max(0, Math.min(n, value));
  }
  return result;
}

/** E[max(0, guaranteed - successes)] for successes ~ Binomial(n, q). */
function expectedShortfall(n: number, guaranteed: number, q: number): number {
  if (q <= 0) return guaranteed;
  if (q >= 1 || guaranteed === 0) return 0;
  const pivot = Math.min(guaranteed - 1, Math.floor((n + 1) * q));
  let log = pivot * Math.log(q) + (n - pivot) * Math.log(1 - q);
  for (let i = 1; i <= Math.min(pivot, n - pivot); i++) log += Math.log((n - i + 1) / i);
  const atPivot = Math.exp(log);
  let result = (guaranteed - pivot) * atPivot,
    probability = atPivot;
  for (let k = pivot; k > 0 && probability > 0; k--) {
    probability *= (k / (n - k + 1)) * ((1 - q) / q);
    result += (guaranteed - k + 1) * probability;
  }
  probability = atPivot;
  for (let k = pivot; k < guaranteed - 1 && probability > 0; k++) {
    probability *= ((n - k) / (k + 1)) * (q / (1 - q));
    result += (guaranteed - k - 1) * probability;
  }
  return Math.max(0, Math.min(guaranteed, result));
}
const compare = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
const nullableCompare = (a: string | null, b: string | null) =>
  a === b ? 0 : a === null ? 1 : b === null ? -1 : compare(a, b);
const prizeCounts = (): GachaPrizeCounts => ({ count: 0, pickup: 0, nonPickup: 0, pickupUnknown: 0, converted: 0 });
const drawCounts = (): GachaDrawCounts => ({
  total: 0,
  high: 0,
  ssr: 0,
  memberSsr: 0,
  supportSsr: 0,
  special: 0,
  member: 0,
  support: 0,
  item: 0,
  unknown: 0,
  other: 0,
  unknownRarity: 0,
  pickup: 0,
  nonPickup: 0,
  pickupUnknown: 0,
  converted: 0,
});
const distribution = () => RARITIES.map((rarity) => ({ rarity, ...prizeCounts() }));
type ExpectedState = { value: number; observed: number; knownDraws: number; knownBatches: number };
type AggregateState = {
  counts: GachaDrawCounts;
  batches: number;
  cost: GachaCostSummary;
  expected: Record<keyof GachaExpectedCounts, ExpectedState>;
};
function aggregateState(): AggregateState {
  return {
    counts: drawCounts(),
    batches: 0,
    cost: Object.fromEntries(
      COSTS.map((k) => [k, { value: null, partial: false, knownBatches: 0, unknownBatches: 0 }]),
    ) as GachaCostSummary,
    expected: Object.fromEntries(
      EXPECTED.map((k) => [k, { value: 0, observed: 0, knownDraws: 0, knownBatches: 0 }]),
    ) as AggregateState["expected"],
  };
}
function classify(p: GachaAnalysisPrize): { kind: GachaAnalysisKind; rarity: GachaAnalysisRarity } {
  const kind = KINDS.includes(p.kind) ? p.kind : "unknown";
  return {
    kind,
    rarity:
      kind === "item"
        ? "item"
        : kind === "unknown"
          ? "unknown"
          : (RARITY_CODES[
              String(p.rarity ?? "")
                .trim()
                .toUpperCase()
            ] ?? "unknown"),
  };
}
function addFlags(c: Omit<GachaPrizeCounts, "count">, p: GachaAnalysisPrize) {
  c[p.pickup === true ? "pickup" : p.pickup === false ? "nonPickup" : "pickupUnknown"]++;
  if (p.converted === true) c.converted++;
}
function addDraw(c: GachaDrawCounts, p: GachaAnalysisPrize, kind: GachaAnalysisKind, rarity: GachaAnalysisRarity) {
  c.total++;
  c[kind]++;
  if (kind === "item" || kind === "unknown") c.other++;
  if ((kind === "member" || kind === "support") && rarity === "unknown") c.unknownRarity++;
  if (rarity === "SSR") {
    c.ssr++;
    if (kind === "member") c.memberSsr++;
    else c.supportSsr++;
  }
  if (rarity === "SSR" || rarity === "EX" || rarity === "BD") c.high++;
  if (rarity === "EX" || rarity === "BD") c.special++;
  addFlags(c, p);
}
function addBatch(s: AggregateState, b: GachaAnalysisBatch, observed: GachaDrawCounts) {
  s.batches++;
  for (const key of COSTS) {
    const value = integerAmount(b.cost?.[key]),
      target = s.cost[key];
    if (value === null) {
      target.unknownBatches++;
      target.partial = true;
    } else {
      target.knownBatches++;
      target.value = (target.value ?? 0) + value;
    }
  }
  for (const key of EXPECTED) {
    const value = finiteAmount(b.expected?.[key]);
    if (value !== null && value <= b.prizes.length) {
      const target = s.expected[key];
      target.value += value;
      target.observed += observed[key];
      target.knownDraws += b.prizes.length;
      target.knownBatches++;
    }
  }
}
function rates(c: GachaDrawCounts) {
  return {
    observedHighRate: c.total ? c.high / c.total : null,
    observedSsrRate: c.total ? c.ssr / c.total : null,
    pullsPerHigh: c.high ? c.total / c.high : null,
  };
}
function finish(s: AggregateState): GachaAggregate {
  const expected = Object.fromEntries(
    EXPECTED.map((key) => {
      const v = s.expected[key];
      return [
        key,
        {
          value: v.knownBatches ? v.value : null,
          observed: v.observed,
          delta: v.knownBatches ? v.observed - v.value : null,
          knownDraws: v.knownDraws,
          unknownDraws: s.counts.total - v.knownDraws,
        },
      ];
    }),
  ) as GachaAggregate["expected"];
  if (!s.batches) for (const key of COSTS) s.cost[key].value = 0;
  return {
    ...s.counts,
    batches: s.batches,
    ...rates(s.counts),
    expected,
    expectedHigh: expected.high.value,
    delta: expected.high.delta,
    knownDraws: expected.high.knownDraws,
    unknownDraws: expected.high.unknownDraws,
    cost: s.cost,
  };
}
export function gachaHistoryDay(value: string | null, offset = 480): string | null {
  if (!Number.isInteger(offset) || Math.abs(offset) > 1440) throw new RangeError("gacha_analysis_offset");
  if (!value) return null;
  const match =
    /^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(?:[zZ]|([+-])(\d{2}):?(\d{2}))?)?$/u.exec(
      value,
    );
  if (!match) return null;
  const y = Number(match[1]),
    m = Number(match[2]),
    d = Number(match[3]);
  const days = [31, y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (m < 1 || m > 12 || d < 1 || d > days[m - 1]!) return null;
  const h = Number(match[4] ?? 0),
    minute = Number(match[5] ?? 0),
    second = Number(match[6] ?? 0);
  if (
    h > 24 ||
    minute > 59 ||
    second > 59 ||
    (h === 24 && (minute !== 0 || second !== 0 || /[1-9]/u.test(match[7] ?? ""))) ||
    Number(match[9] ?? 0) > 23 ||
    Number(match[10] ?? 0) > 59
  )
    return null;
  const iso =
    value.length === 10 ? `${value}T00:00:00Z` : /(?:[zZ]|[+-]\d{2}:?\d{2})$/u.test(value) ? value : `${value}Z`;
  const shifted = new Date(Date.parse(iso) + offset * 60000);
  return Number.isFinite(shifted.getTime()) ? shifted.toISOString().slice(0, 10) : null;
}

/** Each prize is one draw. Input batches remain distinct, including repeated IDs. */
export function analyzeGachaHistory(batches: Iterable<GachaAnalysisBatch>, offsetMinutes = 480): GachaHistoryAnalysis {
  if (!Number.isInteger(offsetMinutes) || Math.abs(offsetMinutes) > 1440) throw new RangeError("gacha_analysis_offset");
  const overall = aggregateState(),
    pools = new Map<string | null, AggregateState>(),
    days = new Map<string | null, GachaDayAnalysis>(),
    cards = new Map<string, GachaCardAnalysis>(),
    allDistribution = distribution(),
    kindCounts = new Map(KINDS.map((kind) => [kind, { ...drawCounts(), kind, distribution: distribution() }]));
  for (const batch of batches) {
    if (!Array.isArray(batch.prizes)) throw new TypeError("gacha_analysis_batch");
    const poolId = batch.poolId ?? null,
      pool = pools.get(poolId) ?? aggregateState();
    pools.set(poolId, pool);
    const day = gachaHistoryDay(batch.pulledAt, offsetMinutes),
      daily = days.get(day) ?? { ...drawCounts(), day, batches: 0 };
    days.set(day, daily);
    daily.batches++;
    const observed = drawCounts();
    for (const p of batch.prizes) {
      if (typeof p.id !== "string" || integerAmount(p.quantity) === null) throw new TypeError("gacha_analysis_prize");
      const { kind, rarity } = classify(p),
        section = kindCounts.get(kind)!;
      for (const target of [overall.counts, pool.counts, daily, observed, section]) addDraw(target, p, kind, rarity);
      for (const rows of [allDistribution, section.distribution]) {
        const row = rows[RARITIES.indexOf(rarity)]!;
        row.count++;
        addFlags(row, p);
      }
      const key = `${kind}:${p.id}`,
        card = cards.get(key) ?? { key, id: p.id, kind, quantity: 0, ...prizeCounts() };
      card.count++;
      card.quantity += p.quantity;
      addFlags(card, p);
      cards.set(key, card);
    }
    addBatch(overall, batch, observed);
    addBatch(pool, batch, observed);
  }
  return {
    ...finish(overall),
    kinds: KINDS.map((kind) => {
      const c = kindCounts.get(kind)!;
      return { ...c, ...rates(c) };
    }),
    distribution: allDistribution,
    pools: [...pools]
      .map(([poolId, s]) => ({ poolId, ...finish(s) }))
      .sort((a, b) => b.total - a.total || nullableCompare(a.poolId, b.poolId)),
    days: [...days.values()].sort((a, b) => nullableCompare(a.day, b.day)),
    cards: [...cards.values()].sort((a, b) => b.count - a.count || compare(a.key, b.key)),
    undated: days.get(null)?.total ?? 0,
  };
}

/** Gem prices are independent. Ticket balances and prize rewards are not costs. */
export function summarizeGachaHistoryMoney(cost: GachaCostSummary, prices: GachaMoneyPrices = {}): GachaMoneySummary {
  function component(amount: GachaCostAmount, rawPrice: unknown): GachaMoneyAmount {
    const unitGemPrice = finiteAmount(rawPrice),
      product = unitGemPrice !== null && amount.value !== null ? amount.value * unitGemPrice : null;
    const value = product !== null && Number.isFinite(product) ? product : null;
    return { value, unitGemPrice, partial: amount.partial || value === null };
  }
  const freeGems = component(cost.freeGems, prices.freeUnitGemPrice),
    paidGems = component(cost.paidGems, prices.paidUnitGemPrice);
  const partial = freeGems.partial || paidGems.partial;
  const sum = !partial ? freeGems.value! + paidGems.value! : null;
  return {
    freeGems,
    paidGems,
    sum: sum !== null && Number.isFinite(sum) ? sum : null,
    partial: partial || (sum !== null && !Number.isFinite(sum)),
  };
}

export interface GachaDrawInterval {
  min: number;
  max: number;
}
export interface GachaHitBatch {
  batchIds: string[];
  pulledAt: string;
  count: number;
  poolPosition: GachaDrawInterval;
  kindPosition: GachaDrawInterval;
}
export interface GachaProgressMetric {
  count: number;
  datedCount: number;
  unknownDraws: number;
  hitBatches: GachaHitBatch[];
  /** Counts draws without the target between two target draws. Adjacent hits have zero misses. */
  gaps: {
    count: number | null;
    shortest: GachaDrawInterval | null;
    longest: GachaDrawInterval | null;
    mean: GachaDrawInterval | null;
  };
  trailingMisses: GachaDrawInterval | null;
  partial: boolean;
}
export interface GachaKindProgress {
  kind: "member" | "support";
  total: number;
  datedDraws: number;
  high: GachaProgressMetric;
  pickup: GachaProgressMetric;
}
export interface GachaPoolProgress {
  poolId: string | null;
  total: number;
  datedDraws: number;
  undatedDraws: number;
  unknownKindDraws: number;
  kinds: GachaKindProgress[];
}
export interface GachaHistoryProgress {
  pools: GachaPoolProgress[];
}

type ProgressGroup = { batchIds: string[]; pulledAt: string; time: number; prizes: GachaAnalysisPrize[] };
type HitGroup = { lower: number; upper: number; count: number };
function historyTime(value: string | null): number | null {
  if (gachaHistoryDay(value, 0) === null) return null;
  const iso =
    value!.length === 10 ? `${value}T00:00:00Z` : /(?:[zZ]|[+-]\d{2}:?\d{2})$/u.test(value!) ? value! : `${value}Z`;
  return Date.parse(iso);
}
function progressTarget(p: GachaAnalysisPrize, kind: "member" | "support", metric: "high" | "pickup"): boolean | null {
  const classified = classify(p);
  if (classified.kind !== kind)
    return classified.kind === "unknown" && (metric === "high" || p.pickup !== false) ? null : false;
  return metric === "pickup"
    ? typeof p.pickup === "boolean"
      ? p.pickup
      : null
    : classified.rarity === "unknown"
      ? null
      : ["SSR", "EX", "BD"].includes(classified.rarity);
}
function gapSummary(groups: HitGroup[]): GachaProgressMetric["gaps"] {
  const count = groups.reduce((n, g) => n + g.count, 0) - 1;
  if (count <= 0) return { count: 0, shortest: null, longest: null, mean: null };
  const ranges: GachaDrawInterval[] = [];
  for (let i = 0; i < groups.length; i++) {
    const g = groups[i]!;
    if (g.count > 1) ranges.push({ min: 0, max: g.upper - g.lower + 1 - g.count });
    if (i) {
      const p = groups[i - 1]!;
      ranges.push({
        min: Math.max(0, g.lower - p.upper - 1),
        max: g.upper - g.count + 1 - (p.lower + p.count - 1) - 1,
      });
    }
  }
  const upper = ranges.reduce((n, r) => Math.max(n, r.max), 0);
  // Earliest feasible hits leave room to maximize the smallest gap.
  const fitsMinimum = (gap: number) => {
    let last: number | null = null;
    for (const g of groups) {
      last = Math.max(g.lower, last === null ? g.lower : last + gap + 1) + (g.count - 1) * (gap + 1);
      if (last > g.upper) return false;
    }
    return true;
  };
  const fitsMaximum = (gap: number) => {
    // The latest feasible hit in each group reaches the next group best.
    let last: number | null = null;
    for (const g of groups) {
      if (last === null) {
        last = g.upper;
        continue;
      }
      const first = Math.min(g.upper - g.count + 1, last + gap + 1);
      if (first < g.lower) return false;
      last = Math.min(g.upper, first + (g.count - 1) * (gap + 1));
    }
    return true;
  };
  let lo = 0,
    hi = upper;
  while (lo < hi) {
    const middle = Math.ceil((lo + hi) / 2);
    if (fitsMinimum(middle)) lo = middle;
    else hi = middle - 1;
  }
  const shortest = { min: ranges.reduce((n, r) => Math.min(n, r.min), upper), max: lo };
  lo = 0;
  hi = upper;
  while (lo < hi) {
    const middle = Math.floor((lo + hi) / 2);
    if (fitsMaximum(middle)) hi = middle;
    else lo = middle + 1;
  }
  const first = groups[0]!,
    last = groups.at(-1)!;
  // Summed gaps telescope to the distance from the first hit to the last hit.
  const mean =
    groups.length === 1
      ? { min: 0, max: (first.upper - first.lower + 1 - first.count) / count }
      : {
          min: Math.max(0, last.lower + last.count - 1 - (first.upper - first.count + 1) - count) / count,
          max: (last.upper - first.lower - count) / count,
        };
  return { count, shortest, longest: { min: lo, max: upper }, mean };
}
function progressMetric(
  all: GachaAnalysisPrize[],
  groups: ProgressGroup[],
  undated: number,
  undatedKind: number,
  kind: "member" | "support",
  metric: "high" | "pickup",
): GachaProgressMetric {
  const states = all.map((p) => progressTarget(p, kind, metric));
  const count = states.filter((v) => v === true).length,
    unknownDraws = states.filter((v) => v === null).length;
  const hits: HitGroup[] = [],
    hitBatches: GachaHitBatch[] = [];
  let before = 0,
    beforeKind = 0,
    lastUnknownEnd: number | null = null;
  for (const g of groups) {
    const targets = g.prizes.map((p) => progressTarget(p, kind, metric)),
      n = g.prizes.length,
      k = targets.filter((v) => v === true).length;
    const kindDraws = g.prizes.filter((p) => classify(p).kind === kind).length;
    if (targets.includes(null)) lastUnknownEnd = before + n;
    if (k) {
      hits.push({ lower: before + 1, upper: before + n, count: k });
      hitBatches.push({
        batchIds: g.batchIds,
        pulledAt: g.pulledAt,
        count: k,
        poolPosition: { min: before + 1, max: before + n + undated },
        kindPosition: { min: beforeKind + 1, max: beforeKind + kindDraws + undatedKind },
      });
    }
    before += n;
    beforeKind += kindDraws;
  }
  const last = hits.at(-1),
    possibleEnd = Math.max(last?.upper ?? 0, lastUnknownEnd ?? 0);
  return {
    count,
    datedCount: hits.reduce((n, g) => n + g.count, 0),
    unknownDraws,
    hitBatches,
    gaps: undated || unknownDraws ? { count: null, shortest: null, longest: null, mean: null } : gapSummary(hits),
    trailingMisses: undated
      ? null
      : { min: before - possibleEnd, max: before - (last ? last.lower + last.count - 1 : 0) },
    partial: undated > 0 || unknownDraws > 0,
  };
}

/** Pool draw positions include every prize. Equal timestamps share one unordered group. */
export function gachaHistoryProgress(batches: Iterable<GachaAnalysisBatch>): GachaHistoryProgress {
  const pools = new Map<string | null, GachaAnalysisBatch[]>();
  for (const batch of batches) {
    const id = batch.poolId ?? null,
      rows = pools.get(id) ?? [];
    rows.push(batch);
    pools.set(id, rows);
  }
  return {
    pools: [...pools]
      .map(([poolId, rows]): GachaPoolProgress => {
        const all: GachaAnalysisPrize[] = [],
          unplaced: GachaAnalysisPrize[] = [],
          byTime = new Map<number, ProgressGroup>();
        for (const batch of rows) {
          if (!Array.isArray(batch.prizes)) throw new TypeError("gacha_analysis_batch");
          for (const p of batch.prizes)
            if (typeof p.id !== "string" || integerAmount(p.quantity) === null)
              throw new TypeError("gacha_analysis_prize");
          for (const p of batch.prizes) all.push(p);
          const time = historyTime(batch.pulledAt);
          if (time === null) {
            for (const p of batch.prizes) unplaced.push(p);
            continue;
          }
          const group = byTime.get(time) ?? { batchIds: [], pulledAt: new Date(time).toISOString(), time, prizes: [] };
          group.batchIds.push(batch.id);
          for (const p of batch.prizes) group.prizes.push(p);
          byTime.set(time, group);
        }
        const groups = [...byTime.values()].sort((a, b) => a.time - b.time);
        const kinds = (["member", "support"] as const).map((kind) => {
          const total = all.filter((p) => classify(p).kind === kind).length,
            undatedKind = unplaced.filter((p) => classify(p).kind === kind).length;
          return {
            kind,
            total,
            datedDraws: total - undatedKind,
            high: progressMetric(all, groups, unplaced.length, undatedKind, kind, "high"),
            pickup: progressMetric(all, groups, unplaced.length, undatedKind, kind, "pickup"),
          };
        });
        return {
          poolId,
          total: all.length,
          datedDraws: all.length - unplaced.length,
          undatedDraws: unplaced.length,
          unknownKindDraws: all.filter((p) => classify(p).kind === "unknown").length,
          kinds,
        };
      })
      .sort((a, b) => b.total - a.total || nullableCompare(a.poolId, b.poolId)),
  };
}

export type GachaHitTarget = "high" | "pickup";
export interface GachaHit {
  batchId: string;
  pulledAt: string;
  prize: GachaAnalysisPrize;
  /** One-based draw number in the pool; draws inside one timestamp are unordered. */
  position: GachaDrawInterval;
  /** Draws without the target before this hit, since the previous hit or the first draw. */
  since: GachaDrawInterval;
}
export interface GachaPoolHits {
  poolId: string | null;
  total: number;
  undatedDraws: number;
  unknownDraws: number;
  hits: GachaHit[];
  /** Draws without the target after the latest hit. */
  trailing: GachaDrawInterval | null;
}

function hitTarget(p: GachaAnalysisPrize, target: GachaHitTarget): boolean | null {
  const { kind, rarity } = classify(p);
  if (kind === "item") return false;
  if (kind === "unknown") return null;
  if (target === "pickup") return typeof p.pickup === "boolean" ? p.pickup : null;
  return rarity === "unknown" ? null : rarity === "SSR" || rarity === "EX" || rarity === "BD";
}

/** Chronological hits per pool across both card kinds. Undated draws stay outside positions. */
export function gachaHistoryHits(batches: Iterable<GachaAnalysisBatch>, target: GachaHitTarget): GachaPoolHits[] {
  const pools = new Map<string | null, GachaAnalysisBatch[]>();
  for (const batch of batches) {
    if (!Array.isArray(batch.prizes)) throw new TypeError("gacha_analysis_batch");
    const rows = pools.get(batch.poolId ?? null) ?? [];
    rows.push(batch);
    pools.set(batch.poolId ?? null, rows);
  }
  return [...pools]
    .map(([poolId, rows]): GachaPoolHits => {
      const groups = new Map<number, { time: number; pulledAt: string; rows: GachaAnalysisBatch[] }>();
      let total = 0,
        undatedDraws = 0,
        unknownDraws = 0;
      for (const batch of rows) {
        total += batch.prizes.length;
        for (const p of batch.prizes) if (hitTarget(p, target) === null) unknownDraws++;
        const time = historyTime(batch.pulledAt);
        if (time === null) {
          undatedDraws += batch.prizes.length;
          continue;
        }
        const group = groups.get(time) ?? { time, pulledAt: new Date(time).toISOString(), rows: [] };
        group.rows.push(batch);
        groups.set(time, group);
      }
      const hits: GachaHit[] = [];
      let before = 0,
        previous: HitGroup | null = null;
      for (const group of [...groups.values()].sort((a, b) => a.time - b.time)) {
        const found = group.rows.flatMap((batch) =>
          batch.prizes.filter((p) => hitTarget(p, target) === true).map((prize) => ({ batch, prize })),
        );
        const size = group.rows.reduce((n, batch) => n + batch.prizes.length, 0);
        const lower = before + 1,
          upper = before + size,
          k = found.length;
        found.forEach(({ batch, prize }, i) => {
          const since =
            i > 0
              ? { min: 0, max: upper - lower + 1 - k }
              : previous
                ? {
                    min: Math.max(0, lower - previous.upper - 1),
                    max: upper - k + 1 - (previous.lower + previous.count - 1) - 1,
                  }
                : { min: lower - 1, max: upper - k };
          hits.push({
            batchId: batch.id,
            pulledAt: group.pulledAt,
            prize,
            position: { min: lower + i, max: upper - (k - 1 - i) },
            since,
          });
        });
        if (k) previous = { lower, upper, count: k };
        before = upper;
      }
      return {
        poolId,
        total,
        undatedDraws,
        unknownDraws,
        hits,
        trailing: undatedDraws
          ? null
          : previous
            ? { min: before - previous.upper, max: before - (previous.lower + previous.count - 1) }
            : { min: before, max: before },
      };
    })
    .sort((a, b) => b.total - a.total || nullableCompare(a.poolId, b.poolId));
}

export interface GachaLuck {
  observed: number;
  expected: number;
  draws: number;
  /** P(X < observed) + P(X = observed) / 2 under the official rates, from 0 to 1. */
  percentile: number;
  /** P(X >= observed). */
  atLeast: number;
}

function logGamma(x: number): number {
  const g = [
    676.5203681218851, -1259.1392167224028, 771.32342877765313, -176.61502916214059, 12.507343278686905,
    -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7,
  ];
  if (x < 0.5) return Math.log(Math.PI / Math.sin(Math.PI * x)) - logGamma(1 - x);
  x -= 1;
  let a = 0.99999999999980993;
  const t = x + 7.5;
  for (let i = 0; i < g.length; i++) a += g[i]! / (x + i + 1);
  return 0.5 * Math.log(2 * Math.PI) + (x + 0.5) * Math.log(t) - t + Math.log(a);
}
type Window = { lo: number; probs: number[] };
function binomialWindow(n: number, p: number): Window {
  if (p <= 0) return { lo: 0, probs: [1] };
  if (p >= 1) return { lo: n, probs: [1] };
  const mean = n * p,
    sd = Math.sqrt(n * p * (1 - p));
  const lo = Math.max(0, Math.floor(mean - 12 * sd - 4)),
    hi = Math.min(n, Math.ceil(mean + 12 * sd + 4));
  const mode = Math.min(hi, Math.max(lo, Math.floor((n + 1) * p)));
  const probs = new Array<number>(hi - lo + 1).fill(0);
  probs[mode - lo] = Math.exp(
    logGamma(n + 1) - logGamma(mode + 1) - logGamma(n - mode + 1) + mode * Math.log(p) + (n - mode) * Math.log(1 - p),
  );
  const odds = p / (1 - p);
  for (let k = mode; k < hi; k++) probs[k + 1 - lo] = probs[k - lo]! * ((n - k) / (k + 1)) * odds;
  for (let k = mode; k > lo; k--) probs[k - 1 - lo] = (probs[k - lo]! * (k / (n - k + 1))) / odds;
  return { lo, probs };
}
function convolve(a: Window, b: Window, mean: number, sd: number): Window {
  const lo = Math.max(a.lo + b.lo, Math.floor(mean - 12 * sd - 4)),
    hi = Math.min(a.lo + a.probs.length + b.lo + b.probs.length - 2, Math.ceil(mean + 12 * sd + 4));
  const probs = new Array<number>(Math.max(1, hi - lo + 1)).fill(0);
  for (let i = 0; i < a.probs.length; i++) {
    const x = a.probs[i]!;
    if (x < 1e-300) continue;
    for (let j = 0; j < b.probs.length; j++) {
      const k = a.lo + i + b.lo + j - lo;
      if (k >= 0 && k < probs.length) probs[k] += x * b.probs[j]!;
    }
  }
  return { lo, probs };
}

/**
 * Where the observed count falls among outcomes of the same draws at official rates.
 * Each batch contributes its draws at that batch's mean per-draw rate; batches without
 * expectations are left out.
 */
export function gachaHistoryLuck(
  batches: Iterable<GachaAnalysisBatch>,
  target: keyof GachaExpectedCounts,
): GachaLuck | null {
  const byRate = new Map<number, number>();
  let observed = 0,
    expected = 0,
    draws = 0;
  for (const batch of batches) {
    const n = batch.prizes.length,
      value = finiteAmount(batch.expected?.[target]);
    if (!n || value === null || value > n) continue;
    const counts = drawCounts();
    for (const p of batch.prizes) {
      const { kind, rarity } = classify(p);
      addDraw(counts, p, kind, rarity);
    }
    observed += counts[target];
    expected += value;
    draws += n;
    const p = value / n;
    const key = Math.round(p * 1e12) / 1e12;
    byRate.set(key, (byRate.get(key) ?? 0) + n);
  }
  if (!draws) return null;
  let distribution: Window = { lo: 0, probs: [1] },
    mean = 0,
    spread = 0;
  for (const [p, n] of [...byRate].sort((a, b) => a[0] - b[0])) {
    mean += n * p;
    spread += n * p * (1 - p);
    distribution = convolve(distribution, binomialWindow(n, p), mean, Math.sqrt(spread));
  }
  const total = distribution.probs.reduce((s, v) => s + v, 0);
  let below = 0,
    at = 0;
  distribution.probs.forEach((value, i) => {
    const k = distribution.lo + i;
    if (k < observed) below += value / total;
    else if (k === observed) at = value / total;
  });
  if (observed < distribution.lo) below = at = 0;
  const percentile = Math.min(1, Math.max(0, below + at / 2));
  return { observed, expected, draws, percentile, atLeast: Math.min(1, Math.max(0, 1 - below)) };
}

export interface GachaPoolRates {
  high: number;
  memberHigh: number;
  supportHigh: number;
  pickup: number;
  rarities: Record<"SSR" | "EX" | "BD" | "SR" | "R" | "item", number>;
}

/** Official single-draw probabilities from normalized group and prize weights. */
export function gachaPoolRates(pool: Readonly<Record<string, unknown>>): GachaPoolRates | null {
  if (!Array.isArray(pool.rates)) return null;
  const result: GachaPoolRates = {
    high: 0,
    memberHigh: 0,
    supportHigh: 0,
    pickup: 0,
    rarities: { SSR: 0, EX: 0, BD: 0, SR: 0, R: 0, item: 0 },
  };
  let total = 0;
  for (const rawGroup of pool.rates) {
    const group = historyRecord(rawGroup),
      weight = finiteAmount(group.rate);
    if (weight === null || !Array.isArray(group.prizes)) return null;
    if (!weight) continue;
    const prizes = group.prizes.map(historyRecord);
    const inner = prizes.reduce((s, p) => s + (finiteAmount(p.rate) ?? 0), 0);
    if (!(inner > 0)) return null;
    total += weight;
    for (const prize of prizes) {
      const mass = (weight * (finiteAmount(prize.rate) ?? 0)) / inner,
        type = integerAmount(prize.resourceType);
      const kind = type === 2 ? "member" : type === 3 ? "support" : "item";
      const rarity = kind === "item" ? "item" : RARITY_CODES[String(integerAmount(prize.rarity ?? group.rarity) ?? "")];
      if (!rarity) return null;
      result.rarities[rarity as keyof GachaPoolRates["rarities"]] += mass;
      if (rarity === "SSR" || rarity === "EX" || rarity === "BD") {
        result.high += mass;
        result[kind === "member" ? "memberHigh" : "supportHigh"] += mass;
      }
      if (prize.pickup === true) result.pickup += mass;
    }
  }
  if (!(total > 0)) return null;
  for (const key of ["high", "memberHigh", "supportHigh", "pickup"] as const) result[key] /= total;
  for (const key of Object.keys(result.rarities) as (keyof GachaPoolRates["rarities"])[]) result.rarities[key] /= total;
  return result;
}
const historyRecord = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};

export interface GachaMonthAnalysis extends GachaDrawCounts {
  month: string;
  batches: number;
  cost: GachaCostSummary;
}

/** Calendar months in server time; undated batches are excluded. */
export function gachaHistoryMonths(batches: Iterable<GachaAnalysisBatch>, offsetMinutes = 480): GachaMonthAnalysis[] {
  const months = new Map<string, AggregateState>();
  for (const batch of batches) {
    const month = gachaHistoryDay(batch.pulledAt, offsetMinutes)?.slice(0, 7);
    if (!month) continue;
    const state = months.get(month) ?? aggregateState();
    months.set(month, state);
    const observed = drawCounts();
    for (const p of batch.prizes) {
      const { kind, rarity } = classify(p);
      addDraw(state.counts, p, kind, rarity);
      addDraw(observed, p, kind, rarity);
    }
    addBatch(state, batch, observed);
  }
  return [...months]
    .sort((a, b) => compare(a[0], b[0]))
    .map(([month, state]) => ({ month, ...state.counts, batches: state.batches, cost: state.cost }));
}
