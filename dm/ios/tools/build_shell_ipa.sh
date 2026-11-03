#!/bin/bash
# Shell prototype (proto/shell2): pack TWO games into one unsigned IPA — Silksong and Hades II behind the
# pick-a-game screen in dm/ios/Sources/main.m (DM_SHELL_PROTO). Each game keeps its own everything:
#   guest modules embedded under its one-letter section prefix (gen_embed.py DM_EMBED_PREFIX, matching
#   dm/host/dm_prof.c's seg_prefix), its tables and launcher settings at DmIOS.app/dm/<title ID>/, its
#   shader libraries at DmIOS.app/msl/<title ID>/b-<chain>, its romfs.id beside its tables (the identity
#   of the RomFS image the player already has; no game files are packed, DM_COPY_ROMFS=NO throughout).
# The pad skin art of both games sits at DmIOS.app/dm/padskin* and dm/hadesskin* as in the single-game
# builds (DmGamepad.m reads those bundle paths; the picked game's env.txt turns its set on).
# The per-game parts (rewritten modules, iOS shader libraries, RomFS image for the identity line) come
# from two ordinary build_ipa_from_nsp.py runs; this script only assembles. Usage: build_shell_ipa.sh <out.ipa>
#   Environment: W=shell work folder (required); per game <P>_PATCHED, <P>_MSL (the folder holding b-<chain>),
#   <P>_ROMFS (its RomFS.img), <P>_ENV (its env.txt), with <P> = SILK / HADES; FONT_PY as in build_ipa.sh.
#   <P>_GD names the profile folder the game's build actually used when it differs from the repo one (the
#   NSP script derives a profile into the build folder for a package version its build rows do not name,
#   and the shader step writes c1_full.tsv there); default: the repo profile dm/games/<title ID>.
set -u
cd "$(dirname "$0")/.." || exit 1
IOS_SOURCE=$PWD; IOS=$PWD; DM=$(cd .. && pwd)
t() { echo "[$(date +%T)] $*"; }; die() { t "FAIL: $*"; exit 1; }
[ -n "${W:-}" ] || die "W is not set (the shell work folder)"
OUT_IPA=${1:-$W/shell.ipa}; O=$W/pkg; DD=$O/dd
SILK=010013C00E930000; HADES=0100A00019DE0000
export DM_SHELL_GAMES="$SILK,$HADES" GAME=$SILK   # gen_build.py's make generates the combined profile header for GAME (dm/games/game.py shell_header)
gp() { python3 "$DM/games/game.py" "$1" "$2" || die "game profile $1: $2"; }
for P in SILK HADES; do
  eval "PATCHED=\${${P}_PATCHED:-}; MSL=\${${P}_MSL:-}; ROMFS=\${${P}_ROMFS:-}; ENVF=\${${P}_ENV:-}"
  [ -d "$PATCHED" ] && [ -d "$MSL" ] && [ -f "$ROMFS" ] && [ -f "$ENVF" ] || die "$P: set ${P}_PATCHED, ${P}_MSL, ${P}_ROMFS (image) and ${P}_ENV"
done
V=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$DM/gfx/nvn/dmsh_chain.h"); [ -n "$V" ] || die "no chain version"
export LC_ALL=C DM_BUNDLE_ID=org.nxnative.shellproto DM_DISPLAY_NAME="Silksong + Hades II" DM_APP_VERSION=1.0 \
  DM_APP_CATEGORY=$(gp $SILK app_category) DM_TEAM_ID=0000000000 DM_SHOW_FPS=NO DM_LANG=${DM_LANG:-zh-Hans}
