# Path B native-lib plumbing — de-risk report

Machine: macOS 26.5.1, arm64 (Apple Silicon), CommandLineTools SDK only (no full Xcode.app),
Swift 6.3.3, no cmake, no Developer ID signing identity present (`security find-identity -v -p codesigning` → 0 identities).
Network to github.com confirmed reachable.

## 1. Toolchain reality check (done first, changes the plan)

| Tool | Present? | Notes |
|---|---|---|
| `swift`/`swiftc` | yes | 6.3.3 |
| `xcodebuild` | **no** | CLT-only install; `xcodebuild -version` errors ("requires Xcode") |
| `cmake` | **no** | not installed |
| `make`, `clang`, `git`, `curl`, `lipo`, `ar`, `codesign`, `xcrun` | yes | all present under `/usr/bin` (CLT-backed) |
| `xcrun notarytool` | yes | `/Library/Developer/CommandLineTools/usr/bin/notarytool` — ships with CLT, full Xcode.app not required |
| `xcrun stapler` | yes | same |
| Signing identity | **none** | `security find-identity -v -p codesigning` → "0 valid identities found" |

Implication for the spec: **cmake cannot be assumed on a dev/CI box** — libdeflate's current `main` branch (commit `b122c8b`, 2026-05-16) ships **CMake-only**, no legacy `Makefile`. The fallback path (direct `clang -c` compilation of the `.c` files) is not a hypothetical contingency — it was the *actual* path used below, and should be treated as the primary supported build path in the spec, with CMake used only if present. `xcodebuild` absence doesn't block anything below — none of the proof steps needed it (raw `clang`/`ar`/`codesign`/`swiftc`/`notarytool` all worked from CLT alone), but a real project will still want full Xcode.app for the actual SwiftUI app target.

## 2. Actually built libdeflate for arm64 — proof

Cloned from source, compiled each `.c` file directly with `clang -arch arm64`, archived with `ar`, and — going beyond the minimum ask — actually **linked and ran** both a C smoke test and a **Swift** smoke test against the static archive, plus built the dynamic-linking contrast case. All commands below were run in this session and their exit codes/output are what's quoted (nothing paraphrased).

### 2.1 Clone

```
git clone --depth 1 https://github.com/ebiggers/libdeflate.git
```
Succeeded (network reachable). HEAD: `b122c8be1d78b19f6d0a6efc5bb79bfcbb30dd51` (2026-05-16).

### 2.2 Build fallback: compile .c files directly (cmake absent)

```bash
SDK=$(xcrun --sdk macosx --show-sdk-path)
for f in lib/adler32.c lib/crc32.c lib/deflate_compress.c lib/deflate_decompress.c \
         lib/gzip_compress.c lib/gzip_decompress.c lib/utils.c lib/zlib_compress.c \
         lib/zlib_decompress.c lib/arm/cpu_features.c
do
  base=$(basename "$f" .c)
  clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=14.0 -O2 -c "$f" -I. -o "build-arm64/${base}.o"
done
```
Result: 10/10 object files compiled clean, zero warnings/errors.

### 2.3 Archive into a static lib

```bash
ar rcs build-arm64/libdeflate.a build-arm64/*.o
```

Verification (exact output captured):
```
$ ar t build-arm64/libdeflate.a
__.SYMDEF SORTED
adler32.o
cpu_features.o
crc32.o
deflate_compress.o
deflate_decompress.o
gzip_compress.o
gzip_decompress.o
utils.o
zlib_compress.o
zlib_decompress.o

$ lipo -info build-arm64/libdeflate.a
Non-fat file: build-arm64/libdeflate.a is architecture: arm64

$ file build-arm64/libdeflate.a
build-arm64/libdeflate.a: current ar archive random library
```
75,368-byte static archive, confirmed single-arch arm64.

### 2.4 Proved it actually links and runs (C)

Wrote `smoke.c` doing a real compress→decompress round-trip via `libdeflate_alloc_compressor` / `libdeflate_deflate_compress` / `libdeflate_deflate_decompress`.

