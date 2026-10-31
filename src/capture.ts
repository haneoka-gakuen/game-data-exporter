// A player's cards from a captured GetPlayerData response: an HTTP archive
// (HAR) exported by an on-device proxy such as Proxyman, Stream or Surge.
// Only the fields the team builder reads are decoded; tokens and names in the
// archive are never read.
import { decompress } from "./formats.js";
import { BOX_LIMITS, BoxImportError } from "./types.js";

const METHOD = "/app.player.PlayerService/GetPlayerData";

type Fields = Map<number, Array<number | Uint8Array>>;

function varint(data: Uint8Array, at: number): [number, number] {
  let value = 0,
    scale = 1,
    i = at;
  for (;;) {
    if (i >= data.length || i - at > 9) throw new BoxImportError("box_invalid_capture");
    const byte = data[i++]!;
    value += (byte & 0x7f) * scale;
    if (!(byte & 0x80)) return [value, i];
    scale *= 128;
  }
}

/** One protobuf message: varints as numbers, length-delimited fields as bytes. */
function fields(data: Uint8Array): Fields {
  const out: Fields = new Map();
  let at = 0;
  while (at < data.length) {
    const [key, next] = varint(data, at);
    at = next;
    const number = Math.floor(key / 8),
      wire = key % 8;
    let value: number | Uint8Array;
    if (wire === 0) [value, at] = varint(data, at);
    else if (wire === 2) {
      const [length, start] = varint(data, at);
      if (start + length > data.length) throw new BoxImportError("box_invalid_capture");
      value = data.subarray(start, start + length);
      at = start + length;
    } else if (wire === 1) {
      at += 8;
      continue;
    } else if (wire === 5) {
      at += 4;
      continue;
    } else throw new BoxImportError("box_invalid_capture");
    const list = out.get(number) ?? [];
    if (list.length >= BOX_LIMITS.rowsPerList) throw new BoxImportError("box_row_budget");
    list.push(value);
    out.set(number, list);
  }
  return out;
}

const messages = (f: Fields, n: number) => (f.get(n) ?? []).filter((v): v is Uint8Array => v instanceof Uint8Array).map(fields);
const number = (f: Fields, n: number) => {
  const v = f.get(n)?.at(-1);
  return typeof v === "number" ? v : 0;
};

/** The save-shaped player the existing projection reads. */
function player(data: Uint8Array) {
  const response = fields(data);
  const [root] = messages(response, 1);
  if (!root) return null;
  return {
    _memberCards: messages(root, 2).map((m) => ({
      _masterId: number(m, 2),
      _exp: number(m, 3),
      _awakeCount: number(m, 4),
      _rank: number(m, 5),
      _liveSkillLevel: number(m, 7),
      _performanceSkillLevel: number(m, 8),
    })),
    _supportCards: messages(root, 3).map((m) => ({ _masterId: number(m, 2), _exp: number(m, 3), _rank: number(m, 5) })),
    _bandItems: messages(root, 8).map((m) => ({ _masterId: number(m, 1), _level: number(m, 2) })),
    _characters: messages(root, 12).map((m) => ({ _masterId: number(m, 1), _exp: number(m, 2) })),
  };
}

/** The message of a gRPC response body, unpacking a gzip frame. */
async function unframe(body: Uint8Array, signal?: AbortSignal): Promise<Uint8Array> {
  if (body.length < 5) throw new BoxImportError("box_invalid_capture");
  const length = ((body[1]! << 24) >>> 0) + (body[2]! << 16) + (body[3]! << 8) + body[4]!;
  if (5 + length > body.length) throw new BoxImportError("box_invalid_capture");
  const message = body.subarray(5, 5 + length);
  return body[0] === 1 ? decompress(message, "gzip", BOX_LIMITS.textBytes, signal) : message;
}

function base64(text: string): Uint8Array {
  const binary = atob(text.replace(/\s/g, ""));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

export const isCapture = (root: Record<string, unknown>) =>
  !!root.log && typeof root.log === "object" && Array.isArray((root.log as Record<string, unknown>).entries);

/** The newest GetPlayerData response in an archive, as a save-shaped player. */
export async function captureDocument(root: Record<string, unknown>, signal?: AbortSignal) {
  const entries = ((root.log as Record<string, unknown>).entries as unknown[]).filter((entry) => {
    const url = (entry as { request?: { url?: unknown } })?.request?.url;
    return typeof url === "string" && url.includes(METHOD);
  });
  for (const entry of entries.reverse()) {
    const content = (entry as { response?: { content?: { text?: unknown; encoding?: unknown } } }).response?.content;
    if (typeof content?.text !== "string" || !content.text) continue;
    const body = content.encoding === "base64" ? base64(content.text) : Uint8Array.from(content.text, (c) => c.charCodeAt(0) & 0xff);
    const result = player(await unframe(body, signal));
    if (result && (result._memberCards.length || result._supportCards.length)) return { _player: result };
  }
  throw new BoxImportError(entries.length ? "box_invalid_capture" : "box_no_capture");
}