t "shell: $DM_DISPLAY_NAME ($DM_BUNDLE_ID), games $SILK + $HADES, chain $V"
rm -rf Gen && mkdir -p Gen/dm/$SILK Gen/dm/$HADES || die "mkdir Gen"
python3 tools/gen_build.py "$DM/host" Gen > Gen/dm.xcconfig || die "gen_build"
grep -q 'DM_SHELL_PROTO' "$DM/host/gen/$SILK/game_profile.h" || die "the generated profile header is not the combined shell one (DM_SHELL_GAMES did not reach game.py)"
# Embedded guest modules, one gen_embed run per game under its section prefix; the two .S files concatenate
F=""
for spec in "$SILK s" "$HADES h"; do set -- $spec; TID=$1; PFX=$2
  if [ "$TID" = "$SILK" ]; then PATCHED=$SILK_PATCHED; GD=${SILK_GD:-}; else PATCHED=$HADES_PATCHED; GD=${HADES_GD:-}; fi
  MODS=$(gp $TID modules)
  for f in $MODS; do [ -f "$PATCHED/$f.patched.bin" ] && [ -f "$PATCHED/$f.fixups.tsv" ] || die "no rewritten module $PATCHED/$f"; done
  Fp=$(DM_EMBED_PREFIX=$PFX python3 tools/gen_embed.py "$PATCHED" Gen/embed-$TID.S $MODS) || die "gen_embed $TID"
  cat Gen/embed-$TID.S >> Gen/embed.S; F="$F $Fp"
  [ -n "$GD" ] || GD=$(python3 "$DM/games/game.py" dir "$TID") || die "profile dir $TID"
  cp "$PATCHED"/*.fixups.tsv "$PATCHED"/*.gates.tsv "$PATCHED"/*.cuts.tsv "$PATCHED"/*.obs.tsv Gen/dm/$TID/ || die "copy rewriter tables $TID"
  if [ -f "$PATCHED/nro.tsv" ]; then cp "$PATCHED/nro.tsv" Gen/dm/$TID/ || die "copy the NRO table $TID"; fi
  cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" "$GD/c1_full.tsv" Gen/dm/$TID/ || die "copy shader tables $TID (a full dmsh_build.py run of this game must have made c1_full.tsv)"
  if [ -f "$GD/cb_extent.tsv" ]; then cp "$GD/cb_extent.tsv" Gen/dm/$TID/ || die "copy cb_extent.tsv $TID"; fi
  for f in shader_pairs.tsv pso_pairs.tsv; do if [ -f "$GD/$f" ]; then cp "$GD/$f" Gen/dm/$TID/ || die "copy $f $TID"; fi; done
done
echo "OTHER_LDFLAGS = \$(inherited) \$(DM_FRAMEWORKS) $F" >> Gen/dm.xcconfig
# Per-game launcher settings, env file and RomFS identity (the identity of the image the player already
# imported for the single-game build: same extraction, so size and index match the delivered datapack)
for spec in "$SILK $SILK_PATCHED $SILK_ROMFS $SILK_ENV" "$HADES $HADES_PATCHED $HADES_ROMFS $HADES_ENV"; do set -- $spec; TID=$1
  PKG=$(gp $TID package); NACP=$(dirname "$3")/control.nacp   # the packed version's control data sits beside its RomFS image (nx_extract saves the update's there)
  [ -f "$NACP" ] || die "no control.nacp beside $3 (settings.py needs the packed version's)"
  VER=$(python3 "$DM/tools/nacp.py" --version "$NACP") || VER=1.0
  L=$(GFXAPI=nvn python3 "$DM/games/settings.py" "$TID" "$2" "$NACP" Gen/dm/$TID/launcher.json) || die "launcher settings $TID"
  t "launcher $TID: $L"
  cp "$4" Gen/dm/$TID/env.txt || die "copy env $TID"
  python3 -I "$DM/tools/romfs_image.py" --identity "$3" "$TID" "$VER" "$PKG" > Gen/dm/$TID/romfs.id || die "identity of $3"
  t "identity $TID: $(cat Gen/dm/$TID/romfs.id)"
done
# Pad skin art of both games, gated on each game's env as in build_ipa.sh, at the bundle's dm/ root
grep -q '^DM_PAD_SKIN=1' Gen/dm/$SILK/env.txt && for s in padskin padskin-badge padskin-metal padskin-glass; do
  [ -d "$IOS_SOURCE/$s" ] && { mkdir -p Gen/dm/$s && cp "$IOS_SOURCE"/$s/*.png Gen/dm/$s/ || die "copy $s art"; }; done
grep -q '^DM_PAD_HADES=1' Gen/dm/$HADES/env.txt && for s in hadesskin hadesskin-badge; do
  [ -d "$IOS_SOURCE/$s" ] && { mkdir -p Gen/dm/$s && cp "$IOS_SOURCE"/$s/*.png Gen/dm/$s/ || die "copy $s art"; }; done
# Shared fonts (game-independent; main.m points DM_FONT_DIR at dm/font in a shell build too)
mkdir -p Gen/dm/font && cp "${STD_FONT:-/System/Library/Fonts/Supplemental/Arial Unicode.ttf}" Gen/dm/font/standard.ttf || die "copy standard font (STD_FONT=a TTF)"
"${FONT_PY:-python3}" "$DM/tools/make_ext_font.py" Gen/dm/font/nintendo_ext.ttf > /dev/null || die "make_ext_font.py (pip install fonttools, or FONT_PY=python with fontTools)"
# App icon: Silksong's (the shell's first game); the catalog is always created, the project always lists it
ICON=$(dirname "$SILK_ROMFS")/icon.jpg
mkdir -p Gen/Assets.xcassets && printf '{"info":{"author":"xcode","version":1}}\n' > Gen/Assets.xcassets/Contents.json || die "asset catalog"
if [ -f "$ICON" ]; then
  AI=Gen/Assets.xcassets/AppIcon.appiconset; mkdir -p "$AI" || die "mkdir $AI"
  sips -s format png -z 1024 1024 "$ICON" --out "$AI/icon.png" > /dev/null || die "sips: cannot convert the icon $ICON"
  printf '{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}\n' > "$AI/Contents.json"
  echo "DM_APPICON = AppIcon" >> Gen/dm.xcconfig; t "app icon: $ICON"
else t "no app icon ($ICON not found): the home-screen icon stays blank"; fi
export DM_SCHEME_NAME=DmIOS
xcodegen generate -q > /dev/null || die "xcodegen"
COMMIT=$(git -C "$DM" rev-parse --short=12 HEAD 2> /dev/null) && { [ -z "$(git -C "$DM" status --porcelain --untracked-files=no 2> /dev/null)" ] || COMMIT=$COMMIT+dirty
  /usr/libexec/PlistBuddy -c "Add :DMCommit string $COMMIT" Gen/Info.plist > /dev/null || die "DMCommit"; t "source: $COMMIT"; }
/usr/libexec/PlistBuddy -c "Add :DMChain string $V" Gen/Info.plist > /dev/null || die "DMChain"
/usr/libexec/PlistBuddy -c "Add :DMBuildTime integer $(date +%s)" Gen/Info.plist > /dev/null || die "DMBuildTime"
# The resource paths the project phases want (IPA mode skips the copy; Silksong's name the placeholders)
DM_RESOURCE_BUILD=$(gp $SILK package) GAME=$SILK python3 tools/gen_resources.py "$IOS" "$SILK_ROMFS" "$(gp $SILK romfs_marker)" "$SILK_MSL/b-$V" "b-$V" "" "$O/xcode-dd" "$DM/gfx/nvn/dmsh_chain.h" "" || die "generate Xcode resource paths"
t "xcodebuild (Release, unsigned, iPhone + iPad)"
mkdir -p "$O"
xcodebuild -project DmIOS.xcodeproj -scheme DmIOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DM_COPY_GAME_RESOURCES=NO \
  DM_XCODE_OUTPUT_ROOT="$DD" SYMROOT="$DD/Build/Products" OBJROOT="$DD/Build/Intermediates.noindex" build > "$O/build.log" 2>&1 \
  || { grep -E 'error:' "$O/build.log" | head -30; die "xcodebuild, log $O/build.log"; }
APP=$DD/Build/Products/Release-iphoneos/DmIOS.app
[ -d "$APP" ] || die "no built app"; t "app: $APP"
rm -rf "$APP/msl" "$O/Payload"; rm -f "$O/out.ipa"
# The Increased Memory Limit entitlement in the executable's ad-hoc signature, as in build_ipa.sh
ENT=$O/DmIOS.entitlements
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict><key>com.apple.developer.kernel.increased-memory-limit</key><true/></dict></plist>' > "$ENT" || die "entitlements"
EXE=$APP/DmIOS; [ ! -f "$APP/Info.plist" ] || EXE=$APP/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Info.plist") || die "CFBundleExecutable of $APP"
xattr -cr "$EXE" 2> /dev/null
codesign --force --sign - --entitlements "$ENT" "$EXE" || die "ad-hoc signature with the entitlements"
codesign -d --entitlements - "$EXE" > /dev/null 2>&1 || die "the executable's signature has no entitlements"
t "entitlements in the executable's ad-hoc signature"
P=Payload/DmIOS.app
MAPS=("$P/msl/$SILK/b-$V=$SILK_MSL/b-$V" "$P/msl/$HADES/b-$V=$HADES_MSL/b-$V" "$P=$APP")
STORE="$(gp $SILK zip_store),$(gp $HADES zip_store)"
python3 tools/pack_ipa.py "$OUT_IPA" --store "$STORE" --skip-suffix _bp.metallib \
  --skip $P/_CodeSignature --skip $P/embedded.mobileprovision --skip $P/msl --skip $P/aoc --skip $P/romfs --skip $P/romfs.img --skip $P/romfs.id "${MAPS[@]}" || die "pack_ipa"
t "done: $OUT_IPA ($(du -h "$OUT_IPA" | cut -f1))"
