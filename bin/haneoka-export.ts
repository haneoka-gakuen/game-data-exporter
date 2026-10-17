#!/usr/bin/env node
import { openAsBlob } from "node:fs";
import { writeFile } from "node:fs/promises";
import { parseArgs } from "node:util";
import { ANDROID_CHANNELS, BoxImportError, encodeOnpkg, parseBoxFiles, readAndroidFiles } from "../src/index.js";
import { createAdbReader } from "../src/device/adb.js";

const USAGE = `Usage:
  haneoka-export --adb [--package <id>] [-o <file>]
  haneoka-export <save file>... [--json] [-o <file>]

Reads Our Notes card progress from a phone over ADB or from save files and
writes an ONPKG1 package for the team builder's import dialog.
Import OtoNote or MoeNotes profiles as their original JSON in Haneoka.
Use --json to inspect parsed profile facts.

Packages: ${ANDROID_CHANNELS.map((channel) => `${channel.packageId} (${channel.label})`).join(", ")}`;

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    adb: { type: "boolean" },
    package: { type: "string" },
    output: { type: "string", short: "o" },
    json: { type: "boolean" },
    help: { type: "boolean", short: "h" },
  },
});
if (values.help || (!values.adb && !positionals.length)) {
  console.log(USAGE);
  process.exit(values.help ? 0 : 1);
}

async function adbFiles(): Promise<Blob[]> {
  const packages = values.package ? [values.package] : ANDROID_CHANNELS.map((channel) => channel.packageId);
  let last: unknown;
  for (const packageId of packages) {
    try {
      const files = await readAndroidFiles(createAdbReader(), packageId, AbortSignal.timeout(120_000));
      if (files === null) throw new BoxImportError("device_unavailable");
      console.error(`${packageId}: ${files.length} file(s)`);
      return files;
    } catch (error) {
      last = error;
    }
  }
  throw last;
}

try {
  const files = values.adb ? await adbFiles() : await Promise.all(positionals.map((path) => openAsBlob(path)));
  const result = await parseBoxFiles(files);
  if (!result.candidates.length) throw new BoxImportError("box_no_player");
  const output = values.json
    ? JSON.stringify(result, null, 2)
    : result.candidates.map((candidate) => encodeOnpkg(candidate)).join("\n");
  for (const candidate of result.candidates)
    console.error(
      `${candidate.format}: ${candidate.members.length} cards, ${candidate.snapshots.length} snapshots, ` +
        `${candidate.characters.length} characters, ${candidate.bandItems.length} band items`,
    );
  if (values.output) await writeFile(values.output, `${output}\n`);
  else console.log(output);
} catch (error) {
  if (error instanceof BoxImportError && error.code === "box_profile_requires_json")
    console.error("Import the original profile JSON in Haneoka; use --json to inspect its parsed facts.");
  console.error(error instanceof BoxImportError ? error.code : error instanceof Error ? error.message : String(error));
  process.exit(1);
}
