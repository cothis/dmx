#!/usr/bin/env python3
"""Build the guest's FEX-Emu x86 emulator (static PIE, musl) inside a dmx VM.

Inputs, all pinned by sha256:
  - the GitHub source archive of a FEX release commit and of the submodules its build uses,
  - the Alpine toolchain packages in TOOLCHAIN (clang, lld), installed offline in the build VM.

Only the `FEX` program is built (FEXInterpreter): no FEXServer, FEXConfig, thunks or tests.
FEX_PATCH makes it run where containers put it, as a binfmt_misc interpreter opened by the
kernel (flag F), with no FEXServer and no other file of its own; makes it ignore the caller's
configuration when the kernel marks the exec privileged (AT_SECURE: a setuid x86 program, which
binfmt's C flag runs with the file's credentials) and read its config, data and cache directories
from the system-wide path rather than the caller's $HOME; reserves the address space above 2^47 by
probing for it where /proc/self/maps cannot be read; caps a translated block at 150 x86
instructions rather than 5000, which is what made node start slowly; makes the vsyscall page a
32-bit program enters the kernel through executable, which it is not without the VDSO thunks; and
fixes four places that relied on glibc behaviour musl does not have. Output: <cache>/<guest.DMX_FEX>, a stripped
static PIE. `make guest` puts it in docker.img.

`--lock` re-resolves TOOLCHAIN from Alpine's current APKINDEX and prints new pins.
"""

import argparse
import hashlib
import importlib.util
import io
import os
import struct
import subprocess
import sys
import tarfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True  # importing the other build scripts must not leave __pycache__ in scripts/
_spec = importlib.util.spec_from_file_location("build_kernel", ROOT / "scripts" / "build-kernel.py")
kernel = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(kernel)
guest = kernel.guest

VERSION = "FEX-2610"
COMMIT = "14c92681f4d62cf84d901460e0358de09c8847a7"
# The release's source and the submodules the FEX target needs, at the commits the release
# names (External/fmt etc. in its git tree). The others are for tests, thunks and tools.
SOURCES = {
    ".": ("FEX-Emu/FEX", COMMIT, "76bb2fb0c1bed5713828c33fc79a82efdc06b20bd8267212b438bb60fa149713"),
    "External/fmt": ("fmtlib/fmt", "c07e2aa4b130b4fd359a1c6455a5201b17af01fa", "e0099a9035521b29523915fae2e5f1b38229df896191e4a046f7b0d55a45c7d2"),
    "External/xxhash": ("Cyan4973/xxHash", "e626a72bc2321cd320e953a0ccf1584cad60f363", "34e71c085636fbc1726482996d92719d0a16e6a6097970ecf2990a27b3821162"),
    "External/range-v3": ("ericniebler/range-v3", "ca1388fb9da8e69314dda222dc7b139ca84e092f", "57a6fca5d60a85b84e8efecc62f0ca064e6b1f89b97b513284fe7f5bd43d49eb"),
    "External/unordered_dense": ("martinus/unordered_dense", "3234af2c03549bc85656bfd3a86993bf1cd8aef1", "aa68d77ef88475db710bf647017f5ccb13ceec6f55f3defa37e995b043eb990b"),
    "External/rpmalloc": ("FEX-Emu/rpmalloc", "09142d726429416bfa7b459151515fe3ab7622dd", "3250fcc53532ed6161642b77f6179c7ba73173fb2130314aa7f019a574266ff6"),
    "External/drm-headers": ("FEX-Emu/drm-headers", "3e49836995c1dcb3df709440ad2f270b569c6a5f", "3d3653841f81ea5be1a15cd4b458f048c1fffbcd97fcc808454a7fbe7cf1a555"),
    "Source/Common/cpp-optparse": ("Sonicadvance1/cpp-optparse", "9f94388a339fcbb0bc95c17768eb786c85988f6e", "68e6b500890270517d226abbc3610135de1600ddde29f44c9b68cca5e2a17f60"),
}


def source_url(repo: str, commit: str) -> str:
    return f"https://github.com/{repo}/archive/{commit}.tar.gz"


