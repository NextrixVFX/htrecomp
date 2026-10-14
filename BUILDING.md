# Building on macOS and Linux

The README covers Windows. This covers the other two, which need the SDK at a
newer version and a few extra steps.

## Why the SDK version matters

`manifests/hydrothunder.toml.in` declares `sdk_version = "0.8.1.19"`, but
**macOS support only exists in rexglue-sdk from v0.10.0** — v0.8.0 and v0.9.0
have no mac CI job and almost no `APPLE` handling. So a mac build cannot use
the version this project was written against, and for consistency Linux is
built against the same v0.10.0.

That version jump is survivable, and it was checked rather than assumed:

- Every macro the generated code uses (`DEFINE_REX_FUNC`, `REX_LOAD_*`,
  `REX_STORE_*`, `REX_FUNC_PROLOGUE`, `REX_CALL_INDIRECT_FUNC`, …) is emitted
  into `generated/hydrothunder_init.h` itself, not pulled from the SDK, so the
  generated code is largely insulated from SDK API drift.
- Every SDK symbol it *does* reference resolves in v0.10.0: `PPCContext`,
  `PPCFunc`, `rex::PPCImageInfo`, `rex::chrono::Clock::QueryGuestTickCount`,
  `rex::runtime::MMIOHandler::global_handler`,
  `rex::runtime::ResolveIndirectFunction`,
  `rex::thread::global_critical_region::{AcquireDirect,mutex}`.
- All 14 `rex/*.h` headers `src/` includes still exist, and all 38 distinct
  `rex::` symbols it names still resolve.
- `rex/ppc/intrinsics.h` — the simde layer that makes the generated SSE
  intrinsics compile on ARM64 — differs by 14 bytes between v0.9.0 and v0.10.0.
- `sdk_version` is read and reported by codegen, never enforced, so the stale
  `0.8.1.19` in the manifest does not block anything.

### generated/ has been regenerated with the v0.10.0 codegen

**This is the fix that retires most of the workarounds below.** The tree now
ships output from the v0.10.0 codegen, not the 0.8.1.19 output it was committed
with. The previous tree is kept at `generated.0.8.1.19.bak/`.

Regenerate with:

```sh
cmake --build <build-dir> --target generate-all
```

It needs `game_data/default.xex` present (`HT_GAME_DATA_ROOT`, default
`./game_data`) and takes about 5 seconds. It does NOT need a converted
executable - codegen reads the encrypted, compressed one straight from the
package.

What changed: 247 files written, 120 translation units instead of 61, and the
units are now self-contained (`hydrothunder_funcs.N.h` -> `hydrothunder_pch.h`)
rather than everything hanging off `hydrothunder_init.h`.

Three problems disappeared with it:

**1. macOS could not compile at all.** Codegen 0.8.1.19 defined
`DEFINE_REX_FUNC` with `__attribute__((alias("__imp__" #name)))`, and Mach-O has
no symbol aliases - clang rejects them outright with `error: aliases are not
supported on darwin`, once per function. The v0.10.0 template has a Darwin
branch that emits a weak symbol whose body is a `[[clang::musttail]]` tail call
to `__imp__##name`: a single `jmp`, still weak so hooks can replace it, with
`__imp__##name` remaining the original entry point. Note it is a thunk, not an
alias, so `&name != &__imp__##name` by design.

**2. `REX_WEAK_FUNC` no longer exists and is no longer needed.** The v0.10.0
macro inlines `__attribute__((weak, noinline))` itself. The shim that used to
live in `fix_stdio.h` is gone.

**3. `fix_stdio.h` is dead.** It was force-included into every generated TU to
supply a platform prelude the old units expected. The new units need nothing
force-fed. The file is left in the tree but is no longer referenced by the
build; `CMakeLists.txt` now sets the SDK's own recompilation options instead
(`-fasync-exceptions` on Windows+Clang for guest SEH, plus the PCH on both the
sources and the target, mirroring `REXGLUE_RECOMP_OPTIONS` in
`resources/templates/init/rexglue_cmake.inja`).

The only compile-time drift fix still needed is the cvar rename:
`cache_path` became `cache_root` (`src/system/runtime.cpp:34`). Because
`REXCVAR_SET` pastes the name into an identifier, it surfaced as
`use of undeclared identifier 'FLAGS_cache_path_storage_'`. Fixed in
`src/ht_app_common.h`.