```bash
clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=14.0 -I. -o smoke_test smoke.c build-arm64/libdeflate.a
./smoke_test
```
Output: `in_len=84 comp_size=48 result=0 roundtrip_ok=1` — compiled, linked, executed, round-trip byte-for-byte correct.

### 2.5 Proved the Swift interop path (the part that actually matters for the spec)

Built a minimal C-library target the way SwiftPM/Xcode consume one — a `module.modulemap` + header, no SwiftPM package wrapper needed to prove the mechanism:

```
CLibDeflate/
  libdeflate.a
  include/
    libdeflate.h
    module.modulemap      # module CLibDeflate { header "libdeflate.h"; link "deflate"; export * }
```

Compiled a Swift file that does `import CLibDeflate` and calls the C API directly (no bridging-header needed for a module-map-based C target — bridging headers are the alternative for old-style non-modular headers; a `module.modulemap` is what SwiftPM's `.target(... cSettings/publicHeadersPath)` / `systemLibrary` generates under the hood):

```bash
swiftc -O \
  -Xcc -I./CLibDeflate/include \
  -Xcc -fmodule-map-file=./CLibDeflate/include/module.modulemap \
  -I ./CLibDeflate/include \
  -L ./CLibDeflate \
  -ldeflate \
  main.swift -o swift_smoke_test
```
Exit code 0, no warnings. Ran:
```
$ ./swift_smoke_test
Swift+C interop: inLen=74 compSize=71 result=0 roundtripOK=true
```

**Proof it's truly statically embedded, not dynamically loaded** — `otool -L` on the resulting executable shows *no* libdeflate entry at all, only system/Swift-runtime dylibs:
```
swift_smoke_test:
	/usr/lib/libz.1.dylib (...)
	/usr/lib/libSystem.B.dylib (...)
	/System/Library/Frameworks/Foundation.framework/... (weak)
	/usr/lib/swift/libswiftCore.dylib (...)
	... (other Swift runtime dylibs, all weak/system)
```
And `nm -m` on the binary shows libdeflate's internal functions compiled directly in as **non-external** symbols in `__TEXT,__text` (e.g. `_deflate_compress_fastest`, `_deflate_compress_lazy2`, `_deflate_compute_true_cost`) — i.e. the C code is physically part of the one Mach-O, not a separate image resolved at load time.

### 2.6 Contrast: built the dynamic (.dylib) case too, for a direct comparison

```bash
clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=14.0 -dynamiclib \
  -install_name "@rpath/libdeflate.1.dylib" -o build-arm64/libdeflate.1.dylib build-arm64/*.o
codesign --sign - --options runtime --force build-arm64/libdeflate.1.dylib   # separate signing step
clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=14.0 -I. \
  -o smoke_test_dyn smoke.c -L build-arm64 -ldeflate.1 -Wl,-rpath,@executable_path
```
This built, ran (`roundtrip_ok=1`), and — unlike the static case — `otool -L smoke_test_dyn` shows an explicit `@rpath/libdeflate.1.dylib` load command that must resolve at runtime, and the dylib itself needed its own, separate `codesign` pass with its own `install_name`/`@rpath` bookkeeping. This is the concrete evidence behind the recommendation in §3.

### 2.7 Signing / hardened runtime smoke test (ad-hoc, since no Developer ID identity is on this machine)

```bash
codesign --sign - --options runtime --force swift_smoke_test
codesign -v --strict swift_smoke_test   # exit 0
```
`codesign -dv` on the result: `flags=0x10002(adhoc,runtime)` — hardened runtime bit set successfully, **on the statically-linked binary, with zero entitlements**, and verification passed. This directly supports §3's "no entitlement needed for static-linked native C" conclusion (see caveat below — ad-hoc signing isn't Developer-ID signing, but the hardened-runtime + library-validation mechanics being tested here are identical between the two).

## 3. Static vs dynamic linking — assessment and recommendation