FEX_PATCH = r"""--- a/FEXCore/Source/Utils/FileUtils.cpp
+++ b/FEXCore/Source/Utils/FileUtils.cpp
@@ -58,7 +58,7 @@ static bool RecursiveRemoveDirectory(int parent_fd, const char* Directory) {
   }

   while (true) {
-    ssize_t read = getdents64(dir_fd, dirent_buffer, dirent_size);
+    ssize_t read = getdents64(dir_fd, reinterpret_cast<struct dirent*>(dirent_buffer), dirent_size);

     if (read == -1) {
       if (errno == EINVAL) {
@@ -151,7 +151,7 @@ FEX_DEFAULT_VISIBILITY void WalkDirectory(std::string_view Directory,
   }

   while (true) {
-    ssize_t read = getdents64(dir_fd, dirent_buffer, dirent_size);
+    ssize_t read = getdents64(dir_fd, reinterpret_cast<struct dirent*>(dirent_buffer), dirent_size);

     if (read == -1) {
       if (errno == EINVAL) {
--- a/FEXCore/include/FEXCore/Utils/SignalScopeGuards.h
+++ b/FEXCore/include/FEXCore/Utils/SignalScopeGuards.h
@@ -98,8 +98,14 @@ public:

   // Asserts that the rwlock isn't exclusively owned by the calling thread.
   void check_lock_owned_by_self_as_write() {
+#ifdef __GLIBC__
     const auto Result = pthread_rwlock_wrlock(&Mutex);
     LOGMAN_THROW_A_FMT(Result == EDEADLK, "User of rwlock must have already locked mutex as write!");
+#else
+    // dmx: musl does not detect a thread write-locking an rwlock it holds (glibc returns
+    // EDEADLK); it waits forever. Only check that the lock is held.
+    LOGMAN_THROW_A_FMT(pthread_rwlock_trywrlock(&Mutex) == EBUSY, "User of rwlock must have already locked mutex as write!");
+#endif
   }

   // Initialize the internal pthread object to its default initializer state.
--- a/Source/Common/FEXServerClient.cpp
+++ b/Source/Common/FEXServerClient.cpp
@@ -236,6 +236,12 @@ int ConnectToServer(ConnectionOption ConnectionOption) {
 }

 bool SetupClient(std::string_view InterpreterPath) {
+  /*
+   * dmx: x86 programs run in containers, which neither contain FEXServer nor reach one
+   * through their own network namespace. Run without it: the program's own / is the
+   * x86 root file system, and there is no log server or code cache.
+   */
+  return true;
   ServerFD = FEXServerClient::ConnectToAndStartServer(InterpreterPath);
   if (ServerFD == -1) {
     return false;
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/Utils/Threads.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/Utils/Threads.cpp
@@ -215,7 +215,13 @@ namespace PThreads {
       // The cause of this race condition is from glibc associating a DTV/TLS region with a stack region until the kernel clears the
       // `set_tid_address` address construct. If the stack is reused before the address is set to zero, then glibc won't initialize the new thread's
       // DTV/TLS region, resulting in TLS usage crashing.
+#ifdef __GLIBC__
       pthread_attr_setstacksize(&Attr, PTHREAD_STACK_MIN);
+#else
+      // dmx: musl's PTHREAD_STACK_MIN is 2 KB (glibc's is 128 KB on arm64), too little for
+      // the frames that run before the stack pivot.
+      pthread_attr_setstacksize(&Attr, 128 * 1024);
+#endif
       uint64_t OldMask;
       bool BlockingSignals = Flags.Internal;
       if (BlockingSignals) {
@@ -251,6 +257,12 @@ namespace PThreads {
     }

     bool detach() override {
+      // dmx: an exiting thread is detached here and again in HandleThreadDeletion. Detaching
+      // twice is undefined; glibc returns EINVAL, musl crashes.
+      if (Detached) {
+        return true;
+      }
+      Detached = true;
       return pthread_detach(Thread) == 0;
     }

@@ -306,6 +318,7 @@ namespace PThreads {
     void* UserArg;
     void* Stack {};
     FEXCore::Threads::Flags Flags {};
+    bool Detached {};

     // Use FEXCore's UncheckedLongJump to avoid fortification checks.
     // This avoids a false positive since glibc does not understand stack pivots.
--- a/Source/Common/Config.cpp
+++ b/Source/Common/Config.cpp
@@ -19,6 +19,7 @@
 #ifndef _WIN32
 #include <linux/limits.h>
 #include <pwd.h>
+#include <sys/auxv.h>
 #endif
 #include <optional>
 #include <utility>
@@ -484,20 +485,35 @@
 
 void LoadConfig(fextl::string ProgramName, char** const envp, const PortableInformation& PortableInfo) {
   const bool IsPortable = PortableInfo.IsPortable;
+  // dmx: for a setuid or file-capability x86 program the kernel sets AT_SECURE, and the caller
+  // is not the owner of the credentials FEX now runs with. Take the configuration from the
+  // built-in defaults and the system-wide files only: every other layer is a path the caller
+  // picks ($HOME, $SteamAppId, FEX_APP_CONFIG, the FEX_* variables themselves), and the
+  // configuration chooses the rootfs libraries are loaded from. FEXInterpreter has already
+  // dropped the FEX_* variables for this case.
+#ifndef _WIN32
+  const bool Secure = getauxval(AT_SECURE) != 0;
+#else
+  const bool Secure = false;
+#endif
   FEX::Config::InitializeConfigs(PortableInfo);
   FEXCore::Config::Initialize();
   if (!IsPortable) {
     FEXCore::Config::AddLayer(CreateGlobalMainLayer());
   }
-  FEXCore::Config::AddLayer(CreateMainLayer(nullptr, ProgramName.empty() ? std::nullopt : std::optional {ProgramName}));
+  if (!Secure) {
+    FEXCore::Config::AddLayer(CreateMainLayer(nullptr, ProgramName.empty() ? std::nullopt : std::optional {ProgramName}));
+  }
 
   if (!ProgramName.empty()) {
     if (!IsPortable) {
       FEXCore::Config::AddLayer(CreateAppLayer(ProgramName, FEXCore::Config::LayerType::LAYER_GLOBAL_APP));
     }
-    FEXCore::Config::AddLayer(CreateAppLayer(ProgramName, FEXCore::Config::LayerType::LAYER_LOCAL_APP));
+    if (!Secure) {
+      FEXCore::Config::AddLayer(CreateAppLayer(ProgramName, FEXCore::Config::LayerType::LAYER_LOCAL_APP));
+    }
 
-    auto SteamID = getenv("SteamAppId");
+    auto SteamID = Secure ? nullptr : getenv("SteamAppId");
     if (SteamID) {
       // If a SteamID exists then let's search for Steam application configs as well.
       // We want to key off both the SteamAppId number /and/ the executable since we may not want to thunk all binaries.
@@ -509,7 +525,7 @@
     }
   }
 
-  const char* AppConfig = getenv("FEX_APP_CONFIG");
+  const char* AppConfig = Secure ? nullptr : getenv("FEX_APP_CONFIG");
   if (AppConfig) {
     fextl::string AppConfigStr = AppConfig;
     if (IsPortable && FHU::Filesystem::IsRelative(AppConfig)) {
@@ -521,7 +537,9 @@
     }
   }
 
-  FEXCore::Config::AddLayer(CreateEnvironmentLayer(envp));
+  if (!Secure) {
+    FEXCore::Config::AddLayer(CreateEnvironmentLayer(envp));
+  }
   FEXCore::Config::Load();
 }
 
@@ -620,7 +638,26 @@
 }
 #endif
 
+/*
+ * dmx: for a setuid or file-capability x86 program the kernel sets AT_SECURE, and $HOME, the XDG
+ * variables and the FEX_* overrides below all come from a caller who is not the owner of the
+ * credentials FEX now runs with. LoadConfig already drops the configuration layers that use them,
+ * but these three functions have other callers (the thunk database in LinuxEmulation's
+ * FileManager, the code cache, the profiler), so make them answer with the system-wide directory
+ * instead and keep every consumer out of the caller's home.
+ */
+static bool SecureExec() {
+#ifndef _WIN32
+  return getauxval(AT_SECURE) != 0;
+#else
+  return false;
+#endif
+}
+
 fextl::string GetDataDirectory(bool Global, const PortableInformation& PortableInfo) {
+  if (SecureExec()) {
+    return GLOBAL_DATA_DIRECTORY;
+  }
 #ifdef FEX_STEAM_SUPPORT
   const char* SteamDataPath = getenv("STEAM_COMPAT_DATA_PATH");
   if (SteamDataPath) {
@@ -661,6 +698,9 @@
 }
 
 fextl::string GetConfigDirectory(bool Global, const PortableInformation& PortableInfo) {
+  if (SecureExec()) {
+    return GLOBAL_DATA_DIRECTORY;
+  }
   const char* ConfigOverride = getenv("FEX_APP_CONFIG_LOCATION");
   if (PortableInfo.IsPortable && Global) {
     return fextl::fmt::format("{}/../share/fex-emu/", PortableInfo.InterpreterPath);
@@ -709,6 +749,9 @@
 }
 
 fextl::string GetCacheDirectory() {
+  if (SecureExec()) {
+    return GLOBAL_DATA_DIRECTORY;
+  }
   const char* CacheOverride = getenv("FEX_APP_CACHE_LOCATION");
   if (CacheOverride) {
     return CacheOverride;
--- a/Source/Tools/FEXInterpreter/FEXInterpreter.cpp
+++ b/Source/Tools/FEXInterpreter/FEXInterpreter.cpp
@@ -381,12 +381,38 @@
     unsetenv(Env);
   }
   return FEXFD;
+}
+
+/**
+ * @brief Remove every `FEX_*` variable from the environment.
+ *
+ * dmx: binfmt_misc registers FEX with flag `C`, so a setuid or file-capability x86 program runs
+ * FEX with the file's credentials while its caller still chooses the environment. FEX reads its
+ * configuration from `FEX_*` variables, which choose the rootfs libraries are loaded from and
+ * the files it writes, so for such an exec the caller must not be able to set them. The kernel
+ * sets `AT_SECURE` for it, as it does for the exec where glibc drops `LD_PRELOAD`.
+ */
+static void DropFEXEnvironment() {
+  fextl::vector<fextl::string> Names;
+  for (char** Var = environ; Var && *Var; ++Var) {
+    const std::string_view View {*Var};
+    if (View.starts_with("FEX_")) {
+      Names.emplace_back(View.substr(0, View.find('=')));
+    }
+  }
+  for (const auto& Name : Names) {
+    unsetenv(Name.c_str());
+  }
 }
 
 int main(int argc, char** argv, char** const envp) {
   auto SBRKPointer = FEX::SBRKAllocations::DisableSBRKAllocations();
   FEXCore::Allocator::GLIBCScopedFault GLIBFaultScope;
 
+  if (getauxval(AT_SECURE)) {
+    DropFEXEnvironment();
+  }
+
   const bool ExecutedWithFD = getauxval(AT_EXECFD) != 0;
   const auto PortableInfo = FEX::ReadPortabilityInformation();
   const bool InterpreterInstalled = QueryInterpreterInstalled(ExecutedWithFD, PortableInfo);
--- a/FEXCore/Source/Utils/Allocator.cpp
+++ b/FEXCore/Source/Utils/Allocator.cpp
@@ -24,6 +24,7 @@
 #ifndef _WIN32
 #include <sys/mman.h>
 #include <sys/user.h>
+#include <unistd.h>
 #endif
 
 namespace fextl::pmr {
@@ -212,6 +213,56 @@
     Cursor = line_end + 1;
   }
   FEX_UNREACHABLE;
+}
+
+/**
+ * @brief Reserve the free parts of [Begin, End) without reading /proc/self/maps.
+ *
+ * dmx: `MAP_FIXED_NOREPLACE` fails with EEXIST where a mapping is already there, so the gaps can
+ * be found by probing for them. Only the chunks that fail are halved, so the whole upper half
+ * costs a few thousand calls: one per level for each existing mapping's two edges.
+ *
+ * Returns false if the host cannot be probed this way at all (a kernel before 4.17 ignores
+ * `MAP_FIXED_NOREPLACE` and answers with an address of its own); what it reserved until then is
+ * in Out. Regions come out in ascending order, as CollectMemoryGaps' do. Out may be null to
+ * reserve without handing the memory to the allocator.
+ */
+static bool ProbeMemoryRegion(uintptr_t Begin, uintptr_t End, int Prot, size_t PageSize, fextl::vector<MemoryRegion>* Out) {
+  if (Begin >= End) {
+    return true;
+  }
+
+  const size_t Size = End - Begin;
+  void* Ptr = ::mmap(reinterpret_cast<void*>(Begin), Size, Prot, MAP_ANONYMOUS | MAP_NORESERVE | MAP_PRIVATE | MAP_FIXED_NOREPLACE, -1, 0);
+  if (Ptr == reinterpret_cast<void*>(Begin)) {
+    // As in the loop below: a core dump must not try to write these out.
+    ::madvise(Ptr, Size, MADV_DONTDUMP);
+    if (Out) {
+      Out->emplace_back(MemoryRegion {Ptr, Size});
+    }
+    return true;
+  }
+
+  if (Ptr != MAP_FAILED) {
+    ::munmap(Ptr, Size);
+    return false;
+  }
+
+  // EEXIST means something is mapped in here, so the free parts are found by halving. Any other
+  // error is the kernel refusing the mapping itself (ENOMEM under an RLIMIT_AS, a map count
+  // limit): halving would ask it 68 billion times for the same answer, so stop and let the caller
+  // say it cannot reserve the space.
+  if (errno != EEXIST) {
+    return false;
+  }
+
+  const uintptr_t Mid = Begin + FEXCore::AlignDown(Size / 2, PageSize);
+  if (Mid == Begin || Mid == End) {
+    // A single page that is already taken.
+    return true;
+  }
+
+  return ProbeMemoryRegion(Begin, Mid, Prot, PageSize, Out) && ProbeMemoryRegion(Mid, End, Prot, PageSize, Out);
 }
 
 fextl::vector<MemoryRegion> StealMemoryRegion(uintptr_t Begin, uintptr_t End) {
@@ -221,8 +272,48 @@
   if (MapsFD == -1) {
     // No procfs, as in BuildKit's emulator probe (an empty chroot). The assert
     // above it compiles out in release, and CollectMemoryGaps then spins on
-    // read(-1) forever; reserve nothing instead.
-    return {};
+    // read(-1) forever.
+    //
+    // dmx: reserving nothing leaves the guest with the host's layout, and on a 48-bit AArch64
+    // host that means addresses above 2^47, which x86-64 programs cannot hold (jemalloc and
+    // mimalloc abort on them). Probe for the gaps instead.
+    const auto PageSizeRet = sysconf(_SC_PAGESIZE);
+    const size_t PageSize = PageSizeRet > 0 ? static_cast<size_t>(PageSizeRet) : FEXCore::Utils::FEX_PAGE_SIZE;
+    // The stack grows down into unmapped memory, so reserving everything below it would cap it
+    // at its current size. Map the window below the stack pointer readable and writable, as the
+    // procfs path does with the gap under the stack, and keep it out of the allocator's regions.
+    constexpr size_t StackHeadroom = 64ULL * 1024 * 1024;
+    const uintptr_t StackTop = FEXCore::AlignDown(StackLocation_u64, PageSize);
+    const uintptr_t StackBottom = StackTop > StackHeadroom ? StackTop - StackHeadroom : 0;
+
+    fextl::vector<MemoryRegion> Regions;
+    bool Reserved;
+    if (StackTop > Begin && StackBottom < End) {
+      const uintptr_t WindowBegin = std::max(Begin, StackBottom);
+      const uintptr_t WindowEnd = std::min(End, StackTop);
+      Reserved = ProbeMemoryRegion(WindowBegin, WindowEnd, PROT_READ | PROT_WRITE, PageSize, nullptr) &&
+                 ProbeMemoryRegion(Begin, WindowBegin, PROT_NONE, PageSize, &Regions) &&
+                 ProbeMemoryRegion(WindowEnd, End, PROT_NONE, PageSize, &Regions);
+    } else {
+      Reserved = ProbeMemoryRegion(Begin, End, PROT_NONE, PageSize, &Regions);
+    }
+
+    if (!Reserved || Regions.empty()) {
+      for (const auto& Region : Regions) {
+        ::munmap(Region.Ptr, Region.Size);
+      }
+      // Only this path refuses to run: with nothing reserved the guest would be left the host's
+      // layout, which on a 48-bit AArch64 host means addresses x86-64 programs cannot hold. The
+      // procfs path above keeps upstream's behaviour, where an empty result is the host's own
+      // answer rather than a failure to ask.
+      if (Begin == 0x0'8000'0000'0000ULL) {
+        constexpr char Message[] = "FEX: could not reserve the address space above 2^47 for x86-64 programs; refusing to run\n";
+        [[maybe_unused]] const auto Written = ::write(STDERR_FILENO, Message, sizeof(Message) - 1);
+        ::_exit(1);
+      }
+      return {};
+    }
+    return Regions;
   }
 
   auto Regions = CollectMemoryGaps(Begin, End, MapsFD);
@@ -288,6 +379,9 @@
   uintptr_t End48BitVA = 0x1'0000'0000'0000ULL;
   auto Regions = StealMemoryRegion(Begin48BitVA, End48BitVA);
   if (Regions.empty()) {
+    // dmx: the probe path stops by itself when it cannot reserve anything (StealMemoryRegion).
+    // Here, with /proc readable, an empty result is what the host's own map says and upstream
+    // runs with the host allocator, so keep that rather than refusing to start.
     return {};
   }
 
--- a/FEXCore/Source/Interface/Config/Config.json.in
+++ b/FEXCore/Source/Interface/Config/Config.json.in
@@ -12,10 +12,13 @@
       },
       "MaxInst": {
         "Type": "int32",
-        "Default": "5000",
+        "Default": "150",
         "AffectsCodeGen": "true",
         "Desc": [
-          "Maximum number of instruction to store in a block"
+          "Maximum number of instruction to store in a block",
+          "dmx: 150 rather than upstream's 5000. Compiling 5000-instruction superblocks out of",
+          "code that runs once is what made node start in 0.65 s instead of 0.27 s; the long",
+          "running workloads measured did not get slower, and node's JIT loop got faster"
         ]
       },
       "EnableCodeCachingWIP": {
--- a/Source/Tools/FEXInterpreter/ELFCodeLoader.h
+++ b/Source/Tools/FEXInterpreter/ELFCodeLoader.h
@@ -664,7 +664,14 @@
           0xc3,       // ret
         };
         memcpy(VSyscallPage, VSyscallCode, sizeof(VSyscallCode));
-        mprotect(VSyscallPage, FEXCore::Utils::FEX_PAGE_SIZE, PROT_READ);
+        // dmx: this page holds the only instructions a 32-bit program can enter the kernel
+        // through, so it has to be executable, and FEX's own tracking of it has to say so.
+        // Mapped read-only, as upstream leaves it, every 32-bit program died on its first
+        // syscall with "NoExec instruction in entry block: FFFFF000". The fallback is taken
+        // whenever there is no VDSO thunk to take a vsyscall entry from, and dmx builds none.
+        mprotect(VSyscallPage, FEXCore::Utils::FEX_PAGE_SIZE, PROT_READ | PROT_EXEC);
+        Handler->AddVirtualPage(Thread, reinterpret_cast<uint64_t>(VSyscallPage), FEXCore::Utils::FEX_PAGE_SIZE,
+                                PROT_READ | PROT_EXEC);
         VSyscallEntry = reinterpret_cast<uint64_t>(VSyscallPage);
       }
 
"""

