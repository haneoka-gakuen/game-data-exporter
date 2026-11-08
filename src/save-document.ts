import { decryptBox, isEncryptedBox } from "./crypt.js";
import { losslessJson, decompress, zipEntries, readZipEntry } from "./formats.js";
import { BOX_LIMITS, BoxImportError, type BoxParseOptions } from "./types.js";
export { losslessJson } from "./formats.js";
export interface SaveDocument {
  name: string;
  value: unknown;
}
/** Decode local save containers without projecting away non-Box progress. */
export async function readSaveDocuments(
  files: readonly File[],
  options: BoxParseOptions = {},
): Promise<SaveDocument[]> {
  if (
    !files.length ||
    files.length > BOX_LIMITS.entries ||
    files.reduce((n, f) => n + f.size, 0) > BOX_LIMITS.inputBytes
  )
    throw new BoxImportError("box_input_budget");
  const results: SaveDocument[] = [];
  let expanded = 0,
    entries = 0;
  const read = async (bytes: Uint8Array, name: string, depth: number): Promise<void> => {
    options.signal?.throwIfAborted();
    if (++entries > BOX_LIMITS.entries || depth > 3 || bytes.length > BOX_LIMITS.fileBytes)
      throw new BoxImportError("box_expanded_budget");
    if (bytes[0] === 0x50 && bytes[1] === 0x4b) {
      for (const entry of zipEntries(bytes)) {
        const data = await readZipEntry(bytes, entry, options);
        expanded += data.length;
        if (expanded > BOX_LIMITS.expandedBytes) throw new BoxImportError("box_expanded_budget");
        try {
          await read(data, entry.path, depth + 1);
        } finally {
          data.fill(0);
        }
      }
      return;
    }
    if (isEncryptedBox(bytes) || (bytes[0] === 0x1f && bytes[1] === 0x8b)) {
      const data = isEncryptedBox(bytes)
        ? await decryptBox(bytes, options.signal)
        : await decompress(bytes, "gzip", BOX_LIMITS.fileBytes, options.signal);
      expanded += data.length;
      if (expanded > BOX_LIMITS.expandedBytes) {
        data.fill(0);
        throw new BoxImportError("box_expanded_budget");
      }
      try {
        await read(data, name, depth + 1);
      } finally {
        data.fill(0);
      }
      return;
    }
    const prefix = new TextDecoder().decode(bytes.subarray(0, 64)).trimStart();
    if (!prefix.startsWith("{")) return;
    results.push({ name, value: losslessJson(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) });
  };
  for (let i = 0; i < files.length; i++) {
    const bytes = new Uint8Array(await files[i]!.arrayBuffer());
    try {
      await read(bytes, files[i]!.name, 0);
    } finally {
      bytes.fill(0);
    }
    options.progress?.(i + 1, files.length);
  }
  if (!results.length) throw new BoxImportError("box_no_player");
  return results;
}