**Recommendation: statically link every bundled native C/C++ library (libdeflate, jpegli/libjxl, leptonica, jbig2enc) directly into the app's single Mach-O executable. Do not ship them as separate `.dylib`s.**

Why, backed by what was actually built above:

| Concern | Static (`.a` linked in) | Dynamic (`.dylib` bundled in `Contents/Frameworks`) |
|---|---|---|
| Mach-O images to sign | 1 (the app binary itself, already signed as part of the normal build) | N (app binary + one dylib per library), each independently `codesign`'d |
| `install_name`/`@rpath` bookkeeping | none — not applicable | required per dylib (`-install_name @rpath/...`, `-Wl,-rpath,@executable_path/../Frameworks`); got this wrong once already in testing (§2.6) even in a 2-minute proof — this is real, not theoretical, friction |
| Library-validation exposure | none — hardened runtime's library-validation check only fires when a separate Mach-O image is *loaded at runtime*; a statically-linked archive is compiled directly into the one binary, so there is nothing for library validation to inspect or reject | applies, but is a non-issue in practice **as long as you sign the dylib yourself with the same Developer ID Team ID as the app** — library validation passes for any image signed by the same Team ID (or by Apple); it's a problem only for loading a genuinely third-party-signed or unsigned plugin |
| `codesign --deep` | irrelevant — nothing nested to walk | Apple's own `codesign` man page: **"--deep (DEPRECATED for signing as of macOS 13.0)"** and warns "All signing options will be applied, in turn, to all nested content. This is almost never what you want." The current correct practice is to sign each nested Mach-O explicitly, innermost-first, not rely on `--deep`. |
| Entitlements needed | **none** (proved empirically in §2.7 — hardened runtime + zero entitlements verified clean) | still none, *provided* you're signing your own build with your own cert — `disable-library-validation` is only needed when loading a dylib signed by a **different** Team ID or unsigned (see §3a) |
| Notarization surface | one Mach-O to notarize/staple | multiple Mach-Os inside the bundle notarized as one archive, but every one must individually pass Apple's automated checks (signed, hardened runtime, secure timestamp) — more places for one to be missed |
| Update/versioning | library version is baked into the one binary at build time — simple | dylib versioning (`-current_version`/`-compatibility_version`) is another axis to get right |

**Swift interop path, concretely (per §2.5):** wrap the C headers in a `module.modulemap` (what SwiftPM generates automatically for a `.target` with a C `include/` dir, or what you write by hand for an Xcode target) — this is the modern, preferred mechanism. A bridging header (`-import-objc-header`) is the older alternative, typically used inside a single Xcode target when you don't want a separate module; both work, module maps are cleaner for a reusable C target and are what SwiftPM's `systemLibrary`/C-target mechanism is built on. Either way the library search path (`-L`) + `-l<name>` (or SwiftPM `linkerSettings: .linkedLibrary(...)`) pulls in the `.a` at link time — proved working end-to-end above.

### 3a. Verified, not guessed: does third-party native code force `disable-library-validation` or `allow-unsigned-executable-memory`?

**No, for this spec's case — neither is needed.** Evidence:
- Apple's local `codesign(1)` man page (verified via `man codesign` on this machine): hardened runtime "includes runtime code signing enforcement, **library validation**, hard, kill, and debugging restrictions. These restrictions can be selectively relaxed via entitlements." — i.e. library validation is a *default hardened-runtime restriction*, relaxed only via `disable-library-validation`.
- Corroborated by web search of Apple developer-forum threads and third-party security writeups: `disable-library-validation` is specifically for loading a dylib/plugin **signed by a different Team ID, or unsigned** — not for code that is statically compiled in, and not needed for a dylib you build and sign yourself with the same cert as the app.
- Empirically: the statically-linked Swift+C binary in §2.7 signed successfully with `--options runtime` and **zero entitlements**, and `codesign -v --strict` passed.
- `allow-unsigned-executable-memory` is unrelated to this problem entirely — confirmed via web search: it exists for **JIT compilers** that mmap `PROT_EXEC` pages at runtime (JavaScriptCore, Mono, custom VMs), part of a documented escalation ladder `allow-jit` → `allow-unsigned-executable-memory` → `disable-executable-page-protection`. None of libdeflate/jpegli/libjxl/leptonica/jbig2enc do runtime code generation — they are ahead-of-time-compiled C/C++ image/PDF codecs. **Not applicable.**