TOOLCHAIN_ROOTS = [
    "clang22", "lld22", "llvm22", "cmake", "samurai", "python3", "linux-headers", "musl-dev",
    "libstdc++-dev", "gcc", "libgcc-static", "patch",
]
# Packages whose static libraries end up in the binary: libc, libstdc++ and libgcc.
STATIC_LINKED = ("musl-dev", "libstdc++-dev", "gcc", "libgcc-static")
# Closure of TOOLCHAIN_ROOTS minus what the minirootfs already has. Generated by --lock.
TOOLCHAIN = {
    "acl-libs-2.3.2-r1.apk": "5bfce1fc46a3625268a7a60c10b5680aa846534d98856a108e692824a1f1b710",
    "binutils-2.45.1-r1.apk": "bac4a00e73296dfebf5f587c2b304b7d110e7de658cd2b05491f87c2b228420c",
    "brotli-libs-1.2.1-r0.apk": "f802b9d5a329c216f02e73607cb8f662c434767e41686367ac0afcf6d0d45d64",
    "c-ares-1.34.9-r0.apk": "1bda7f36597a3f6d616b0c8bd25cd611299bf353ec5ee2ae102e97694885c2f1",
    "clang22-22.1.3-r2.apk": "1f147208ddca79ef7ff8ce1ac241b43fcc5d8ce7bda25f660d8761ad3615e0c0",
    "clang22-headers-22.1.3-r2.apk": "9740b2bbb74a62270f4014cbbb7fdf50d62914239ec1b5483c86156693dbfac0",
    "clang22-libs-22.1.3-r2.apk": "ad2c5f44f52daa3a8dd0fcd02ed83c1f6270059306b615040d9747847caaabcf",
    "cmake-4.2.3-r0.apk": "fbc19c4efe1a12dbcdb646952e9dc1ee2f8bf68feb6ed17fdf320f34bba252ef",
    "fortify-headers-3.0.1-r2.apk": "72bf2a77475f2550a7345683c77b39487ee94ecbc2ca11ed5314161f3b927d76",
    "gcc-15.2.0-r5.apk": "ff3fecfc32c9a1bed4a47a32ccfee6f6f575708258f912c218dce8ed0d892221",
    "gdbm-1.26-r0.apk": "bad50eb26533e2f58e014fbcd3c1744f2fdb79954af6e3c188ccd059251c7790",
    "gmp-6.3.0-r4.apk": "4dab6e86b850fe1b5bc0cf2fac17efa4d7f648bea44f3d9019694cc1e1cb12b7",
    "isl25-0.25-r2.apk": "5209569eb853a98e72f3d78ae575c66708e1d628b8cb2131eb870b3ba1ef0950",
    "jansson-2.15.0-r0.apk": "a13822f5ca1772cced4bb7d3d178ec5dee770d8accba5b4816b2ddc413e6f055",
    "libarchive-3.8.10-r0.apk": "506ffede86c7af41e7256dbbb98af368243fc9a9c9f61d19804c4c3047c8e0b1",
    "libatomic-15.2.0-r5.apk": "31a45fec053c43a006370f83238f16f959838a9a703fbf26bfd1a36da4f538b2",
    "libbz2-1.0.8-r6.apk": "28cb76bb6d11d2a55c3061b5fcb2ab84996412a248b2c9fe52bb710d0a2a84e7",
    "libcurl-8.23.0-r0.apk": "64ae89f6e5d318ed5209778232191806ce49644ce9e09540b7d7830a5330d127",
    "libexpat-2.9.0-r0.apk": "7128bfe18b8a315b9cf90ddf0beffeee454648ae72ff7898ff7d7b09803a559d",
    "libffi-3.5.2-r1.apk": "9a67280b0c7c62db658c2d4d32ed1199903bef859c32dd4245e1a7e35c89ab4b",
    "libgcc-15.2.0-r5.apk": "369aaa6e9d099a737bad6dd3e6c2fe7bb1547ca26d22b94ee0411228f709b403",
    "libgcc-static-15.2.0-r5.apk": "2ec3dc4be953d842cc51193248367d86829ed699a1ed094fb5149b1b3fc62919",
    "libgomp-15.2.0-r5.apk": "90576a8899c560d3983b8ac8442b5b75957a917bc1c4e950e005945080f8682f",
    "libidn2-2.3.8-r0.apk": "d02ffda4510652f89c5fb89cd2e7ff721afb0c74e7d75476ad60bebe7ac0ae20",
    "libncursesw-6.6_p20260516-r0.apk": "51a7aa4b3ec40b144d0801c0544e0a9f62e2a41d04b6067bb5e95786040741c6",
    "libpanelw-6.6_p20260516-r0.apk": "a6912c654c821db4f8a801321709205bd482b0e515b862f2d02045e21b73d97d",
    "libpsl-0.21.5-r3.apk": "b31e91371425d5f80c1db5cba2a849956b65c802add0b49de844b2ca961aa8da",
    "libstdc++-15.2.0-r5.apk": "2302e766d4e4926038ec166ecb85837ee884576115236ddb565e3a5fca4a11d7",
    "libstdc++-dev-15.2.0-r5.apk": "8385c811d93b64ee1877005a5473cde8ebabe82d346301f2b153ff8cb6a71510",
    "libunistring-1.4.2-r0.apk": "58abfcbce2459071c505771a572a79953d6043d72b643ed0d5285ca39cdaf85c",
    "libuv-1.52.1-r0.apk": "64e29a6c58f8375bc9cf83d57e0913e6743746cfc60851b1cb12cd572f5924f3",
    "libxml2-2.13.9-r2.apk": "0a860a26ebdfea491498386fe682130f4c5565e46ee8e0a2281256db2ef1be27",
    "linux-headers-7.0.0-r1.apk": "d61656e81116040ebac0bc8d9046a3ba97f01a00ee085809103576e8a437468f",
    "lld22-22.1.3-r0.apk": "bbd5767abd254135936a0ebfbc952d7d01929725f11c53c20b51662bc819c838",
    "lld22-libs-22.1.3-r0.apk": "aced61ba21a58132c5233b27b13fc3e2c84cf9c92a1b75b8976013ab804902aa",
    "llvm22-22.1.3-r1.apk": "1d8d4bbe13393bdfb5701841f199e7011e90aafa017f448dd02d41464e4f7baa",
    "llvm22-libs-22.1.3-r1.apk": "6b1b25fdc82cd6d0e2fb57594d08d405569d4776e4b9c56012bd81f8dd90805a",
    "llvm22-linker-tools-22.1.3-r1.apk": "c2188d54124bc56289c0a64fa81f1a3309f9ca0d7b1007b3d0aab4d5a3d5303f",
    "lz4-libs-1.10.0-r1.apk": "af6cbe553adda941e04ac40cf0123455b714d65392472389113e7d6dcebbd8d8",
    "mpc1-1.3.1-r1.apk": "c4e03923cf1b958ba0d3665196f521a00fb091132e79c39493298019fb59ae60",
    "mpdecimal-4.0.1-r0.apk": "358959600f99f58deee30ca9089c7f6f0f1bd73cc0021e321a7dbf6f735935c6",
    "mpfr4-4.2.2-r0.apk": "81cb276c1e050138fed90c8f1ef584cf5bfce26739733753fce138fc0a092b35",
    "musl-dev-1.2.6-r3.apk": "45afe0a9f78de3402b6b5d11f5153ed955bf59d59b45344d9c3fed9f4bbf2f66",
    "ncurses-terminfo-base-6.6_p20260516-r0.apk": "e0c546b9461bdce206a90bc720cb69aa4628b5a5b8d908c3e5084e00f28f6a9d",
    "nghttp2-libs-1.70.0-r0.apk": "7ef451f4dcdc065aa872c2f3c78b9d9bb4348caa5bcc70dee0c9e1fcf8e4c1fd",
    "patch-2.8-r0.apk": "c6c7bf0a5d7a9a06d6d6e4dbf44ab6b31308472ba0e15ca1b120f2281b35cf0a",
    "python3-3.14.8-r0.apk": "fb5cc51e45afd7cc78b3189d8019a554e48c6751f0ccbe1aa551d6d94453db5c",
    "readline-8.3.3-r1.apk": "9f0ae0923c02b0d6aba62e9173542b65396ba3f0efefcbf087ea32f1120e7b34",
    "rhash-libs-1.4.6-r0.apk": "7e48c2bbea516c1b97887e6d9cb50e772de9e61e0aa31c4e042cc34df07a3016",
    "samurai-1.2-r8.apk": "37776aa84fe45e5f8430df347050e1e11b750e892a88b9ee24d479776f0594d8",
    "scudo-malloc-22.1.3-r0.apk": "186aa6cd23e901a21f76b12775cfe035c9ed15eecc5b5c322b9725ab62ff50f8",
    "sqlite-libs-3.53.4-r0.apk": "b39d8d73c1208838a436f2d481ba605b52a095f8d6ff781556eafc81cd1a13e9",
    "xz-libs-5.8.4-r0.apk": "9be375832e747afe14f98e400e8b55d8f6fde25e41663090c81600628daab093",
    "zstd-libs-1.5.7-r2.apk": "2bb5136c89f5b0bbe1554c8915a3b520d5aa63ae2a51d4d821eb81698db5a818",
}

