import { spawn } from "node:child_process";
import type { DeviceEntry, DeviceReader } from "./reader.js";

/** Single-quoted for the device shell; paths are already limited to safe names. */
const quote = (path: string) => `'${path.replace(/'/g, `'\\''`)}'`;

const run = (adb: string, args: string[], signal: AbortSignal): Promise<string> =>
  new Promise((resolve, reject) => {
    const child = spawn(adb, args, { signal, stdio: ["ignore", "pipe", "ignore"] });
    let output = "";
    child.stdout.setEncoding("utf8").on("data", (chunk: string) => (output += chunk));
    child.on("error", reject);
    child.on("close", (code) => (code === 0 ? resolve(output) : reject(new Error(`adb exited with ${code}`))));
  });

/**
 * Reads through the `adb` command of Android platform tools. Only `stat`,
 * `ls` and `cat` run on the device, and only on paths the scan hands over.
 */
export function createAdbReader(adb = "adb"): DeviceReader {
  const controller = new AbortController();
  const { signal } = controller;
  return {
    async open() {
      return (await run(adb, ["get-state"], signal).catch(() => "")).trim() === "device";
    },
    async type(path) {
      const kind = (await run(adb, ["shell", `stat -c %F ${quote(path)}`], signal).catch(() => "")).trim();
      return kind === "directory" ? "directory" : kind.startsWith("regular") ? "file" : "other";
    },
    async *list(path) {
      const output = await run(adb, ["shell", `ls -1Ap ${quote(path)}`], signal);
      for (const line of output.split("\n")) {
        const name = line.trimEnd();
        if (!name) continue;
        const entry: DeviceEntry = name.endsWith("/")
          ? { name: name.slice(0, -1), type: "directory" }
          : { name, type: "file" };
        yield entry;
      }
    },
    read(path) {
      const child = spawn(adb, ["exec-out", `cat ${quote(path)}`], { signal, stdio: ["ignore", "pipe", "ignore"] });
      const chunks = child.stdout[Symbol.asyncIterator]() as AsyncIterator<Buffer>;
      return {
        async read() {
          const next = await chunks.next();
          return next.done ? { done: true } : { done: false, value: new Uint8Array(next.value) };
        },
        async cancel() {
          child.kill();
        },
        releaseLock() {},
      };
    },
    async close() {
      controller.abort();
    },
  };
}