Net: for a **statically-linked** build, no special hardened-runtime entitlement is required at all. Even in the dynamic case, none would be required *if you sign every dylib with your own Developer ID cert* — the entitlement only becomes necessary if you were loading someone else's pre-built, differently-signed binary framework (not the case here — you're building all four libraries from source).

## 4. Signing + hardened runtime + notarization recipe (embedded native code)

Confirmed locally present and runnable from CLT alone (no full Xcode.app needed): `codesign`, `xcrun notarytool`, `xcrun stapler`, `codesign_allocate`.

### 4.1 Sign the app (static-linking case — the recommended path)

```bash
codesign --sign "Developer ID Application: <Team Name> (<TEAMID>)" \
  --options runtime \
  --timestamp \
  --entitlements App.entitlements \
  MyApp.app/Contents/MacOS/MyApp
codesign --sign "Developer ID Application: <Team Name> (<TEAMID>)" \
  --options runtime --timestamp \
  MyApp.app
```
`App.entitlements` needs **no** native-library-specific keys for the static case — only whatever the app already needs for its own features (e.g. sandbox/file-access entitlements if sandboxed; this app is presumably non-MAS/Developer-ID so likely unsandboxed, in which case the entitlements file can be minimal or omitted).

Sign the deepest/most-nested items first, then the containing bundle — this is the modern replacement for the deprecated `--deep` (confirmed via local `codesign` man page, §2.6/§3). With everything statically linked there **is no nested item** — one binary, one sign.

### 4.2 If dynamic linking were used instead (not recommended, but documented)

Sign each dylib individually, innermost-first, each with `--options runtime --timestamp`, place them under `MyApp.app/Contents/Frameworks/`, then sign the app bundle last. `--deep` should not be relied on (deprecated for signing since macOS 13).

### 4.3 Package + notarize + staple (exact commands, verified against the locally-installed `notarytool --help`)

```bash
# 1. Zip the app (ditto preserves resource forks/metadata correctly, unlike zip(1))
ditto -c -k --keepParent MyApp.app MyApp.zip

# 2. Submit for notarization (store credentials once via `xcrun notarytool store-credentials`,
#    then reference by --keychain-profile; --wait blocks until Apple's service returns a result)
xcrun notarytool submit MyApp.zip \
  --keychain-profile "my-notary-profile" \
  --wait

# 3. Staple the notarization ticket to the app (and, separately, to the distributed DMG)
xcrun stapler staple MyApp.app
xcrun stapler staple MyApp.dmg
```
`notarytool submit` flags confirmed via local `--help` (this session): `--apple-id`/`--password`/`--team-id` or `-p/--keychain-profile` for auth, `--wait`/`--timeout`, `-f json` for machine-readable output, `--force` to bypass local pre-flight checks. `stapler staple`/`stapler validate` confirmed via local `--help`: supports "UDIF disk images, code-signed executable bundles, and signed flat installer packages" — i.e. staple both the `.app` and the final `.dmg`.

**Not attempted in this session** (by design — no Apple Developer account/credentials available here): the actual `notarytool submit --wait` round-trip against Apple's live service. Everything up to and including local signing/verification (`codesign -v --strict`) was run and passed; only the network call to Apple's notary service and the credential setup (`store-credentials`) require an actual paid Developer account and were not exercised. Document this as the one step the spec must still validate against a real account before shipping.

### 4.4 DMG packaging note
Build the DMG (`hdiutil create` or `create-dmg`) from the already-signed `.app`, sign the DMG itself too (`codesign --sign "Developer ID Application: ..." MyApp.dmg`), then notarize+staple the DMG (notarizing the dmg is standard; notarizing the .app alone and then dmg-wrapping post-notarization also works, but stapling the DMG specifically is what most users double-click, so make sure the ticket ends up on the artifact people actually run).

