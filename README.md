# Haneoka game data exporter

Reads your Our Notes card progress — member cards, snapshots, character ranks and band items — from the game's save files or straight from your phone, and writes it as an `ONPKG1` package that [Haneoka's team builder](https://haneoka.org/en/team-builder/) imports.

It reads only; it never logs in, calls a game server or writes to the device. Your player name, account ID and any tokens in the save are dropped before anything is written: the package carries card, character and band item IDs with their experience, levels and ranks, nothing else.

## From a phone

You need [Android platform tools](https://developer.android.com/tools/releases/platform-tools) (`adb`) and USB debugging turned on.

```sh
npx @haneoka/game-data-exporter --adb -o box.txt
```

The exporter looks in the game's own folder under `Android/data` for the Global (official and Google Play) and Japanese releases, in that order. Name one with `--package`:

| Package                        | Release               |
| ------------------------------ | --------------------- |
| `com.bilibili.sirius.official` | Global, official site |
| `com.bilibili.sirius`          | Global, Google Play   |
| `com.bushiroad.sirius`         | Japan                 |

If several phones are connected, choose one with `ANDROID_SERIAL=<serial>`.

## From files

Pass save files, ZIP or gzip archives, decrypted player JSON or an earlier package:

```sh
npx @haneoka/game-data-exporter save.dat backup.zip -o box.txt
```

Each player found becomes one line of the output. `--json` prints the parsed result instead of packages.

OtoNote personal-growth and MoeNotes card-box JSON files can be imported directly in Haneoka. Their confirmed growth values enter the existing review; unresolved fields remain notices. A MoeNotes box linked to a game save requires that save. Use the original profile JSON for import and `--json` to inspect its parsed facts.

Then open the team builder, choose **Import** and paste the contents of `box.txt`.

## As a library

```ts
import { parseBoxFiles, encodeOnpkg } from "@haneoka/game-data-exporter";

const { candidates } = await parseBoxFiles([file]);
const text = encodeOnpkg(candidates[0]);
```

`parseBoxFiles` takes `Blob`s and runs in browsers, workers and Node 20 or later. `readAndroidFiles` scans one game's folder through any `DeviceReader`; two come with the package:

- `@haneoka/game-data-exporter/adb` — the `adb` command, for Node.
- `@haneoka/game-data-exporter/webusb` — WebUSB in Chromium browsers, through [Tango](https://github.com/yume-chan/ya-webadb). Install `@yume-chan/adb` and `@yume-chan/adb-daemon-webusb` alongside it.

Reads are bounded: 32 MiB of input, 16 MiB per file, 64 MiB after decompression, 512 entries and 16 players. Anything larger is refused with an error code rather than read partially.

## The package format

`ONPKG1:` followed by base64 of gzip-compressed JSON:

```json
{ "v": 1, "m": [[cardId, exp, awakeCount, rank, liveSkillLevel, performanceSkillLevel]], "s": [[cardId, exp, rank]], "c": [[characterId, exp]], "b": [[bandItemId, level]] }
```

Experience is a decimal string so 64-bit values survive. A missing value is `null`.

## Licence

[MPL-2.0](LICENSE). The Rijndael implementation in `src/vendor` is [rijndael-js](https://github.com/Snack-X/rijndael-js) under the MIT licence; the WebUSB reader uses [Tango](https://github.com/yume-chan/ya-webadb) (MIT), and the device scan follows an MIT-licensed reference planner. Their notices are kept beside the code.