### A third break that compiles fine and fails at runtime

**The Xenos GPU became a runtime-loaded plugin after v0.8.0.** At v0.8.0 there
is no `src/system/gpu_plugin_loader.cpp` and no `GPU_PLUGINS` argument in
`rexglue_helpers.cmake`; both appear in v0.9.0. The GPU emulation moved out of
`rexruntime` into `rexgpu-xenos.dll` / `librexgpu-xenos.so` / `.dylib`, which
`rexruntime` resolves with `LoadLibrary` from the executable's own folder.

`CMakeLists.txt` called `rexglue_configure_target(hydrothunder)` with no
`GPU_PLUGINS`, which was correct for v0.8.0 and silently wrong from v0.9.0 on.
Because the plugin is not a link dependency of `hydrothunder`, it is neither
built nor staged - the build succeeds, and the game dies at startup with:

```
GPU plugin 'xenos' not found at <exe dir>/rexgpu-xenos.dll. Stage it next to
the executable (GPU_PLUGINS xenos in rexglue_configure_target).
```

Now `rexglue_configure_target(hydrothunder GPU_PLUGINS xenos)`, which adds the
build dependency, stages the plugin beside the executable on every link, and on
`APPLE` also stages the macOS Vulkan runtime (`libvulkan`, `libMoltenVK`) the
Vulkan backend loads at runtime.

Note the per-config filename postfix (`gpu_plugin_loader.cpp:31-39`): a
RelWithDebInfo build looks for `rexgpu-xenosrd.dll`, Debug for
`rexgpu-xenosd.dll`. Mixing configs between host and plugin will not resolve.

### Three more breaks found by actually running it

Compiling cleanly was not enough; all three of these produce a build that
starts and then does nothing useful.

**1. `GetExecutablePath()` fastfails from inside a DLL with a static CRT.**
`src/core/filesystem_win.cpp` used `_get_wpgmptr`, but `_wpgmptr` is a
per-CRT-instance global that only the EXECUTABLE's CRT startup populates. Since
`rexruntime` is a SHARED library, linking the static CRT gives it a private CRT
instance where that pointer was never initialised; `_get_wpgmptr` then hands a
null to the invalid-parameter handler, which calls `__fastfail` and kills the
process with `STATUS_STACK_BUFFER_OVERRUN` (0xC0000409). `__fastfail` bypasses
SEH, so the project's own unhandled-exception filter never runs and no
`crash_dump.txt` appears - the process just vanishes two seconds in, with
`startup_debug.txt` ending at "Entered SetupEnvironment".

Fixed in the SDK to use `GetModuleFileNameW(nullptr, ...)`, which is correct
regardless of CRT linkage or calling module. Confirmed with a minimal
static-CRT DLL repro before changing anything. Upstreamable.

