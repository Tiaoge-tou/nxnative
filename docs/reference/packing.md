# Packing

## Build tools

### Homebrew .NET is on PATH but apphosts cannot find the runtime

- **Symptom:** the first extraction stops with `nx_extract exit code 131` and `.NET location: Not found`, even though `dotnet` is on `PATH`. The shader translator can fail the same way.
- **Cause:** standalone .NET apphosts search runtime roots and registered installations, not `PATH` ([.NET runtime discovery](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-environment-variables#dotnet_root-dotnet_rootx86-dotnet_root_x86-dotnet_root_x64)). Homebrew's formula installs the runtime under `libexec` and its `bin/dotnet` can be a wrapper that sets `DOTNET_ROOT` only for its own child ([Homebrew caveat](https://formulae.brew.sh/formula/dotnet)). Resolving that wrapper's symlink gives `bin`, not the runtime root.
- **Fix:** `scripts/build_ipa_from_nsp.py` `configure_dotnet` derives the root from the `Microsoft.NETCore.App` entry in `dotnet --list-runtimes`, using the build's environment, before any extraction or survey. It exports `DOTNET_ROOT` both to that environment and to `os.environ`, for tools launched with an explicit environment and those that inherit it. Caller-supplied roots, including architecture-specific overrides, retain precedence. A failed or malformed probe leaves the environment unchanged rather than guessing the wrapper's directory.
- **Found on:** [Balatro](../../dm/games/0100CD801CE5E000/README.md), first extraction with Homebrew .NET ([PR #284](https://github.com/seedds/nxnative/pull/284)). Applies to every game's build on that installation setup.

## IPA archives

### A streamed file changes size and the IPA fails its CRC check

- **Symptom:** packing succeeds, but `unzip -t` or Python's `ZipFile.testzip()` reports a bad CRC for a large deflated file.
- **Cause:** `pack_ipa.py` wrote the uncompressed size collected before reading. Its streaming check compared the output size only for stored files, so a compressible file that grew or shrank still published an archive with the old size.
- **Fix:** count uncompressed bytes as they are read and compare them with the listed size before completing either streamed method. A mismatch stops the pack and removes the partial archive, preserving the previous IPA and its reuse index. Regression tests cover growth and shrinkage with both deflate and store.
- **Found on:** synthetic IPA inputs while reviewing [PR #279](https://github.com/seedds/nxnative/pull/279); no game files required.

## Compressed inputs

### NSZ decompression rejects `--keys`

- **Symptom:** `decompress NSZ` stops immediately with `nsz: error: unrecognized arguments: --keys …`.
- **Cause:** `nsz` 4.6.1 has no `--keys` argument. It loads `keys.txt` beside `sys.argv[0]`, or falls back to `~/.switch/prod.keys`, while importing its modules, before parsing arguments ([4.6.1 key loader](https://github.com/nicoboss/nsz/blob/4.6.1/nsz/nut/Keys.py)). Newer upstream code supports `--keys`; staging `keys.txt` also supports 4.6.1.
- **Fix:** `scripts/build_ipa_from_nsp.py` `decompress_nsz` links the file selected by `-k` as `keys.txt` in the conversion's temporary folder and runs `nsz -D` there, with `sys.argv[0]` set to `nsz` before import. Input and output paths are absolute. The temporary folder and link are removed on success or failure; the user's default keys are untouched.
- **Found on:** [Super Mario Odyssey](../../dm/games/0100000000010000/README.md), converting its v0 NSZ. Applies to NSZ and XCZ inputs for every game.

## Cartridge dumps

### A cartridge dump with its update on it extracts the update as the base game

- **Symptom:** the extraction of a game whose base is an XCI that also carries its update (a "1G+1U" dump) stops with `[RED] nx_extract exit code -6`. `extract_v<version>.log` lists the update's build IDs even for the base game alone, then ends in an unhandled exception from the RomFS (`ResultFsNonRealDataVerificationFailed (2002-4604): Hash error!` from `RomFsFileSystem..ctor`, or `ArgumentException` / `InvalidOperationException` from the patch layers).
- **Cause:** the XCI's secure partition holds the update's NCAs beside the base game's, and the update's Program NCA has the program's title ID too. `nx_extract` took the first Program NCA of the lowest title ID as the base, which is the update's when the dump lists it first. Its data section is a patch (BKTR) over the base RomFS, so it cannot be read alone or under another patch. The ExeFS still opens, with the update's build IDs, because an update's code section is complete. The Control NCA (display version, icon) was also whichever of the two came last.
- **Fix:** `dm/tools/nx_extract/Program.cs` `OpenNsp` reads the base package's content metas (`*.cnmt` in its Meta NCAs) and keeps only the NCAs that its Application content meta lists, and prints how many it left out. When none of them is a Program NCA (NCA files renamed, so their names are not content IDs), it prints a `[RED]` line and reads every NCA as before. An NSP or a base-only XCI keeps every NCA but its meta NCA, so it extracts as before (Balatro's NSPs and Monster Hunter Rise's XCI give identical manifests). The update is still taken from the update NSP in the folder; the one on the cartridge is not used, so an XCI alone packs the base game's version.
- **Found on:** [The Legend of Zelda: Tears of the Kingdom](../../dm/games/0100F2C0115B6000/README.md), a 1G+1U XCI (base v0 with update 1.4.3, whose 524 MB Program NCA is listed before the base's 17.1 GB one) beside the 1.4.3 update NSP ([PR #311](https://github.com/seedds/nxnative/pull/311)). Reproduced with a package of Balatro's update NSP followed by its base NSP: the base alone and the base with the update now give the same manifests and control data as the separate NSPs. Applies to any game's XCI that carries its update.
