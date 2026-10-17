import { BOX_LIMITS, BoxImportError, integer, object, type BoxCandidate, type BoxCandidateNotice } from "./types.js";

type Row = Record<string, unknown>;
function invalid(): never {
  throw new BoxImportError("box_invalid_json");
}
const row = (value: unknown): Row => object(value) || invalid();
function list(value: unknown): unknown[] {
  if (!Array.isArray(value)) return invalid();
  if (value.length > BOX_LIMITS.rowsPerList) throw new BoxImportError("box_row_budget");
  return value;
}
function entries(value: unknown): [string, unknown][] {
  const result = Object.entries(row(value));
  if (result.length > BOX_LIMITS.rowsPerList) throw new BoxImportError("box_row_budget");
  return result;
}
function id(value: unknown): number {
  const result = integer(value);
  return result !== null && result > 0 && result <= 0x7fffffff ? result : invalid();
}
function numeric(value: unknown): number {
  return integer(value) ?? invalid();
}
function candidate(server?: string): BoxCandidate {
  return {
    id: crypto.randomUUID(),
    format: "inventory-json",
    members: [],
    snapshots: [],
    characters: [],
    bandItems: [],
    notices: [],
    ...(server ? { declaredIdentity: { server } } : {}),
  };
}
function notice(result: BoxCandidate, code: BoxCandidateNotice["code"], path: string): void {
  result.notices!.push({ code, path });
}
const otoServers: Record<string, string> = {
  jp: "jp",
  "global-hmt": "intl",
  "global-en": "intl",
  "global-kr": "intl",
};
const moeServers: Record<string, string> = { jp: "jp", tw: "intl", en: "intl", kr: "intl" };
function server(value: unknown, aliases: Record<string, string>): string {
  return typeof value === "string" && Object.hasOwn(aliases, value) ? aliases[value]! : invalid();
}
function otoInventory(value: Row, result: BoxCandidate): void {
  if (
    integer(value.schemaVersion) !== 1 ||
    typeof value.sourceReleaseId !== "string" ||
    !value.sourceReleaseId.trim() ||
    value.sourceReleaseId.length > 256
  )
    invalid();
  const growth = value.growth === undefined ? {} : row(value.growth);
  const seen = new Set<string>();
  for (const [kind, field] of [
    ["member", "memberCardIds"],
    ["support", "supportCardIds"],
  ] as const) {
    for (const raw of list(value[field])) {
      if (typeof raw !== "string") invalid();
      const match = new RegExp(`^${kind}-card-([1-9][0-9]*)$`).exec(raw);
      if (!match || seen.has(raw)) invalid();
      seen.add(raw);
      const cardId = id(match[1]),
        item = growth[raw] === undefined ? {} : row(growth[raw]);
      const read = (field: string): number | null => {
        if (item[field] === undefined || item[field] === null) {
          notice(result, "unknown", `inventory.growth.${raw}.${field}`);
          return null;
        }
        return numeric(item[field]);
      };
      const level = read("level"),
        rank = read("rank");
      if (kind === "member")
        result.members.push({
          cardId,
          exp: null,
          level,
          rank,
          awakeCount: read("awake"),
          liveSkillLevel: read("skillLevel"),
          performanceSkillLevel: read("gekisouSkillLevel"),
        });
      else result.snapshots.push({ cardId, exp: null, level, rank });
    }
  }
}
function oto(root: Row, personal: boolean): BoxCandidate {
  const declared = personal || root.serverId !== undefined ? server(root.serverId, otoServers) : undefined;
  if (personal && root.region !== (declared === "jp" ? "jp" : "global")) invalid();
  const result = candidate(declared);
  otoInventory(personal ? row(root.inventory) : root, result);
  if (!personal) return result;
  const account = row(root.account);
  for (const field of ["characterRanks", "bandItems"] as const) {
    if (account[field] === undefined) continue;
    for (const [key, value] of entries(account[field])) {
      if (field === "characterRanks") result.characters.push({ id: id(key), exp: null, rank: numeric(value) });
      else result.bandItems.push({ id: id(key), level: numeric(value) });
    }
  }
  if (account.tgwCardRank !== undefined) result.playerScalars = { vipRank: numeric(account.tgwCardRank) };
  if (account.bandItemTotals !== undefined) notice(result, "unsupported_field", "account.bandItemTotals");
  if (
    Object.keys(account).some((key) => !["characterRanks", "bandItems", "tgwCardRank", "bandItemTotals"].includes(key))
  )
    notice(result, "unsupported_field", "account");
  return result;
}
function moe(root: Row): BoxCandidate {
  if (root.save !== undefined && root.save !== null) throw new BoxImportError("box_linked_save_required");
  const result = candidate(server(root.server, moeServers)),
    player = row(root.player),
    seen = new Set<string>();
  const read = (value: unknown, path: string): unknown => {
    if (value === undefined) {
      notice(result, "unknown", path);
      return undefined;
    }
    const field = row(value);
    if (
      !["unknown", "observed", "manual", "conflict"].includes(String(field.status)) ||
      typeof field.needsReview !== "boolean" ||
      !Object.hasOwn(field, "value")
    )
      invalid();
    if (field.status === "unknown" || field.status === "conflict") {
      notice(result, field.status, path);
      return undefined;
    }
    if (field.needsReview) {
      notice(result, "needs_review", path);
      return undefined;
    }
    if (field.value === null) invalid();
    return field.value;
  };
  const number = (value: unknown, path: string): number | null => {
    const known = read(value, path);
    return known === undefined ? null : numeric(known);
  };
  for (const [index, value] of list(root.cards).entries()) {
    const card = row(value),
      path = `cards[${index}]`;
    if (card.kind !== "member" && card.kind !== "snap") invalid();
    const identity = read(card.identity, `${path}.identity`);
    if (identity === undefined) continue;
    const cardId = id(identity),
      key = `${card.kind}:${cardId}`;
    if (seen.has(key)) invalid();
    seen.add(key);
    const fields = row(card.fields),
      level = number(fields.level, `${path}.fields.level`),
      rank = number(fields.rank, `${path}.fields.rank`);
    if (card.kind === "member")
      result.members.push({
        cardId,
        exp: null,
        level,
        rank,
        awakeCount: number(fields.awake, `${path}.fields.awake`),
        liveSkillLevel: number(fields.liveSkillLevel, `${path}.fields.liveSkillLevel`),
        performanceSkillLevel: number(fields.gekisouSkillLevel, `${path}.fields.gekisouSkillLevel`),
      });
    else {
      result.snapshots.push({ cardId, exp: null, level, rank });
      for (const field of ["awake", "liveSkillLevel", "gekisouSkillLevel"]) {
        const value = object(fields[field]);
        if (value && value.status !== "unknown" && read(value, `${path}.fields.${field}`) !== undefined)
          notice(result, "unsupported_field", `${path}.fields.${field}`);
      }
    }
  }
  for (const [key, value] of entries(player.characterRanks ?? {})) {
    const rank = number(value, `player.characterRanks.${key}`);
    if (rank !== null) result.characters.push({ id: id(key), exp: null, rank });
  }
  const items = row(player.bandItems ?? {}),
    states = row(player.bandItemStates ?? {});
  if (new Set([...Object.keys(items), ...Object.keys(states)]).size > BOX_LIMITS.rowsPerList)
    throw new BoxImportError("box_row_budget");
  for (const key of new Set([...Object.keys(items), ...Object.keys(states)])) {
    const entity = id(key),
      path = `player.bandItemStates.${key}`,
      state = read(states[key], path);
    if (state === undefined) continue;
    if (!["owned", "active", "inactive", "not-owned", "no-bonus"].includes(String(state))) invalid();
    if (state === "not-owned") {
      result.bandItems.push({ id: entity, level: 0 });
      continue;
    }
    if (state === "inactive" || state === "no-bonus") {
      notice(result, "inactive_band_item", path);
      continue;
    }
    const level = number(items[key], `player.bandItems.${key}`);
    if (level !== null) result.bandItems.push({ id: entity, level });
  }
  const vipRank = number(player.vipRank, "player.vipRank");
  if (vipRank !== null) result.playerScalars = { vipRank };
  if (number(player.characterTotalRank, "player.characterTotalRank") !== null)
    notice(result, "unsupported_summary", "player.characterTotalRank");
  for (const key of ["memory", "eventIds"] as const)
    if (read(player[key], `player.${key}`) !== undefined) notice(result, "unsupported_field", `player.${key}`);
  for (const [, value] of entries(player.catalogFields ?? {})) {
    if (read(value, "player.catalogFields") !== undefined) notice(result, "unsupported_field", "player.catalogFields");
  }
  return result;
}

/** Projects only current declared inventory facts; observations and save links remain at the source. */
export function projectThirdPartyInventory(root: Row): BoxCandidate | null {
  if (root.format === "otonote-personal-growth") {
    if (integer(root.schemaVersion) !== 1) invalid();
    return oto(root, true);
  }
  if (root.format === "moenotes.card-box/1") return moe(root);
  if (
    root.format === undefined &&
    integer(root.schemaVersion) === 1 &&
    typeof root.sourceReleaseId === "string" &&
    Array.isArray(root.memberCardIds) &&
    Array.isArray(root.supportCardIds)
  )
    return oto(root, false);
  return null;
}