# Generic arm64 code (not tuned to the build machine), no telemetry files, FEX's own allocator
# for its JIT but not the glibc allocator hook, and the release's version string (there is no
# git checkout to describe).
BUILD_SH = r"""
set -eu
# stdout carries the binary; everything else goes to stderr.
exec 3>&1 1>&2
cd /build
apk add --no-network --repositories-file /dev/null --force-non-repository --quiet pkgs/*.apk
mkdir src
for s in $SOURCES; do
	dir=${s%%=*} file=${s#*=}
	mkdir -p src/$dir
	tar -xzf src-$file.tar.gz -C src/$dir --strip-components=1
	rm src-$file.tar.gz
done
cd src
patch -p1 -s <../dmx-fex.patch
mkdir build
cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
	-DUSE_LINKER=lld -DENABLE_LTO=True -DCMAKE_CXX_SCAN_FOR_MODULES=OFF -DTUNE_CPU=generic \
	-DBUILD_TESTING=False -DBUILD_FEXCONFIG=False -DBUILD_THUNKS=False -DENABLE_ASSERTIONS=False \
	-DENABLE_JEMALLOC_GLIBC_ALLOC=False -DENABLE_OFFLINE_TELEMETRY=False -DENABLE_CCACHE=False \
	-DOVERRIDE_VERSION=$VERSION -DOVERRIDE_HASH=$COMMIT -DCMAKE_EXE_LINKER_FLAGS=-static-pie .. >/dev/null
start=$(date +%s)
# The emulated /proc/version has __DATE__ and __TIME__ in it.
SOURCE_DATE_EPOCH=$EPOCH ninja FEX
echo "build-fex: compiled in $(( $(date +%s) - start )) s" >&2
cat Bin/FEX >&3
"""


