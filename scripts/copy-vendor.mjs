import { mkdir, readdir, copyFile } from "node:fs/promises";
const source = new URL("../src/vendor/", import.meta.url);
const target = new URL("../dist/src/vendor/", import.meta.url);
await mkdir(target, { recursive: true });
for (const name of await readdir(source)) {
  if (name.endsWith(".js") || name.endsWith(".d.ts") || name === "LICENSE")
    await copyFile(new URL(name, source), new URL(name, target));
}