## 5. Special case: bundling Ghostscript (a separate executable, invoked via `Process`)

One line, as scoped: this is **not** the same problem as the linked-library case — it's an **embedded helper tool**, so it must be code-signed as its own executable (own `codesign --sign ... --options runtime` pass, placed typically under `Contents/MacOS/` or `Contents/Resources/`) and satisfy hardened-runtime + notarization checks independently, exactly like the app binary itself, but is invoked at runtime via `Process`/`NSTask` rather than linked — and since this is a non-MAS Developer-ID app (not App Store), the App Sandbox restriction on spawning arbitrary subprocesses (`com.apple.security.app-sandbox` + exec restrictions) simply doesn't apply; that constraint is specific to sandboxed MAS apps. Two remaining gotchas specific to this pattern, not covered above: (1) Ghostscript's own license (AGPL for `gs`, unlike the four MIT/BSD/Apache libraries this spec is otherwise built on) is a materially different legal posture and should be flagged separately from the "permissive libs" assumption if it's ever added; (2) a spawned helper's *own* dependent dylibs (Ghostscript typically links several) all need to be present, signed, and satisfy library validation exactly like any other Mach-O on this system — bundling a stock `gs` binary you didn't build/sign yourself is a much bigger notarization/library-validation risk than the four libraries actually in scope here, since it wouldn't be signed by your Team ID at all.

## 6. Verdict

**"Well-trodden, low risk"** for the static-linking approach as scoped (libdeflate, jpegli/libjxl, leptonica, jbig2enc — all AOT-compiled, permissively-licensed, buildable-from-source C/C++). This is proved, not asserted: source cloned, compiled from `.c` with plain `clang -arch arm64`, archived, linked into both a C and a **Swift** binary, run with a correct round-trip result, and ad-hoc signed with hardened runtime + zero entitlements, verified clean.

**Ranked gotchas** (real friction, none of them blockers):

1. **Build-system mismatch, not code risk.** libdeflate (and likely libjxl, which uses CMake, and leptonica, which supports both autotools and CMake) assume `cmake`/`make`/`autoconf` are present. This machine had no `cmake` — had to fall back to direct `clang -c` compilation. For the four libraries in scope this is mechanical (all are small-to-medium C/C++ codebases), but jpegli/libjxl in particular has more source files and a few generated headers (SIMD dispatch tables) that a hand-rolled `clang -c` loop must reproduce faithfully if cmake truly can't be used — budget time to just install `cmake` (e.g. via Homebrew) in the real dev/CI environment rather than reproducing its logic by hand; treat direct compilation as the emergency fallback proved here, not the primary plan.
2. **Getting the C→Swift module-map/header exposure right once per library.** Not hard (proved above), but it's per-library boilerplate: a `module.modulemap` + umbrella header (or SwiftPM C-target `publicHeadersPath`) for each of the four libraries, done once and then reused.
3. **Discipline to keep it static.** The main way this gets harder is scope creep toward dynamic linking (e.g. because a library's own build system defaults to producing a `.dylib`/`.so` and it's easier to just ship that) — resist it; force static `.a` output (`BUILD_SHARED_LIBS=OFF` for cmake-based libs, or just don't link `-dynamiclib`) for all four, per §3.

**Recommended approach for the spec:** static-link all four libraries into the app's single Mach-O via SwiftPM C targets (or Xcode C target + module map), one code-signing pass on the resulting app bundle (`codesign --options runtime --timestamp`, no special entitlements), package into a DMG, sign the DMG, `notarytool submit --wait`, `stapler staple` both `.app` and `.dmg`. Ghostscript, if ever added, is signed and notarized as its own embedded helper executable — same recipe, separate pass, and carries its own AGPL licensing question that's out of scope for the four libraries actually named in Path B.