def has_interpreter(elf: bytes) -> bool:
    """True if the ELF64 has a PT_INTERP program header."""
    phoff, = struct.unpack_from("<Q", elf, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", elf, 0x36)
    return any(struct.unpack_from("<I", elf, phoff + i * phentsize)[0] == 3 for i in range(phnum))


def build(args):
    if not TOOLCHAIN:
        sys.exit("TOOLCHAIN is empty; run with --lock and paste the result")
    out = CACHE / guest.DMX_FEX
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w") as tar:
        def add(name, data):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        add("build.sh", BUILD_SH.encode())
        add("dmx-fex.patch", FEX_PATCH.encode())
        for repo, commit, sha256 in SOURCES.values():
            tar.add(kernel.fetch(source_url(repo, commit), sha256), f"src-{commit}.tar.gz")
        for pin, sha256 in TOOLCHAIN.items():
            tar.add(kernel.fetch(kernel.apk_url(pin), sha256), f"pkgs/{Path(pin).name}")

    # The bootstrap guest (stock Alpine kernel) that `make kernel` uses, so this does not depend
    # on an earlier dmx guest either.
    bootstrap = CACHE / "bootstrap"
    subprocess.run([sys.executable, "-I", str(ROOT / "scripts" / "build-guest.py"), "--kernel", "alpine",
                    "--cache", str(CACHE), "--out", str(bootstrap / "guest")], check=True, stdout=subprocess.DEVNULL)
    dmx = ROOT / ".build" / "release" / "dmx"
    sources = " ".join(f"{d}={c}" for d, (_, c, _) in SOURCES.items())
    script = ("set -e; mkdir /build; mount -t tmpfs -o size=90% tmpfs /build; cd /build; tar -xf -; "
              f"SOURCES='{sources}' VERSION='{VERSION}' COMMIT='{COMMIT}' EPOCH='{guest.EPOCH}' sh build.sh")
    cmd = [str(dmx), "boot", "--memory", args.memory, "--boot-memory", args.memory, "--", "sh", "-c", script]
    start = time.monotonic()
    tmp = out.with_name(out.name + ".part")
    with open(tmp, "wb") as f:
        proc = subprocess.run(cmd, input=payload.getvalue(), stdout=f, env={**os.environ, "DMX_HOME": str(bootstrap)})
    if proc.returncode != 0 or tmp.read_bytes()[:4] != b"\x7fELF":
        tmp.unlink(missing_ok=True)
        sys.exit(f"FEX build failed (exit {proc.returncode})")
    if has_interpreter(tmp.read_bytes()):
        tmp.unlink()
        sys.exit("FEX build failed: the binary needs a dynamic loader, which containers do not have")
    tmp.chmod(0o755)
    tmp.rename(out)
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    print(f'{{"ok": true, "out": "{out}", "bytes": {out.stat().st_size}, "sha256": "{digest}", "seconds": {time.monotonic() - start:.0f}}}')


def main():
    global CACHE
    home = Path(os.environ.get("DMX_HOME", Path.home() / ".dmx"))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cache", type=Path, default=home / "cache")
    ap.add_argument("--memory", default="8G", help="memory ceiling of the build VM")
    ap.add_argument("--lock", action="store_true", help="print TOOLCHAIN pins for the current APKINDEX")
    args = ap.parse_args()
    CACHE = kernel.CACHE = args.cache
    CACHE.mkdir(parents=True, exist_ok=True)
    kernel.lock(TOOLCHAIN_ROOTS) if args.lock else build(args)


if __name__ == "__main__":
    main()