**2. The GPU plugin is staged but never selected.** `gpu_plugin` (defined in
the SDK's `src/ui/rex_app.cpp`) defaults to EMPTY, and empty means "no GPU
emulation", not "use the only plugin present". The game boots, runs the guest,
burns ~80% of a core and renders a **black window**, with only three warnings
to show for it:

```
VdSetGraphicsInterruptCallback:  no GPU emulation loaded (gpu_plugin not set)
VdInitializeRingBuffer:          no GPU emulation loaded (gpu_plugin not set)
VdEnableRingBufferRPtrWriteBack: no GPU emulation loaded (gpu_plugin not set)
```

Set in `src/main.cpp`'s `OnPreSetup` via `RuntimeConfig::gpu_plugin` rather than
the cvar, because the cvar is never declared in a public SDK header. The
ordering in `ReXApp::SetupPresentation` allows this: cvar read into the config
(`:309`), then `OnPreSetup` (`:314`), then the plugin loads (`:316`).

**3. The static MSVC runtime is incompatible with this architecture.**
`HTRECOMP_STATIC_MSVC_RUNTIME` defaults ON (`CMakeLists.txt:7-11`) and is set
before `add_subdirectory`, so the executable, `rexruntime.dll` and
`rexgpu-xenos.dll` each got a private CRT - separate heaps, separate STL state.
With the GPU plugin finally loading, the next fastfail landed in
`InitializeShaderStorage`, which passes `std::filesystem::path` across the
module boundary and spawns threads.

**Configure with `-DHTRECOMP_STATIC_MSVC_RUNTIME=OFF`.** A DLL-based runtime
needs one shared CRT. The cost is a dependency on `MSVCP140.dll` /
`VCRUNTIME140.dll`, so a distributable build must ship the VC++ redistributable
or those DLLs. Fix 1 is still worth keeping - a DLL should never read
`_wpgmptr` - but it is not sufficient on its own.

With all three applied the game boots to an in-race attract demo at 1920x1080,
holding ~38% of one core and ~807 MB, and shuts down cleanly.

### The runnable artifact set

A host binary alone is not enough. Next to the executable you need:

| File | Where it comes from |
|---|---|
| `hydrothunder` (+`.exe`) | this project |
| `rexruntime` (`.dll`/`.so`/`.dylib`) | staged by `ht_stage_runtime_library` |
| `rexgpu-xenos` plugin | staged by `GPU_PLUGINS xenos` (above) |
| `libvulkan`, `libMoltenVK` | macOS only, staged by the same call |

`ninja hydrothunder` builds the host and its link dependencies. The plugin is
pulled in by the `add_dependencies` that `GPU_PLUGINS` adds, so it now comes
along - but `ninja all` is the safer habit.

### Still unverified

The non-volatile register save buffer grew from 1600 to 1616 bytes in v0.10.0
(cr2-cr4 and fpscr were added to the layout). Nothing in `generated/`
hardcodes that size, but this project does set `setjmp_address` in
`config/hydrothunder_overrides.toml`, so if it builds and then dies on a
`longjmp`, start there. This is a runtime concern, not a compile one.

## Why not just use the prebuilt SDK?

The SDK publishes prebuilt zips for all five platforms on each release
(`rexglue-sdk-0.10.0-{win-amd64,linux-amd64,linux-arm64,mac-amd64,mac-arm64}.zip`,
43-116 MB), and they are a real CMake package: `find_package(rexglue CONFIG)`
hands you `rex::runtime`, `rex::rexglue` (the codegen tool), the ImGui headers,
and on macOS even prebuilt `libMoltenVK.dylib` and `libvulkan.1.dylib` as
imported targets. That would skip the 696 MB recursive clone, the MoltenVK
`fetchDependencies` step and the symlink problem all at once.

**It will not work for this project, because of the patches.**

`SDK_PATCHES.md` documents changes made *inside* the SDK source tree, and the
files they touch are compiled into libraries that ship prebuilt:

| Patch | File | Library | Installed? |
|---|---|---|---|
| 2 - ImGui `CmdLists.Size` | `src/ui/imgui_drawer.cpp` | `rexui` -> linked into `rexruntime` | yes, prebuilt |
| 1 - additive depth test | `src/graphics/vulkan/pipeline_cache.cpp` | `rexgpu-xenos` | yes, prebuilt |

You cannot patch a compiled binary. Using the prebuilt SDK means shipping the
unfixed `imgui_drawer`, which makes **every overlay invisible** - F3, F4, F5,
F6 and the console all come up empty, including this project's own settings
panel, with no error to explain it. That is the whole reason the SDK is
vendored as source here rather than consumed as a package.

Switching would also mean rewriting the build: `CMakeLists.txt:60` does
`add_subdirectory(third_party/rexglue-sdk)` and line 93 reaches into
`${REXSDK_DIR}/thirdparty/imgui`, a source path. Both are fixable - the install
does ship the ImGui headers - but it is pointless while the patches are needed.

The prebuilt zips are still useful for two things: confirming what a given
release actually contains, and as a source of a prebuilt `libMoltenVK.dylib`
if `fetchDependencies` gives trouble on macOS.

## Setup

```sh
# --- macOS ---------------------------------------------------------------
# Xcode 16+ is required: the SDK hard-fails below AppleClang 16 (C++23).
xcode-select --install
brew install cmake ninja molten-vk vulkan-loader python git git-lfs

# --- Linux (Debian/Ubuntu) ----------------------------------------------
# The SDK requires Clang; its own CI pins clang-20.
sudo apt install clang-20 lld-20 cmake ninja-build python3 git git-lfs \
  libvulkan-dev libgtk-3-dev libx11-xcb-dev libxss-dev \
  libwayland-dev libwayland-bin wayland-protocols libxkbcommon-dev \
  libdecor-0-dev libasound2-dev libpulse-dev libpipewire-0.3-dev
```

Then, on either platform:

```sh
git clone --recursive --depth 1 -b v0.10.0 --shallow-submodules \
  https://github.com/rexglue/rexglue-sdk third_party/rexglue-sdk

cd third_party/rexglue-sdk
git apply ../../patches/0001-imgui-iterate-cmdlists-size.patch
cd ../..
```

Two extra steps that are easy to miss:

```sh
# macOS only: MoltenVK's dependencies are NOT git submodules, so --recursive
# does not fetch them, and nothing in the build does it for you.
cd third_party/rexglue-sdk/thirdparty/moltenvk && ./fetchDependencies --macos && cd -

# Only needed if the tree was cloned on, or copied from, Windows.
python3 tools/fix_symlink_checkout.py   # 'python' is not on PATH on macOS
```

### `xcodebuild` must point at Xcode, not the Command Line Tools

MoltenVK's `fetchDependencies` shells out to `xcodebuild`, which fails if the
active developer directory is a Command Line Tools install:

```
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer
directory '/Library/Developer/CommandLineTools' is a command line tools instance
```

This usually does NOT mean Xcode is missing - only that `xcode-select` points
elsewhere. Check and switch:

```sh
xcode-select -p                                                  # what is active
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept                                  # if never run
xcodebuild -version                                              # confirm
```

If Xcode genuinely is not installed, you can sidestep MoltenVK's build instead
by taking `libMoltenVK.dylib` from the prebuilt `rexglue-sdk-0.10.0-mac-arm64`
release asset, or from `brew install molten-vk`. Switching `xcode-select` is
the better path when Xcode is available, since it builds the revision the SDK
pins.

### MoltenVK's `External/` dependencies

On `APPLE` the SDK does `add_subdirectory(moltenvk)` and builds MoltenVK from
source (`thirdparty/CMakeLists.txt:218`). MoltenVK fetches SPIRV-Cross and
Vulkan-Headers with its own `fetchDependencies` script rather than git
submodules, so `git clone --recursive` leaves `External/` empty and several
include paths inside MoltenVK dangling. Nothing in the CMake runs it for you.

`brew install molten-vk` does not substitute for this: the build compiles the
pinned revision rather than linking the brew one. The brew package is still
wanted at runtime for the ICD.

### Symlinks, if the tree ever touched Windows

Three submodules track symlinks: `libmspack` (15), `moltenvk` (10) and
`o1heap` (1). Git on Windows only creates real symlinks with
`core.symlinks=true`, which needs Developer Mode or an elevated shell;
otherwise each one is checked out as a small text file containing the link
target path. `libmspack/cabextract/mspack/lzxd.c` is used on **every**
platform for XEX LZX decompression, so the build dies with:

```
libmspack/cabextract/mspack/lzxd.c:1:1: error: expected identifier or '('
    1 | ../../libmspack/mspack/lzxd.c
```

`tools/fix_symlink_checkout.py` replaces each placeholder with a real copy,
which works on every platform and survives being zipped or copied between
machines - unlike a real symlink. It is idempotent and skips entries that are
already real symlinks, so it is harmless on a native macOS or Linux clone.
`--check` reports without writing.

This matters most if you clone on Windows and copy the folder to a Mac: the
placeholders travel with it. Cloning fresh on the target platform avoids it.

Seven of the `moltenvk` placeholders point into `External/` and cannot be
resolved until `fetchDependencies` has run; the script reports them and skips
them. Run `fetchDependencies` first on macOS, then the script.


**Do not skip the patch.** Without it every overlay renders nothing — F3, F4,
F5, F6 and the console all come up empty, with no error to explain it. See
`SDK_PATCHES.md`.

## Build

```sh
# macOS (arm64)
cmake --preset mac-relwithdebinfo
cmake --build --preset mac-relwithdebinfo

# Linux
cmake --preset linux-relwithdebinfo
cmake --build --preset linux-relwithdebinfo
```

Both build presets pin `jobs: 3`. That is deliberate and the README explains
why: each generated translation unit can take 1–2 GB in the compiler, and there
are 61 of them, so an unbounded `--parallel` exhausts a 16 GB machine. Raise it
to 4 only with 24 GB or more. On a fanless Mac expect thermal throttling across
a build this size.

If the distro's default Clang is too old:

```sh
cmake --preset linux-relwithdebinfo \
  -DCMAKE_C_COMPILER=clang-20 -DCMAKE_CXX_COMPILER=clang++-20
```

Both presets select the Vulkan backend explicitly. D3D12 is Windows-only, and
`APPLE`/`UNIX` already force that choice in the SDK, but a stale cache with
both backends off trips a `FATAL_ERROR` — hence being explicit.

## The xextool conversion appears to be obsolete on v0.10.0

`src/ht_setup.cpp` refuses to start unless `default.xex` has `encryption == 0`
and `compression != 2`, and the README states that an unconverted executable
"would reach the title screen and then close as soon as you press Start".

**That was not reproducible on SDK v0.10.0.** With `HT_SKIP_XEX_CHECK=1` and a
straight-from-the-package `default.xex` (`encryption=1 compression=2`), the game
boots, reaches the menus, and plays. This is consistent with the SDK handling it
itself: `src/system/xex_module.cpp` dispatches on `compression_type` in
`ReadImage`, and `ReadImageCompressed` does the AES decrypt and LZX decompress
at load time. `xextool` is a Win32 binary and `FindXexTool`/`RunXexTool` are
stubbed off Windows, so this is the difference between "macOS needs a Windows
machine first" and "macOS just works".

Caveat: this is one session's evidence, not an audit. The check was presumably
added against a real symptom on an older SDK. Treat `HT_SKIP_XEX_CHECK=1` as
the known-good path on v0.10.0, and if something misbehaves deep in a race,
converting the executable is still the first thing to rule out.

## Running: what you need

```sh
# 1. unpack the package (any platform; needs no file dialog)
cmake --build <build-dir> --target ht_import
./ht_import <your-package-file> <build-dir>/game_data

# 2. run
HT_SKIP_XEX_CHECK=1 ./hydrothunder
```

`ht_import` (tools/ht_import.cpp) exists because `src/ht_setup.cpp`'s first-run
wizard calls `PickFile()`/`AskYesNo()`, both stubbed to `return false` outside
`_WIN32` - so on macOS and Linux there is otherwise no way to import at all. It
uses the same SDK STFS device the wizard does, and prints the executable's
encryption/compression verdict when it finishes.

The package is the file whose name is a long string of hex characters with no
extension, around 460 MB for the base game. It is NOT a `default.xex`; the real
`default.xex` lives inside it. `ht_import` says so plainly if you point it at
the wrong thing.

Verify you have the right package before unpacking - the STFS header carries
the title id at offset 0x360, which must read `5841096A`, matching `kTitleId`
in `src/ht_setup.cpp`.

## Known gaps on macOS and Linux

| Gap | Where | Effect |
|---|---|---|
| Additive-draw depth test | SDK patch 1, ported to Vulkan but **never run** | Should fix point lights drawing through terrain and through your boat. Compiles clean; correctness unverified. `force_additive_depth_test = false` disables it without a rebuild. See `SDK_PATCHES.md`. |
| First-run setup wizard | `src/ht_setup.cpp:78-81` | No file picker or prompts - use `ht_import` instead. |
| xex conversion | `src/ht_setup.cpp:358-360` | Appears unnecessary on v0.10.0; use `HT_SKIP_XEX_CHECK=1`. |
| `timeBeginPeriod(1)` audio pacing fix | `src/main.cpp`, Windows-only | The guest vblank thread paces with 1 ms sleeps. macOS and Linux do not have Windows' ~15.6 ms default granularity, so this is probably moot — but it is where to look if audio stutters. |
| Crash reporter | `src/main.cpp`, Windows-only | No `crash_dump.txt`; use `lldb`/`gdb`. A POSIX `sigaction` handler would restore it. |

## What was changed to make this build at all

- **`fix_stdio.h`** — included `<windows.h>` unconditionally while being
  `-include`'d into all 61 generated translation units, which is 61 immediate
  hard errors off Windows. Now guarded. Verified safe: the generated sources
  name no Windows type and no bare CRT printf-family symbol, and each one
  includes nothing but `hydrothunder_init.h`.
- **`CMakePresets.json`** - added `mac-*` and `linux-*` presets.
- **`fix_stdio.h`** - also restores `REX_WEAK_FUNC`, deleted in v0.10.0 (see
  above). Remove once `generated/` is regenerated.
- **`src/ht_app_common.h`** - `cache_path` cvar renamed to `cache_root`.
- **SDK, applied in tree** - patch 1 ported to the Vulkan backend across
  `include/rex/graphics/flags.h`, `src/graphics/flags.cpp` and
  `src/graphics/vulkan/pipeline_cache.cpp`.
- **`tools/fix_symlink_checkout.py`** - new; materialises Windows symlink
  placeholders.
- **`src/ht_settings_overlay.cpp`** — the panel listed five `d3d12_*` cvars
  that do not exist in a Vulkan build, which rendered as "unavailable" rows.
  Those are now `optional`, and the two with real Vulkan counterparts
  (`vulkan_allow_present_mode_immediate`, `vulkan_sparse_shared_memory`) were
  added alongside, also `optional`, so each row appears only on the backend
  that has it. `optional` was plumbed through `E()`/`DrawEnumSetting`, which
  previously only `S()`/`DrawSetting` supported.
- **`src/ht_settings_overlay.cpp`** — "Open backup folder" was a silent no-op
  off Windows; now uses `open` on macOS and `xdg-open` elsewhere.

## What has actually been compiled

Everything here was built on Windows with Clang 19.1.5. Two full builds passed:

1. `-DREXGLUE_USE_VULKAN=ON -DREXGLUE_USE_D3D12=ON`
2. **`-DREXGLUE_USE_VULKAN=ON -DREXGLUE_USE_D3D12=OFF`, from a wiped build
   directory** - the exact backend configuration macOS and Linux use, since
   `APPLE`/`UNIX` force D3D12 off. 732/732 targets, zero errors.

So the Vulkan backend was really compiled, not just inspected. Covered:

- the full `rexruntime` shared library, including all four SDK changes
- `src/graphics/vulkan/pipeline_cache.cpp` with the ported depth-test fix
- all 61 generated translation units, with the `REX_WEAK_FUNC` shim
- the project's own four sources
- a linked `hydrothunder` executable (40 MB)

**Not verified:** the `GPU_PLUGINS xenos` fix. It was found by inspection after
the toolchain was removed (VS 2022 uninstalled, taking Clang 19 with it), so it
has never been through a configure. The logic is a direct read of
`rexglue_helpers.cmake:147-167` and the two builds above predate it - meaning
**those builds produced no `rexgpu-xenos` plugin and would not have run.**

**Not verified:** macOS and Linux themselves. No cross-toolchain was available,
so the platform-gated paths - the guarded `<windows.h>` prelude, the
`__APPLE__`/`xdg-open` branches, MoltenVK, and the Vulkan code actually running
on a device - have never been through a compiler for those targets. A Windows
build exercises everything else.

### Windows toolchain note

The builds recorded above used Clang 19.1.5 and MSVC 14.44, both from
VS 2022. That combination is gone: VS 2022 was uninstalled, leaving VS 18
(MSVC 14.51) and no Clang at all. MSVC 14.51's STL hard-rejects anything below
Clang 20:

```
yvals_core.h:917: error STL1000: Unexpected compiler version, expected Clang 20 or newer.
```

So a Windows build now needs Clang 20+ installed separately - either VS 18's
"C++ Clang tools for Windows" component, or standalone LLVM:

```powershell
winget install LLVM.LLVM     # or: choco install llvm
```

Then point CMake at it explicitly, since the SDK requires Clang and will
otherwise pick up whatever is first on PATH:

```sh
cmake --preset relwithdebinfo \
  -DCMAKE_C_COMPILER="C:/Program Files/LLVM/bin/clang.exe" \
  -DCMAKE_CXX_COMPILER="C:/Program Files/LLVM/bin/clang++.exe"
```

Clang 20+ with MSVC 14.51 is a matched pair, so no `VCToolsInstallDir` pinning
is needed - that workaround only existed to force the older toolset while both
VS installs were present. None of this applies to macOS or Linux.
