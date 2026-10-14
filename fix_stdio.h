#pragma once

// Force-included into every generated translation unit (see CMakeLists.txt).
//
// This header used to also #define sprintf, _vsnprintf, _snprintf, vsprintf,
// swprintf, _vswprintf, RtlCaptureContext, RtlUnwind and RtlRaiseException to
// ht_* replacements. None of those ht_* symbols was ever defined anywhere in
// the tree. The renames were scaffolding for an older codegen revision that
// emitted bare CRT names; current codegen emits __imp__<name> instead, so the
// macros matched nothing in the generated sources - but they *did* apply to the
// standard headers included after them, which is a real hazard.
//
// They are gone. Do not reintroduce a rename here without a definition to go
// with it.
//
// What remains is only the platform prelude the generated sources expect.

#if defined(_WIN32)
// Verified vestigial as of this codegen revision: the generated sources name no
// Windows type (HANDLE/DWORD/HRESULT/WINAPI/...) and no bare CRT printf-family
// symbol, and each one includes nothing but hydrothunder_init.h. It is kept on
// Windows only because dropping it there changes nothing and proving a negative
// across 65 translation units is not worth a surprise.
//
// It must stay guarded: this header is -include'd into every generated TU, so
// an unconditional <windows.h> is 65 immediate hard errors on macOS and Linux.
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#endif  // _WIN32

#include <cstdio>
#include <cstring>
#include <cwchar>

//=============================================================================
// REX_WEAK_FUNC compatibility shim
//=============================================================================
//
// The committed generated/ tree was produced by codegen 0.8.1.19, whose
// DEFINE_REX_FUNC expands to:
//
//     __attribute__((alias("__imp__" #name))) REX_WEAK_FUNC(name);
//     REX_EXTERN(__imp__##name)
//
// so the recompiled body lands on __imp__sub_X and sub_X becomes a weak alias
// to it - which is what lets a hook replace sub_X while the original stays
// reachable.
//
// rexglue-sdk v0.10.0 split REX_FUNC/REX_EXTERN out of rex/ppc/context.h into
// rex/ppc/func.h and, in the process, DROPPED REX_WEAK_FUNC. The other two
// survived. Every generated translation unit therefore fails with
// "unknown type name 'REX_WEAK_FUNC'", 61 files over.
//
// This restores the v0.9.0 definition verbatim. It is defined here rather than
// in the SDK because this header is already -include'd into every generated TU
// (see CMakeLists.txt), which puts it ahead of the first DEFINE_REX_FUNC use.
//
// THE REAL FIX is to regenerate generated/ with the v0.10.0 codegen
// (`cmake --build <dir> --target generate-all`), which needs a converted
// default.xex present. Drop this shim once that is done - if v0.10.0's codegen
// still emits REX_WEAK_FUNC, the macro belongs upstream in rex/ppc/func.h
// instead, and is worth reporting as an oversight in the header split.
#if !defined(REX_WEAK_FUNC)
#include <rex/ppc/func.h>  // REX_FUNC, which this is defined in terms of
#define REX_WEAK_FUNC(x) __attribute__((weak, noinline)) REX_FUNC(x)
#endif

