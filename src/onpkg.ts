import { gzipSync } from "fflate";
import { BoxImportError, type BoxCandidate } from "./types.js";

/**
 * The compact package every Haneoka importer reads: card, character and band
 * item progress only, as positional rows, gzip-compressed and base64-encoded.
 * Experience stays a decimal string so 64-bit values survive.
 */
export interface CompactPackage {
  v: 1;
  m: [number, string | null, number | null, number | null, number | null, number | null][];
  s: [number, string | null, number | null][];
  c: [number, string | null][];
  b: [number, number | null][];
}

export function compactPackage(candidate: BoxCandidate): CompactPackage {
  if (candidate.format === "inventory-json" || candidate.format === "reference-profile")
    throw new BoxImportError("box_profile_requires_json");
  return {
    v: 1,
    m: candidate.members.map((row) => [
      row.cardId,
      row.exp,
      row.awakeCount,
      row.rank,
      row.liveSkillLevel,
      row.performanceSkillLevel,
    ]),
    s: candidate.snapshots.map((row) => [row.cardId, row.exp, row.rank]),
    c: candidate.characters.map((row) => [row.id, row.exp]),
    b: candidate.bandItems.map((row) => [row.id, row.level]),
  };
}

/** `ONPKG1:` text that can be pasted into the team builder's import dialog. */
export function encodeOnpkg(candidate: BoxCandidate): string {
  const bytes = gzipSync(new TextEncoder().encode(JSON.stringify(compactPackage(candidate))));
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000)
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  return `ONPKG1:${btoa(binary)}`;
}
