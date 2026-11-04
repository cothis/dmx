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
fixes four places that relied on glibc behaviour musl does not have. Signal return restores
its syscall marker even when the handler leaves RIP unchanged; the decoder takes aligned
eight-byte snapshots so an atomic HotSpot method-entry rewrite cannot mix opcode and operand
bytes; and a block decoded from writable code is checked against memory once its pages are
write-protected and decoded again if another thread changed it in between (pages already known
to be protected are not protected again). Signal contexts and temporary wait masks follow the guest,
abandoned signal frames are reclaimed, and new writable aliases invalidate translated code. Integer
division raises x86's faults, including when a host parent ignored the signal. Output:
<cache>/<guest.DMX_FEX>, a stripped static PIE. `make guest` puts it in docker.img.

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
 
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator/GuestFramesManagement.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator/GuestFramesManagement.cpp
@@ -126,12 +126,11 @@
                                        FEXCore::Core::CpuStateFrame* Frame, void* ucontext) {
   auto* guest_uctx = reinterpret_cast<FEXCore::x86_64::ucontext_t*>(Context->UContextLocation);
   [[maybe_unused]] auto* guest_siginfo = reinterpret_cast<siginfo_t*>(Context->SigInfoLocation);
+  // A normal sigreturn also bypasses the syscall epilogue; restore its spill marker.
+  Frame->InSyscallInfo = Context->InSyscallInfo;

   // If the guest modified the RIP then we need to take special precautions here
   if (Context->OriginalRIP != guest_uctx->uc_mcontext.gregs[FEXCore::x86_64::FEX_REG_RIP] || Context->FaultToTopAndGeneratedException) {
-
-    // Restore previous `InSyscallInfo` structure.
-    Frame->InSyscallInfo = Context->InSyscallInfo;

     // Hack! Go back to the top of the dispatcher top
     // This is only safe inside the JIT rather than anything outside of it
@@ -208,11 +207,10 @@
 void SignalDelegator::RestoreFrame_ia32(FEXCore::Core::InternalThreadState* Thread, ArchHelpers::Context::ContextBackup* Context,
                                         FEXCore::Core::CpuStateFrame* Frame, void* ucontext) {
   SigFrame_i32* guest_uctx = reinterpret_cast<SigFrame_i32*>(Context->UContextLocation);
+  // A normal sigreturn also bypasses the syscall epilogue; restore its spill marker.
+  Frame->InSyscallInfo = Context->InSyscallInfo;
   // If the guest modified the RIP then we need to take special precautions here
   if (Context->OriginalRIP != guest_uctx->sc.ip || Context->FaultToTopAndGeneratedException) {
-    // Restore previous `InSyscallInfo` structure.
-    Frame->InSyscallInfo = Context->InSyscallInfo;
-
     // Hack! Go back to the top of the dispatcher top
     // This is only safe inside the JIT rather than anything outside of it
     ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
@@ -286,11 +284,10 @@
 void SignalDelegator::RestoreRTFrame_ia32(FEXCore::Core::InternalThreadState* Thread, ArchHelpers::Context::ContextBackup* Context,
                                           FEXCore::Core::CpuStateFrame* Frame, void* ucontext) {
   RTSigFrame_i32* guest_uctx = reinterpret_cast<RTSigFrame_i32*>(Context->UContextLocation);
+  // A normal sigreturn also bypasses the syscall epilogue; restore its spill marker.
+  Frame->InSyscallInfo = Context->InSyscallInfo;
   // If the guest modified the RIP then we need to take special precautions here
   if (Context->OriginalRIP != guest_uctx->uc.uc_mcontext.gregs[FEXCore::x86::FEX_REG_EIP] || Context->FaultToTopAndGeneratedException) {
-
-    // Restore previous `InSyscallInfo` structure.
-    Frame->InSyscallInfo = Context->InSyscallInfo;

     // Hack! Go back to the top of the dispatcher top
     // This is only safe inside the JIT rather than anything outside of it

--- a/FEXCore/Source/Interface/Core/Frontend.cpp
+++ b/FEXCore/Source/Interface/Core/Frontend.cpp
@@ -129,8 +129,24 @@

 std::optional<uint8_t> Decoder::PeekByte(uint8_t Offset) {
   uint64_t ByteAddress = reinterpret_cast<uint64_t>(InstStream.InstStream + InstructionSize + Offset);
+  if (InstructionSize + Offset >= MAX_INST_SIZE) {
+    return std::nullopt;
+  }
   if (CheckRangeExecutable(ByteAddress, 1)) {
-    return InstStream.AdjustedInstStream[InstructionSize + Offset];
+    if (InstStream.InstStream != InstStream.AdjustedInstStream) {
+      // Synthetic vsyscall bytes are immutable and need no concurrent-code snapshot.
+      return InstStream.AdjustedInstStream[InstructionSize + Offset];
+    }
+    const uint64_t WordAddress = ByteAddress & ~uint64_t {7};
+    const uint64_t FirstWord = reinterpret_cast<uint64_t>(InstStream.InstStream) & ~uint64_t {7};
+    const size_t Index = (WordAddress - FirstWord) / 8;
+    if (!(InstructionWordMask & (1U << Index))) {
+      // HotSpot atomically replaces an aligned eight-byte method entry. Fetch that
+      // word once so opcode and operands cannot come from different versions.
+      InstructionWords[Index] = __atomic_load_n(reinterpret_cast<const uint64_t*>(WordAddress), __ATOMIC_RELAXED);
+      InstructionWordMask |= 1U << Index;
+    }
+    return uint8_t(InstructionWords[Index] >> (8 * (ByteAddress & 7)));
   } else {
     return std::nullopt;
   }
@@ -144,7 +160,15 @@
   LastFieldReadOffset = (uint8_t)InstructionSize;
   LastFieldReadSize = Size;
   if (CheckRangeExecutable(Address, Size)) {
-    std::memcpy(&Res, &InstStream.AdjustedInstStream[InstructionSize], Size);
+    for (uint8_t i = 0; i < Size; ++i) {
+      auto Byte = PeekByte(i);
+      if (!Byte) {
+        HitNonExecutableRange = true;
+        Res = 0;
+        break;
+      }
+      Res |= uint64_t(*Byte) << (8 * i);
+    }
   } else {
     HitNonExecutableRange = true;
     // See PeekByte, this specific case may cause some executable memory to read as 0 but it doesn't matter as the entire instruction will be rolled back anyway.
@@ -1581,6 +1605,7 @@

     while (1) {
       InstructionSize = 0;
+      InstructionWordMask = 0;

       // MAX_INST_SIZE assumes worst case
       auto OpAddress = BlockIt->Entry + PCOffset;
--- a/FEXCore/Source/Interface/Core/Frontend.h
+++ b/FEXCore/Source/Interface/Core/Frontend.h
@@ -181,6 +181,9 @@

   static constexpr size_t MAX_INST_SIZE = 15;
   uint8_t InstructionSize {};
+  // At most three aligned words cover one 15-byte x86 instruction.
+  uint64_t InstructionWords[3] {};
+  uint8_t InstructionWordMask {};
   // Contains the full decoded instruction, unless it is a `Thunk` instruction.
   std::array<uint8_t, MAX_INST_SIZE> Instruction;
   uint8_t LastEscapePrefix {};
--- a/FEXCore/Source/Interface/Core/Core.cpp
+++ b/FEXCore/Source/Interface/Core/Core.cpp
@@ -875,6 +875,9 @@
     return HostCode;
   }
 
+  int DecodeAttempts = 0;
+  bool CacheBlock = true;
+DecodeAgain:
   Thread->FrontendDecoder->SetupDecodeInstructionsAtEntry(Thread, GuestRIP, MaxInst);
 
   std::optional<ExecutableFileSectionInfo> Region = SyscallHandler->LookupExecutableFileSection(Thread, GuestRIP);
@@ -928,6 +931,28 @@
     return reinterpret_cast<uintptr_t>(CodePtr);
   }
 
+  // Another thread can write mutable code between decoding and the write protection below, and that
+  // write does not fault, so the block would keep running the old bytes. Protect every page first,
+  // including those another thread marked but may not have protected yet; writers then fault and wait
+  // on CodeInvalidationMutex for this compile. Decode again if the bytes changed in the meantime.
+  // Writes protection cannot stop (another process sharing the memory) may defeat the retries;
+  // such a block runs once and is not cached.
+  const bool RecheckCode = NeedsAddGuestCodeRanges && Thread->FrontendDecoder->DecodedFromMutableCode();
+  if (RecheckCode) {
+    for (auto CodePage : Thread->FrontendDecoder->GetDecodedBlockInfo()->CodePages) {
+      SyscallHandler->MarkGuestExecutableRange(Thread, CodePage, FEXCore::Utils::FEX_PAGE_SIZE);
+    }
+    if (!Thread->FrontendDecoder->MutableCodeUnchanged()) {
+      if (++DecodeAttempts < 8) {
+        if (!CodeCache.IsGeneratingCache) {
+          Thread->CPUBackend->ClearRelocations();
+        }
+        goto DecodeAgain;
+      }
+      CacheBlock = false;
+    }
+  }
+
   if (DiskCacheGuestCodeKey && Hit && DiskCache.IsValidating()) {
     DiskCache.Validate(*DiskCacheGuestCodeKey, *Hit, CompiledCode, Region);
   }
@@ -983,14 +1008,14 @@
     CodePages.reserve(BlockInfo->CodePages.size());
     CodePages.insert(CodePages.end(), BlockInfo->CodePages.begin(), BlockInfo->CodePages.end());
     for (auto CodePage : BlockInfo->CodePages) {
-      if (Thread->LookupCache->AddBlockExecutableRange(Thread, BlockInfo->EntryPoints, CodePage, FEXCore::Utils::FEX_PAGE_SIZE)) {
+      if (Thread->LookupCache->AddBlockExecutableRange(Thread, BlockInfo->EntryPoints, CodePage, FEXCore::Utils::FEX_PAGE_SIZE) && !RecheckCode) {
         SyscallHandler->MarkGuestExecutableRange(Thread, CodePage, FEXCore::Utils::FEX_PAGE_SIZE);
       }
     }
   }
 
   // Disk Cache
-  if (!CodeCache.IsGeneratingCache) {
+  if (!CodeCache.IsGeneratingCache && CacheBlock) {
     if (DiskCacheGuestCodeKey) {
       std::span<const FEXCore::CPU::Relocation> Relocations;
       if (DebugData && DebugData->Relocations) {
@@ -1009,7 +1034,9 @@
 
   // Insert to lookup cache
   for (auto [GuestAddr, HostAddr] : CompiledCode.EntryPoints) {
-    Thread->LookupCache->AddBlockMapping(Thread, GuestAddr, CodePages, HostAddr);
+    if (CacheBlock) {
+      Thread->LookupCache->AddBlockMapping(Thread, GuestAddr, CodePages, HostAddr);
+    }
   }
 
   // Clear any relocations that might have been generated
--- a/FEXCore/Source/Interface/Core/Frontend.cpp
+++ b/FEXCore/Source/Interface/Core/Frontend.cpp
@@ -99,6 +99,7 @@
     ExecutableRangeBase = RangeInfo.Base;
     ExecutableRangeEnd = RangeInfo.Base + RangeInfo.Size;
     ExecutableRangeWritable = RangeInfo.Writable;
+    ExecutableRangeMayChange = RangeInfo.MayChange;
 
     if (RangeInfo.Size == 0) {
       return false;
@@ -145,6 +146,9 @@
       // word once so opcode and operands cannot come from different versions.
       InstructionWords[Index] = __atomic_load_n(reinterpret_cast<const uint64_t*>(WordAddress), __ATOMIC_RELAXED);
       InstructionWordMask |= 1U << Index;
+      if (ExecutableRangeMayChange && CTX->Config.SMCChecks == FEXCore::Config::CONFIG_SMC_MTRACK) {
+        MutableCodeWords.push_back({WordAddress, InstructionWords[Index]});
+      }
     }
     return uint8_t(InstructionWords[Index] >> (8 * (ByteAddress & 7)));
   } else {
@@ -152,6 +156,15 @@
   }
 }
 
+bool Decoder::MutableCodeUnchanged() const {
+  for (const auto& Word : MutableCodeWords) {
+    if (__atomic_load_n(reinterpret_cast<const uint64_t*>(Word.Address), __ATOMIC_RELAXED) != Word.Value) {
+      return false;
+    }
+  }
+  return true;
+}
+
 std::pair<uint64_t, bool> Decoder::ReadData(uint8_t Size) {
   LOGMAN_THROW_A_FMT(Size != 0 && Size <= sizeof(uint64_t), "Unknown data size to read");
 
@@ -1812,6 +1825,7 @@
   CurrentCodePage = PC & FEXCore::Utils::FEX_PAGE_MASK;
 
   BlockInfo.CodePages = {CurrentCodePage};
+  MutableCodeWords.clear();
 
   EntryBlock = true;
   FinalInstruction = false;
--- a/FEXCore/Source/Interface/Core/Frontend.h
+++ b/FEXCore/Source/Interface/Core/Frontend.h
@@ -89,6 +89,13 @@
     ExecutableRangeBase = ExecutableRangeEnd = 0;
   }
 
+  // True if the block was decoded from guest code that may change before its pages are
+  // write-protected (SMC tracking by mprotect only).
+  bool DecodedFromMutableCode() const {
+    return !MutableCodeWords.empty();
+  }
+  bool MutableCodeUnchanged() const;
+
 private:
   // To pass any information from instruction prefixes
   // down into the actual instruction handling machinery.
@@ -151,6 +158,7 @@
   uint64_t ExecutableRangeBase {};
   uint64_t ExecutableRangeEnd {};
   bool ExecutableRangeWritable {};
+  bool ExecutableRangeMayChange {};
   bool HitNonExecutableRange {};
   bool HitBadRelocation {};
 
@@ -184,6 +192,12 @@
   // At most three aligned words cover one 15-byte x86 instruction.
   uint64_t InstructionWords[3] {};
   uint8_t InstructionWordMask {};
+  struct CodeWord {
+    uint64_t Address;
+    uint64_t Value;
+  };
+  // Every aligned word of mutable guest code this block was decoded from.
+  fextl::vector<CodeWord> MutableCodeWords;
   // Contains the full decoded instruction, unless it is a `Thunk` instruction.
   std::array<uint8_t, MAX_INST_SIZE> Instruction;
   uint8_t LastEscapePrefix {};
--- a/FEXCore/include/FEXCore/HLE/SyscallHandler.h
+++ b/FEXCore/include/FEXCore/HLE/SyscallHandler.h
@@ -21,6 +21,8 @@
   uint64_t Base;
   uint64_t Size;
   bool Writable;
+  // Writable here or through another mapping of the same memory.
+  bool MayChange {};
 };
 
 class SyscallHandler;
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsSMCTracking.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsSMCTracking.cpp
@@ -226,7 +226,7 @@
       (!Entry->second.Prot.Executable && (!(ThreadObject->persona & READ_IMPLIES_EXEC) || !Entry->second.Prot.Readable))) {
     return {0, 0, false};
   }
-  return {Entry->first, Entry->second.Length, Entry->second.Prot.Writable};
+  return {Entry->first, Entry->second.Length, Entry->second.Prot.Writable, Entry->second.Prot.Writable || Entry->second.Flags.Shared};
 }
 
 struct ReadELFHeadersResult {
--- a/FEXCore/Source/Interface/Context/Context.h
+++ b/FEXCore/Source/Interface/Context/Context.h
@@ -152,6 +152,7 @@
   uint64_t GetGuestBlockEntry(FEXCore::Core::InternalThreadState* Thread) override;
 
   uint64_t RestoreRIPFromHostPC(FEXCore::Core::InternalThreadState* Thread, uint64_t HostPC) override;
+  uint32_t GetBlockStackBytesFromHostPC(FEXCore::Core::InternalThreadState* Thread, uint64_t HostPC) override;
   uint32_t ReconstructCompactedEFLAGS(FEXCore::Core::InternalThreadState* Thread, bool WasInJIT, const uint64_t* HostGPRs, uint64_t PSTATE) override;
   void SetFlagsFromCompactedEFLAGS(FEXCore::Core::InternalThreadState* Thread, uint32_t EFLAGS) override;
 
@@ -379,6 +380,11 @@
   bool HostRNGAvailable {};
 
   FEXCore::Utils::WritePriorityMutex::Mutex CodeInvalidationMutex {};
+  // Pages of mutable code CompileBlock has write-protected since their last invalidation. Every change
+  // that makes a page writable again is followed by one, under CodeInvalidationMutex, before the guest
+  // can rely on it.
+  std::mutex ProtectedCodePagesMutex;
+  fextl::set<uint64_t> ProtectedCodePages;
 
   uint32_t StrictSplitLockMutex {};
 
--- a/FEXCore/Source/Interface/Core/CPUBackend.h
+++ b/FEXCore/Source/Interface/Core/CPUBackend.h
@@ -92,6 +92,9 @@
       // Shared-code modification spin-loop futex.
       uint32_t SpinLockFutex;
 
+      // Host stack this block allocates for its spill slots.
+      uint32_t SpillStackBytes;
+
       // If this block represents a single guest instruction.
       bool SingleInst;
 
--- a/FEXCore/Source/Interface/Core/Core.cpp
+++ b/FEXCore/Source/Interface/Core/Core.cpp
@@ -183,6 +183,15 @@
 
   // Fallback to what is stored in the RIP currently.
   return Frame->State.rip;
+}
+
+uint32_t ContextImpl::GetBlockStackBytesFromHostPC(FEXCore::Core::InternalThreadState* Thread, uint64_t HostPC) {
+  const uint64_t BlockBegin = Thread->CurrentFrame->State.InlineJITBlockHeader;
+  auto [InlineHeader, InlineTail] = GetFrameBlockInfo(Thread->CurrentFrame);
+  if (InlineHeader && HostPC >= BlockBegin && HostPC < BlockBegin + InlineTail->Size) {
+    return InlineTail->SpillStackBytes;
+  }
+  return 0;
 }
 
 uint32_t ContextImpl::ReconstructCompactedEFLAGS(FEXCore::Core::InternalThreadState* Thread, bool WasInJIT, const uint64_t* HostGPRs,
@@ -364,10 +373,8 @@
   // Set up the SignalDelegator config since core is initialized.
   SignalDelegation->SetConfig(Dispatcher->MakeSignalDelegatorConfig());
 
-  if (Config.GdbServer) {
-    // If gdbserver is enabled then this needs to be enabled.
-    Config.NeedsPendingInterruptFaultCheck = true;
-  }
+  // Guest signals that arrive outside a system call wait for these checks, where the guest state is exact.
+  Config.NeedsPendingInterruptFaultCheck = true;
 
   if constexpr (BLOCK_DEBUGGING) {
     // If the developer wants to do any single-stepping points or watch points.
@@ -933,14 +940,23 @@
 
   // Another thread can write mutable code between decoding and the write protection below, and that
   // write does not fault, so the block would keep running the old bytes. Protect every page first,
-  // including those another thread marked but may not have protected yet; writers then fault and wait
-  // on CodeInvalidationMutex for this compile. Decode again if the bytes changed in the meantime.
+  // including those another thread marked but may not have protected yet (pages known to be protected
+  // are skipped); writers then fault and wait on CodeInvalidationMutex for this compile. Decode again
+  // if the bytes changed in the meantime.
   // Writes protection cannot stop (another process sharing the memory) may defeat the retries;
   // such a block runs once and is not cached.
   const bool RecheckCode = NeedsAddGuestCodeRanges && Thread->FrontendDecoder->DecodedFromMutableCode();
   if (RecheckCode) {
     for (auto CodePage : Thread->FrontendDecoder->GetDecodedBlockInfo()->CodePages) {
+      {
+        std::scoped_lock ProtectedLock(ProtectedCodePagesMutex);
+        if (ProtectedCodePages.contains(CodePage)) {
+          continue;
+        }
+      }
       SyscallHandler->MarkGuestExecutableRange(Thread, CodePage, FEXCore::Utils::FEX_PAGE_SIZE);
+      std::scoped_lock ProtectedLock(ProtectedCodePagesMutex);
+      ProtectedCodePages.insert(CodePage);
     }
     if (!Thread->FrontendDecoder->MutableCodeUnchanged()) {
       if (++DecodeAttempts < 8) {
@@ -1076,6 +1092,11 @@
   FEXCORE_PROFILE_SCOPED("InvalidateCodeBuffersCodeRange");
 
   LOGMAN_THROW_A_FMT(CodeInvalidationMutex.try_lock() == false, "CodeInvalidationMutex needs to be unique_locked here");
+  {
+    std::scoped_lock ProtectedLock(ProtectedCodePagesMutex);
+    ProtectedCodePages.erase(ProtectedCodePages.lower_bound(Start & FEXCore::Utils::FEX_PAGE_MASK),
+                             ProtectedCodePages.lower_bound(Start + Length));
+  }
   std::scoped_lock lk {CodeBufferListLock};
   auto it = CodeBufferList.begin();
   while (it != CodeBufferList.end()) {
--- a/FEXCore/Source/Interface/Core/JIT/BranchOps.cpp
+++ b/FEXCore/Source/Interface/Core/JIT/BranchOps.cpp
@@ -249,9 +249,18 @@
   auto Op = IROp->C<IR::IROp_CondJump>();
 
   auto TrueTargetLabel = JumpTarget(Op->TrueBlock);
+
+  // A loop can close on a conditional branch and never reach another check, so a backward branch goes through one,
+  // only when taken. REP SCAS and REP CMPS branch inside the instruction: a guest restarted from a check on the path out
+  // would go on searching after a match, while on the way back round all the instruction's state is written and it can restart.
+  // Inverting the branch keeps the loop's path to one taken branch.
+  const bool Backward = TrueTargetLabel->Backward.Location != nullptr;
+  ARMEmitter::BiDirectionalLabel NotTaken;
+  auto BranchLabel = Backward ? &NotTaken : TrueTargetLabel;
 
   if (Op->FromNZCV) {
-    b_OrRestart(MapCC(Op->Cond), TrueTargetLabel);
+    const auto Condition = MapCC(Op->Cond);
+    b_OrRestart(Backward ? static_cast<ARMEmitter::Condition>(FEXCore::ToUnderlying(Condition) ^ 1) : Condition, BranchLabel);
   } else {
     uint64_t Const;
     const bool isConst = IsInlineConstant(Op->Cmp2, &Const);
@@ -264,21 +273,43 @@
 
     if (Op->Cond == IR::CondClass::EQ) {
       LOGMAN_THROW_A_FMT(Const == 0, "CondJump: Expected 0 source");
-      cbz_OrRestart(Size, Reg, TrueTargetLabel);
+      if (Backward) {
+        cbnz_OrRestart(Size, Reg, BranchLabel);
+      } else {
+        cbz_OrRestart(Size, Reg, BranchLabel);
+      }
     } else if (Op->Cond == IR::CondClass::NEQ) {
       LOGMAN_THROW_A_FMT(Const == 0, "CondJump: Expected 0 source");
-      cbnz_OrRestart(Size, Reg, TrueTargetLabel);
+      if (Backward) {
+        cbz_OrRestart(Size, Reg, BranchLabel);
+      } else {
+        cbnz_OrRestart(Size, Reg, BranchLabel);
+      }
     } else if (Op->Cond == IR::CondClass::TSTZ) {
       LOGMAN_THROW_A_FMT(Const < 64, "CondJump: Expected valid bit source");
-      tbz_OrRestart(Reg, Const, TrueTargetLabel);
+      if (Backward) {
+        tbnz_OrRestart(Reg, Const, BranchLabel);
+      } else {
+        tbz_OrRestart(Reg, Const, BranchLabel);
+      }
     } else if (Op->Cond == IR::CondClass::TSTNZ) {
       LOGMAN_THROW_A_FMT(Const < 64, "CondJump: Expected valid bit source");
-      tbnz_OrRestart(Reg, Const, TrueTargetLabel);
+      if (Backward) {
+        tbz_OrRestart(Reg, Const, BranchLabel);
+      } else {
+        tbnz_OrRestart(Reg, Const, BranchLabel);
+      }
     } else {
       LOGMAN_THROW_A_FMT(false, "CondJump expected simple condition");
     }
   }
 
+  if (Backward) {
+    EmitSuspendInterruptCheck();
+    b_OrRestart(TrueTargetLabel);
+    BindOrRestart(&NotTaken);
+  }
+
   PendingTargetLabel = JumpTarget(Op->FalseBlock);
 }
 
--- a/FEXCore/Source/Interface/Core/JIT/JIT.cpp
+++ b/FEXCore/Source/Interface/Core/JIT/JIT.cpp
@@ -1081,6 +1081,7 @@
     .RIP = Entry,
     .GuestSize = Size,
     .SpinLockFutex = 0,
+    .SpillStackBytes = static_cast<uint32_t>(SpillSlots * MaxSpillSlotSize),
     .SingleInst = SingleInst,
   };
 
--- a/FEXCore/Source/Interface/Core/OpcodeDispatcher.cpp
+++ b/FEXCore/Source/Interface/Core/OpcodeDispatcher.cpp
@@ -799,7 +799,9 @@
     auto CondJump_ = CondJump(CondReg);
 
     // Taking branch block
-    if (TrueBlock != JumpTargets.end()) {
+    // Backward leaves through the target's entry: a check at this branch would see RCX already
+    // decremented with RIP still at this instruction, which a handler that moves the guest would rerun.
+    if (TrueBlock != JumpTargets.end() && Target > Op->PC) {
       SetTrueJumpTarget(CondJump_, TrueBlock->second.BlockEntry);
     } else {
       // Make sure to start a new block after ending this one
--- a/FEXCore/include/FEXCore/Core/Context.h
+++ b/FEXCore/include/FEXCore/Core/Context.h
@@ -86,6 +86,7 @@
   ///< State reconstruction helpers
   ///< Reconstructs the guest RIP from the passed in thread context and related Host PC.
   FEX_DEFAULT_VISIBILITY virtual uint64_t RestoreRIPFromHostPC(FEXCore::Core::InternalThreadState* Thread, uint64_t HostPC) = 0;
+  FEX_DEFAULT_VISIBILITY virtual uint32_t GetBlockStackBytesFromHostPC(FEXCore::Core::InternalThreadState* Thread, uint64_t HostPC) = 0;
   /**
    * @brief Reconstructs a compacted EFLAGS from FEX's internal EFLAG representation.
    *
--- a/Source/Tools/LinuxEmulation/ArchHelpers/MContext.h
+++ b/Source/Tools/LinuxEmulation/ArchHelpers/MContext.h
@@ -40,6 +40,8 @@
   FEXCore::x86_64::_libc_fpstate FPRState;
   uint64_t sa_mask;
   uint16_t InSyscallInfo;
+  // Host stack the interrupted JIT block has allocated.
+  uint32_t JITStackBytes;
   bool FaultToTopAndGeneratedException;
 
   // Guest state
@@ -67,6 +69,8 @@
   __uint128_t FPRs[32];
   uint64_t sa_mask;
   uint16_t InSyscallInfo;
+  // Host stack the interrupted JIT block has allocated.
+  uint32_t JITStackBytes;
   bool FaultToTopAndGeneratedException;
 
   // Guest state
@@ -182,16 +186,20 @@
 static inline uint64_t GetArmESR(void* ucontext) {
   auto MContext = GetMContext(ucontext);
 
-  size_t i = 0;
-  auto HostState = reinterpret_cast<HostCTXHeader*>(&MContext->__reserved[i]);
-  do {
-    if (HostState->Magic == ESR1_MAGIC) {
-      auto ESR = reinterpret_cast<HostESRState*>(HostState);
-      return ESR->ESR;
+  // Record sizes are in bytes and __reserved's elements are not. Stepping by index walks out of the signal
+  // frame, into whatever the stack last held, and past the end of the stack when it finds no terminator.
+  auto Records = reinterpret_cast<const uint8_t*>(&MContext->__reserved[0]);
+  size_t Offset = 0;
+  while (Offset + sizeof(HostCTXHeader) <= sizeof(MContext->__reserved)) {
+    auto HostState = reinterpret_cast<const HostCTXHeader*>(Records + Offset);
+    if (HostState->Magic == ESR1_MAGIC && Offset + sizeof(HostESRState) <= sizeof(MContext->__reserved)) {
+      return reinterpret_cast<const HostESRState*>(HostState)->ESR;
     }
-    i += HostState->Size;
-    HostState = reinterpret_cast<HostCTXHeader*>(&MContext->__reserved[i]);
-  } while (HostState->Size != 0);
+    if (HostState->Size == 0) {
+      break;
+    }
+    Offset += HostState->Size;
+  }
 
   return 0;
 }
@@ -223,10 +231,8 @@
                      ESR1_EC_DataAbort, GetESRName(ESR));
 
   uint32_t ProtectFlags {};
-  if ((ESR & ESR1_DataAbort_Level) == ESR1_DataAbort_Level_EL0) {
-    // Always a user error for us.
-    ProtectFlags |= FEXCore::X86State::X86_PF_USER;
-  }
+  // Always a user error for us, at any level of the page tables.
+  ProtectFlags |= FEXCore::X86State::X86_PF_USER;
 
   if (ESR & ESR1_WNR) {
     // Fault was due to a write
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator/GuestFramesManagement.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator/GuestFramesManagement.cpp
@@ -134,6 +134,9 @@
 
     // Hack! Go back to the top of the dispatcher top
     // This is only safe inside the JIT rather than anything outside of it
+    // The guest goes elsewhere: an interrupted syscall won't finish, and an interrupted block won't free its stack.
+    Frame->InSyscallInfo = 0;
+    ArchHelpers::Context::SetSp(ucontext, ArchHelpers::Context::GetSp(ucontext) + Context->JITStackBytes);
     ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
     ArchHelpers::Context::SetFillSRASingleInst(ucontext, false);
     // Set our state register to point to our guest thread data
@@ -213,6 +216,9 @@
   if (Context->OriginalRIP != guest_uctx->sc.ip || Context->FaultToTopAndGeneratedException) {
     // Hack! Go back to the top of the dispatcher top
     // This is only safe inside the JIT rather than anything outside of it
+    // The guest goes elsewhere: an interrupted syscall won't finish, and an interrupted block won't free its stack.
+    Frame->InSyscallInfo = 0;
+    ArchHelpers::Context::SetSp(ucontext, ArchHelpers::Context::GetSp(ucontext) + Context->JITStackBytes);
     ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
     ArchHelpers::Context::SetFillSRASingleInst(ucontext, false);
     // Set our state register to point to our guest thread data
@@ -291,6 +297,9 @@
 
     // Hack! Go back to the top of the dispatcher top
     // This is only safe inside the JIT rather than anything outside of it
+    // The guest goes elsewhere: an interrupted syscall won't finish, and an interrupted block won't free its stack.
+    Frame->InSyscallInfo = 0;
+    ArchHelpers::Context::SetSp(ucontext, ArchHelpers::Context::GetSp(ucontext) + Context->JITStackBytes);
     ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
     ArchHelpers::Context::SetFillSRASingleInst(ucontext, false);
     // Set our state register to point to our guest thread data
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
@@ -81,12 +81,34 @@
                       FHU::Syscalls::gettid());
   } else {
     SignalHandler& Handler = HostHandlers[Signal];
+    // These handlers enter signal-deferring sections, whose ends touch the page a waiting signal has protected,
+    // and the fault that would make cannot be taken in here.
+    // A required signal can nest in one of these, so only the outermost closes the page again.
+    auto& Exact = Thread->SignalInfo;
+    const bool OpenCheckPage = (Exact.WaitingForExactState || !Exact.DeferredSignalFrames.empty()) &&
+                               static_cast<siginfo_t*>(Info)->si_addr != reinterpret_cast<void*>(&Thread->Thread->InterruptFaultPage);
+    if (OpenCheckPage && Exact.CheckPageOpenDepth++ == 0) {
+      mprotect(reinterpret_cast<void*>(&Thread->Thread->InterruptFaultPage), sizeof(Thread->Thread->InterruptFaultPage), PROT_READ | PROT_WRITE);
+    }
+    bool Handled = false;
     for (auto& HandlerFunc : Handler.Handlers) {
       if (HandlerFunc(Thread->Thread, Signal, Info, UContext)) {
         // If the host handler handled the fault then we can continue now
-        return;
+        Handled = true;
+        break;
       }
+    }
+    if (OpenCheckPage && --Exact.CheckPageOpenDepth == 0 && (Exact.WaitingForExactState || !Exact.DeferredSignalFrames.empty()) &&
+        mprotect(reinterpret_cast<void*>(&Thread->Thread->InterruptFaultPage), sizeof(Thread->Thread->InterruptFaultPage), PROT_NONE) != 0 &&
+        Exact.WaitingForExactState) {
+      // Nothing would end the wait now, so it ends here, and the signal comes back wherever this resumes.
+      auto& [HostMaskValues] = static_cast<ucontext_t*>(UContext)->uc_sigmask;
+      HostMaskValues[0] = Exact.MaskBeforeWaiting;
+      Exact.WaitingForExactState = false;
     }
+    if (Handled) {
+      return;
+    }
 
     if (Handler.FrontendHandler && Handler.FrontendHandler(Thread->Thread, Signal, Info, UContext)) {
       return;
@@ -136,6 +158,8 @@
 #endif
 }
 
+static bool IsAsyncSignal(const siginfo_t* Info, int Signal);
+
 ArchHelpers::Context::ContextBackup* SignalDelegator::StoreThreadState(FEXCore::Core::InternalThreadState* Thread, int Signal, void* ucontext) {
   // We can end up getting a signal at any point in our host state
   // Jump to a handler that saves all state so we can safely return
@@ -171,6 +195,7 @@
   Context->UContextLocation = 0;
   Context->SigInfoLocation = 0;
   Context->InSyscallInfo = 0;
+  Context->JITStackBytes = 0;
 
   // Store fault to top status and then reset it
   Context->FaultToTopAndGeneratedException = Thread->CurrentFrame->SynchronousFaultData.FaultToTopAndGeneratedException;
@@ -316,10 +341,12 @@
     SpillSRA(Thread, ucontext, IgnoreMask);
 
     ContextBackup->Flags |= ArchHelpers::Context::ContextFlags::CONTEXT_FLAG_INJIT;
-
-    // We are leaving the syscall information behind. Make sure to store the previous state.
-    ContextBackup->InSyscallInfo = Thread->CurrentFrame->InSyscallInfo;
-    Thread->CurrentFrame->InSyscallInfo = 0;
+    // At a check or a synchronous fault the block has its stack. Anywhere else it may not, as in its first
+    // or last instructions, where only an undelivered signal's fallback can land.
+    if (Frame->InSyscallInfo == 0 && (FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread)->SignalInfo.AtCheck ||
+                                      !IsAsyncSignal(static_cast<const siginfo_t*>(info), Signal))) {
+      ContextBackup->JITStackBytes = CTX->GetBlockStackBytesFromHostPC(Thread, OldPC);
+    }
   } else {
     if (!IsAddressInDispatcher(OldPC)) {
       // This is likely to cause issues but in some cases it isn't fatal
@@ -333,6 +360,12 @@
     }
   }
 
+  // We are leaving the syscall information behind. Make sure to store the previous state, also for a signal
+  // that arrived in the syscall handler rather than the JIT: the guest handler runs outside the syscall, and
+  // the interrupted syscall is still in progress after it returns.
+  ContextBackup->InSyscallInfo = Thread->CurrentFrame->InSyscallInfo;
+  Thread->CurrentFrame->InSyscallInfo = 0;
+
   uint64_t OldGuestSP = Frame->State.gregs[FEXCore::X86State::REG_RSP];
   uint64_t NewGuestSP = OldGuestSP;
 
@@ -407,6 +440,8 @@
   if (ArchHelpers::Context::GetPc(ucontext) == Config.SignalHandlerReturnAddress ||
       ArchHelpers::Context::GetPc(ucontext) == Config.SignalHandlerReturnAddressRT) {
     auto ThreadObject = FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread);
+    // This restores the interrupted context's mask, and whatever was waiting comes back under that.
+    FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread)->SignalInfo.WaitingForExactState = false;
     RestoreThreadState(Thread, ucontext,
                        ArchHelpers::Context::GetPc(ucontext) == Config.SignalHandlerReturnAddressRT ? RestoreType::TYPE_REALTIME :
                                                                                                       RestoreType::TYPE_NONREALTIME);
@@ -547,6 +582,19 @@
   return true;
 }
 
+uint64_t SignalDelegator::GetWaitBlockableSignals() const {
+  // Signals that can be synchronous stay unblocked: the kernel kills a thread for a blocked synchronous one.
+  // So do the ones FEX requires, whichever have registered by now: this also runs while they register.
+  uint64_t Mask = ~((1ULL << (SIGILL - 1)) | (1ULL << (SIGSEGV - 1)) | (1ULL << (SIGBUS - 1)) | (1ULL << (SIGTRAP - 1)) |
+                    (1ULL << (SIGFPE - 1)) | (1ULL << (SIGSYS - 1)) | (1ULL << (SIGNAL_FOR_PAUSE - 1)));
+  for (size_t i = 0; i < MAX_SIGNALS; ++i) {
+    if (HostHandlers[i + 1].Required.load(std::memory_order_relaxed)) {
+      Mask &= ~(1ULL << i);
+    }
+  }
+  return Mask;
+}
+
 uint64_t SignalDelegator::GetNewSigMask(int Signal) const {
   const SignalHandler& Handler = HostHandlers[Signal];
   // Set up a new mask based on this signals signal mask
@@ -595,6 +643,62 @@
   auto SigInfo = *static_cast<siginfo_t*>(Info);
 
   auto MustDeferSignal = (Thread->CurrentFrame->State.DeferredSignalRefCount.Load() != 0);
+  // Outside a system call the guest state FEX can show a handler is not exact. Inside a block it can only
+  // name the instruction a signal interrupted, and that instruction may be half done. In the dispatcher
+  // the guest registers are in host registers and the saved copies are stale, and a linked block's RIP is not
+  // written yet. That is enough for a handler that returns, since the host context resumes exactly, but not
+  // for one that moves the guest, as Go's asynchronous preemption does.
+  //
+  // So such a signal goes back to the kernel, stays blocked, and arrives again at the next check at a block
+  // entry or loop edge, or at the start of a system call. The kernel keeps its payload and mask. Only two
+  // realtime signals of one number queued to this thread can change order: the first goes behind the second.
+  auto& Exact = ThreadObject->SignalInfo;
+  const uint64_t HostPC = ArchHelpers::Context::GetPc(UContext);
+  // Good for one delivery: the code buffer can be reused, and any further signal comes through the check again.
+  Exact.AtCheck = HostPC == Exact.ExactStatePC;
+  Exact.ExactStatePC = 0;
+  auto& [HostMaskValues] = _context->uc_sigmask;
+  static_assert(sizeof(HostMaskValues[0]) == sizeof(uint64_t), "Unknown sigset_t layout");
+  if (Exact.WaitingForExactState && Signal == SIGSEGV && SigInfo.si_code == SEGV_ACCERR &&
+      SigInfo.si_addr == reinterpret_cast<void*>(&Thread->InterruptFaultPage)) {
+    // The end of a signal-deferring section in the dispatcher or in FEX itself also lands here.
+    if (MustDeferSignal || (Thread->CurrentFrame->InSyscallInfo == 0 && !CTX->IsAddressInCodeBuffer(Thread, HostPC))) {
+      ArchHelpers::Context::SetPc(UContext, HostPC + 4);
+      return;
+    }
+    HostMaskValues[0] = Exact.MaskBeforeWaiting;
+    Exact.WaitingForExactState = false;
+    // A signal that arrives here, as the kernel returns to this check, sees the exact state.
+    Exact.ExactStatePC = HostPC;
+    mprotect(reinterpret_cast<void*>(&Thread->InterruptFaultPage), sizeof(Thread->InterruptFaultPage), PROT_READ | PROT_WRITE);
+    return;
+  }
+  const uint64_t Blockable = GetWaitBlockableSignals();
+  // Already waiting and still unblocked means the mask was replaced since, so the new mask is the one to keep.
+  if (IsAsyncSignal(&SigInfo, Signal) && (Blockable & (1ULL << (Signal - 1)))) {
+    const auto TargetFunction = HostHandlers[Signal].GuestAction.sigaction_handler.handler;
+    const bool GuestWillRunHandler = TargetFunction != SIG_DFL && TargetFunction != SIG_IGN &&
+                                     !(ThreadObject->SignalInfo.CurrentSignalMask.Val & (1ULL << (Signal - 1)));
+    if (MustDeferSignal || (GuestWillRunHandler && Thread->CurrentFrame->InSyscallInfo == 0 && !Exact.AtCheck)) {
+      const int SavedErrno = errno;
+      // The page first: once the signal is queued it must not be handled here as well, and without a protected
+      // page nothing would ever end the wait.
+      if (mprotect(reinterpret_cast<void*>(&Thread->InterruptFaultPage), sizeof(Thread->InterruptFaultPage), PROT_NONE) == 0) {
+        if (::syscall(SYS_rt_tgsigqueueinfo, ::getpid(), FHU::Syscalls::gettid(), Signal, &SigInfo) == 0) {
+          Exact.MaskBeforeWaiting = HostMaskValues[0];
+          HostMaskValues[0] |= Blockable;
+          Exact.WaitingForExactState = true;
+          return;
+        }
+        if (!Exact.WaitingForExactState) {
+          mprotect(reinterpret_cast<void*>(&Thread->InterruptFaultPage), sizeof(Thread->InterruptFaultPage), PROT_READ | PROT_WRITE);
+        }
+      }
+      // No memory for the page's mapping, or the kernel's queue is full. What follows handles it as before,
+      // inexact as that may be.
+      errno = SavedErrno;
+    }
+  }
   if (Signal == SIGSEGV && SigInfo.si_code == SEGV_ACCERR && SigInfo.si_addr == reinterpret_cast<void*>(&Thread->InterruptFaultPage)) {
     if (!MustDeferSignal) {
       // We just reached the end of the outermost signal-deferring section and faulted to check for pending signals.
@@ -648,6 +752,11 @@
     auto& [sigmask_val] = _context->uc_sigmask;
     static_assert(sizeof(sigmask_val[0]) == sizeof(uint64_t), "Unknown sigset_t layout");
 
+    if (Exact.WaitingForExactState) {
+      // The mask that frame saves must be the guest's, and the check below now serves both.
+      sigmask_val[0] = Exact.MaskBeforeWaiting;
+      Exact.WaitingForExactState = false;
+    }
     ThreadObject->SignalInfo.DeferredSignalFrames.emplace_back(ThreadStateObject::DeferredSignalState {
       .Info = SigInfo,
       .Signal = Signal,
@@ -688,6 +797,13 @@
   } else if (Handler.GuestAction.sigaction_handler.handler == SIG_IGN) {
     return;
   } else {
+    if (Exact.WaitingForExactState) {
+      // A synchronous fault cannot wait for the check. Its handler must see the mask the guest set, and the
+      // signal that was waiting comes back through the kernel as this handler's mask allows.
+      HostMaskValues[0] = Exact.MaskBeforeWaiting;
+      Exact.WaitingForExactState = false;
+      mprotect(reinterpret_cast<void*>(&Thread->InterruptFaultPage), sizeof(Thread->InterruptFaultPage), PROT_READ | PROT_WRITE);
+    }
     if (Handler.GuestHandler &&
         Handler.GuestHandler(Thread, Signal, &SigInfo, UContext, &Handler.GuestAction, &ThreadObject->SignalInfo.GuestAltStack)) {
       uint64_t NewMask = GetNewSigMask(Signal);
@@ -796,6 +912,10 @@
 
   // Walk the signals we have that are required and make sure to remove it from the mask
   // This'll likely be SIGILL, SIGBUS, SIG63
+
+  // Nothing nests in a host handler but a synchronous fault: a signal that did would see the handler's mask as the
+  // guest's, and could interrupt the signal state it is changing. The guest's sa_mask applies from GetNewSigMask.
+  SignalHandler.HostAction.sa_mask = GetWaitBlockableSignals();
 
   // If the guest has masked some signals then we need to also mask those signals
   for (size_t i = 1; i < HostHandlers.size(); ++i) {
@@ -1020,6 +1140,9 @@
   // Copy the thread object to the start of the alt-stack
   memcpy(Thread->SignalInfo.AltStackPtr, &Thread, sizeof(void*));
 
+  // Get the current host signal mask, before a signal can arrive on the alt stack and change it.
+  ::syscall(SYS_rt_sigprocmask, 0, nullptr, &Thread->SignalInfo.CurrentSignalMask.Val, 8);
+
   // Protect the first page of the alt-stack for overflow protection.
   mprotect(Thread->SignalInfo.AltStackPtr, FEXCore::Utils::FEX_PAGE_SIZE, PROT_READ);
 
@@ -1029,9 +1152,6 @@
     LogMan::Msg::EFmt("Failed to install alternative signal stack {}", strerror(errno));
   }
 
-  // Get the current host signal mask
-  ::syscall(SYS_rt_sigprocmask, 0, nullptr, &Thread->SignalInfo.CurrentSignalMask.Val, 8);
-
   if (Thread->Thread) {
     // Reserve a small amount of deferred signal frames. Usually the stack won't be utilized beyond
     // 1 or 2 signals but add a few more just in case.
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.h
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.h
@@ -292,6 +292,7 @@
   bool HandleSIGILL(FEXCore::Core::InternalThreadState* Thread, int Signal, void* info, void* ucontext);
 
   uint64_t GetNewSigMask(int Signal) const;
+  uint64_t GetWaitBlockableSignals() const;
 };
 
 fextl::unique_ptr<FEX::HLE::SignalDelegator>
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls/Thread.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls/Thread.cpp
@@ -32,6 +32,7 @@
 #include <linux/sched.h>
 #include <stdint.h>
 #include <sched.h>
+#include <sys/stat.h>
 #include <sys/personality.h>
 #include <poll.h>
 #include <sys/prctl.h>
@@ -204,6 +205,9 @@
     // Frame->Thread is /ONLY/ safe to access when CLONE_THREAD flag is not set
     // Unlock the mutexes on both sides of the fork
     FEX::HLE::_SyscallHandler->UnlockAfterFork(Frame->Thread, true);
+
+    // The clone call that was in progress ends here, in the child.
+    Thread->Thread->CurrentFrame->InSyscallInfo = 0;
 
     ::syscall(SYS_rt_sigprocmask, SIG_SETMASK, &CloneArgs->SignalMask, nullptr, sizeof(CloneArgs->SignalMask));
 
@@ -308,6 +312,27 @@
   const bool IsChild = Result == 0;
 
   if (IsChild) {
+    // Only a vfork child ends its parent's wait, not a process it forks in turn: busybox's `timeout` runs
+    // its watcher that way, and the parent would wait for the watcher. The guest may have closed the pipe
+    // already, and its descriptor number may mean something else by now.
+    static struct {
+      int FD {-1};
+      dev_t Device;
+      ino_t Inode;
+    } VForkWriteEnd;
+    struct stat Pipe {};
+    // A child that shares the descriptor table would close it for the vfork child too.
+    if (!(flags & CLONE_FILES)) {
+      if (VForkWriteEnd.FD != -1 && ::fstat(VForkWriteEnd.FD, &Pipe) == 0 && Pipe.st_dev == VForkWriteEnd.Device &&
+          Pipe.st_ino == VForkWriteEnd.Inode) {
+        ::close(VForkWriteEnd.FD);
+      }
+      VForkWriteEnd.FD = -1;
+    }
+    if (IsVFork && ::fstat(VForkFDs[1], &Pipe) == 0) {
+      VForkWriteEnd = {VForkFDs[1], Pipe.st_dev, Pipe.st_ino};
+    }
+
     auto ThreadObject = static_cast<FEX::HLE::ThreadStateObject*>(Thread->FrontendPtr);
     // Unlock the mutexes on both sides of the fork
     FEX::HLE::_SyscallHandler->UnlockAfterFork(Frame->Thread, IsChild);
@@ -449,6 +474,10 @@
                         }));
 
   REGISTER_SYSCALL_IMPL(exit, [](FEXCore::Core::CpuStateFrame* Frame, int status) -> uint64_t {
+    // No guest handler runs from here on, as with the kernel's own exit, and the state it needs goes away.
+    // Faults stay unblocked: FEX recovers from one when a write lands on a code page it protects.
+    const uint64_t AllSignals = ~((1ULL << (SIGSEGV - 1)) | (1ULL << (SIGBUS - 1)) | (1ULL << (SIGILL - 1)));
+    ::syscall(SYS_rt_sigprocmask, SIG_SETMASK, &AllSignals, nullptr, sizeof(AllSignals));
     // TLS/DTV teardown is something FEX can't control. Disable glibc checking when we leave a pthread.
     // Since this thread is hard stopping, we can't track the TLS/DTV teardown in FEX's thread handling.
     FEXCore::Allocator::YesIKnowImNotSupposedToUseTheGlibcAllocator::HardDisable();
@@ -566,6 +595,10 @@
   });
 
   REGISTER_SYSCALL_IMPL(exit_group, [](FEXCore::Core::CpuStateFrame* Frame, int status) -> uint64_t {
+    // No guest handler runs from here on, as with the kernel's own exit, and the state it needs goes away.
+    // Faults stay unblocked: FEX recovers from one when a write lands on a code page it protects.
+    const uint64_t AllSignals = ~((1ULL << (SIGSEGV - 1)) | (1ULL << (SIGBUS - 1)) | (1ULL << (SIGILL - 1)));
+    ::syscall(SYS_rt_sigprocmask, SIG_SETMASK, &AllSignals, nullptr, sizeof(AllSignals));
     Frame->Thread->CTX->FlushAndCloseCodeMap();
 
     // Save telemetry if we're exiting.
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls.cpp
@@ -897,6 +897,10 @@
 void SyscallHandler::HandleSyscall(FEXCore::Core::CpuStateFrame* Frame) {
   // Grab the return address which will be inside the JIT.
   const uint64_t JITPC = reinterpret_cast<uint64_t>(__builtin_extract_return_addr(__builtin_return_address(0)));
+  // Take any signal still waiting for an exact state: the guest state is written back here, and the
+  // call may block with that signal masked.
+  reinterpret_cast<FEXCore::Core::NonAtomicRefCounter<uint64_t>*>(&FEX::HLE::ThreadManager::GetStateObjectFromCPUState(Frame)->Thread->InterruptFaultPage)
+    ->Store(0);
   const auto Is64Bit = Is64BitMode();
 
   // TODO: At some point these will be runtime selectable based on `syscall` versus `int 0x80` entrypoint.
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/ThreadManager.h
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/ThreadManager.h
@@ -83,6 +83,12 @@
     // Queue of thread local signal frames that have been deferred.
     // Async signals aren't guaranteed to be delivered in any particular order, but FEX treats them as FILO.
     fextl::vector<DeferredSignalState> DeferredSignalFrames;
+    // A signal went back to the kernel until the guest state is exact. See HandleGuestSignal.
+    bool WaitingForExactState {};
+    bool AtCheck {};
+    uint32_t CheckPageOpenDepth {};
+    uint64_t MaskBeforeWaiting {};
+    uint64_t ExactStatePC {};
   } SignalInfo {};
 
   // Seccomp thread specific data.
--- a/FEXCore/Source/Interface/Core/Dispatcher/Dispatcher.cpp
+++ b/FEXCore/Source/Interface/Core/Dispatcher/Dispatcher.cpp
@@ -546,6 +546,13 @@
     // We can safely claim we are no longer in a syscall
     str(ARMEmitter::XReg::zr, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));
 
+    ARMEmitter::ForwardLabel l_KeepStack;
+    ldr(TMP1, STATE, offsetof(FEXCore::Core::CpuStateFrame, PendingHostSP));
+    (void)cbz(ARMEmitter::Size::i64Bit, TMP1, &l_KeepStack);
+    add(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::rsp, TMP1, 0);
+    str(ARMEmitter::XReg::zr, STATE, offsetof(FEXCore::Core::CpuStateFrame, PendingHostSP));
+    (void)Bind(&l_KeepStack);
+
     // Now go back to the regular dispatcher loop
     (void)b(&LoopTop);
   }
--- a/FEXCore/Source/Interface/Core/JIT/BranchOps.cpp
+++ b/FEXCore/Source/Interface/Core/JIT/BranchOps.cpp
@@ -254,7 +254,7 @@
   // only when taken. REP SCAS and REP CMPS branch inside the instruction: a guest restarted from a check on the path out
   // would go on searching after a match, while on the way back round all the instruction's state is written and it can restart.
   // Inverting the branch keeps the loop's path to one taken branch.
-  const bool Backward = TrueTargetLabel->Backward.Location != nullptr;
+  const bool Backward = TrueTargetLabel->Backward.Location != nullptr && !Op->NoSuspendCheck;
   ARMEmitter::BiDirectionalLabel NotTaken;
   auto BranchLabel = Backward ? &NotTaken : TrueTargetLabel;
 
@@ -314,6 +314,7 @@
 }
 
 DEF_OP(Syscall) {
+  ResetStack();
   SpillStaticRegs(TMP1);
 
   // Jump to the syscall dispatch handler. We won't return after this.
@@ -405,6 +406,7 @@
 DEF_OP(ThreadRemoveCodeEntry) {
   auto Op = IROp->C<IR::IROp_ThreadRemoveCodeEntry>();
 
+  ResetStack();
   SpillStaticRegs(TMP1);
 
   // Store the new RIP to go to.
--- a/FEXCore/Source/Interface/Core/JIT/JITClass.h
+++ b/FEXCore/Source/Interface/Core/JIT/JITClass.h
@@ -64,6 +64,7 @@
   }
 
 private:
+  void EmitBreak(const IR::BreakDefinition& Reason);
   const bool HostSupportsSVE128 {};
   const bool HostSupportsSVE256 {};
   const bool HostSupportsAVX256 {};
--- a/FEXCore/Source/Interface/Core/JIT/MiscOps.cpp
+++ b/FEXCore/Source/Interface/Core/JIT/MiscOps.cpp
@@ -13,6 +13,8 @@
 #include "Interface/Core/JIT/DebugData.h"
 #include "Interface/Core/JIT/JITClass.h"
 
+#include <csignal>
+
 #include <FEXCore/Core/SignalDelegator.h>
 #include <FEXCore/Debug/InternalThreadState.h>
 #include <FEXCore/Utils/EnumUtils.h>
@@ -56,18 +58,16 @@
   }
 }
 
-DEF_OP(Break) {
-  auto Op = IROp->C<IR::IROp_Break>();
-
+void Arm64JITCore::EmitBreak(const IR::BreakDefinition& Reason) {
   // First we must reset the stack
   ResetStack();
 
   Core::CpuStateFrame::SynchronousFaultDataStruct State = {
     .FaultToTopAndGeneratedException = 1,
-    .Signal = Op->Reason.Signal,
-    .TrapNo = Op->Reason.TrapNumber,
-    .si_code = Op->Reason.si_code,
-    .err_code = Op->Reason.ErrorRegister,
+    .Signal = Reason.Signal,
+    .TrapNo = Reason.TrapNumber,
+    .si_code = Reason.si_code,
+    .err_code = Reason.ErrorRegister,
   };
 
   uint64_t Constant {};
@@ -76,7 +76,9 @@
   LoadConstant(ARMEmitter::Size::i64Bit, TMP1, Constant);
   str(TMP1, STATE, offsetof(FEXCore::Core::CpuStateFrame, SynchronousFaultData));
 
-  switch (Op->Reason.Signal) {
+  switch (Reason.Signal) {
+  // The guest's divide error goes the same way: SIGILL always has a host handler, and SIGTRAP only with a guest's.
+  case SIGFPE:
   case Core::FAULT_SIGILL:
     ldr(TMP1, STATE, offsetof(FEXCore::Core::CpuStateFrame, Pointers.GuestSignal_SIGILL));
     br(TMP1);
@@ -96,6 +98,19 @@
   }
 }
 
+DEF_OP(Break) {
+  auto Op = IROp->C<IR::IROp_Break>();
+  EmitBreak(Op->Reason);
+}
+
+DEF_OP(BreakIfNonZero) {
+  auto Op = IROp->C<IR::IROp_BreakIfNonZero>();
+  ARMEmitter::ForwardLabel Continue {};
+  (void)cbz(ARMEmitter::Size::i64Bit, GetReg(Op->Value), &Continue);
+  EmitBreak(Op->Reason);
+  (void)Bind(&Continue);
+}
+
 DEF_OP(GetRoundingMode) {
   auto Dst = GetReg(Node);
   mrs(Dst, ARMEmitter::SystemRegister::FPCR);
--- a/FEXCore/Source/Interface/Core/OpcodeDispatcher.cpp
+++ b/FEXCore/Source/Interface/Core/OpcodeDispatcher.cpp
@@ -3435,7 +3435,9 @@
         _CondSubNZCV(OpSize::i64Bit, Src2, Src1, CondClass::NEQ, REPE ? 0 : (1 << 2) /* Z */);
         CachedNZCV = nullptr;
         NZCVDirty = false;
-        InnerJump = CondJumpNZCV(REPE ? CondClass::EQ : CondClass::NEQ);
+        // PF and AF hold this loop's operands until it ends, so a signal shown this state would see wrong flags.
+        // The loop is bounded by RCX, and a signal waits for the check after it.
+        InnerJump = CondJumpNZCV(REPE ? CondClass::EQ : CondClass::NEQ, true);
 
         // Jump back to the start if we have more work to do
         SetTrueJumpTarget(InnerJump, LoopHeader);
@@ -3714,7 +3716,25 @@
     Ref Result = CalculateFlags_SUB(Size, ZeroConst, Dest);
 
     StoreResultGPR(Op, Result);
+  }
+}
+
+void OpDispatchBuilder::RaiseDivideErrorIf(OpcodeArgs, Ref Condition) {
+  // x86 faults here, leaving its registers alone. arm64's division just gives an answer, so without this a division by
+  // zero would return 0 where .NET and the JVM count on the fault for their exceptions.
+  CalculateDeferredFlags();
+  FlushRegisterCache();
+  if (CurrentHeader->HasX87) {
+    // x87 state is only written out at the end of a block, and a handler sees it and returns to it.
+    _SyncStackToSlow();
   }
+  _StoreContextGPR(GetGPROpSize(), GetRelocatedPC(Op, -Op->InstSize), offsetof(FEXCore::Core::CPUState, rip));
+  _BreakIfNonZero(Condition, FEXCore::IR::BreakDefinition {
+                               .ErrorRegister = 0,
+                               .Signal = SIGFPE,
+                               .TrapNumber = X86State::X86_TRAPNO_DE,
+                               .si_code = 1, ///< FPE_INTDIV
+                             });
 }
 
 void OpDispatchBuilder::DIVOp(OpcodeArgs) {
@@ -3730,12 +3750,14 @@
     return;
   }
 
-  Ref Quotient = _AllocateGPR(true);
-  Ref Remainder = _AllocateGPR(true);
-
+  // An unsigned quotient fits exactly when the dividend's upper half is below the divisor, which also rules out zero.
   if (Size == OpSize::i8Bit) {
     Ref Src1 = LoadGPRRegister(X86State::REG_RAX, OpSize::i16Bit);
 
+    RaiseDivideErrorIf(Op, _Select(OpSize::i32Bit, OpSize::i32Bit, CondClass::UGE, _Bfe(OpSize::i32Bit, 8, 8, Src1), Divisor, Constant(1), Constant(0)));
+
+    Ref Quotient = _AllocateGPR(true);
+    Ref Remainder = _AllocateGPR(true);
     _UDiv(OpSize::i16Bit, Src1, Invalid(), Divisor, Quotient, Remainder);
 
     // AX[15:0] = concat<URem[7:0]:UDiv[7:0]>
@@ -3745,6 +3767,12 @@
     Ref Src1 = LoadGPRRegister(X86State::REG_RAX);
     Ref Src2 = LoadGPRRegister(X86State::REG_RDX);
 
+    Ref Upper = Size == OpSize::i16Bit ? _Bfe(OpSize::i32Bit, 16, 0, Src2) : Src2;
+    const auto CompareSize = Size == OpSize::i64Bit ? OpSize::i64Bit : OpSize::i32Bit;
+    RaiseDivideErrorIf(Op, _Select(OpSize::i32Bit, CompareSize, CondClass::UGE, Upper, Divisor, Constant(1), Constant(0)));
+
+    Ref Quotient = _AllocateGPR(true);
+    Ref Remainder = _AllocateGPR(true);
     _UDiv(Size, Src1, Src2, Divisor, Quotient, Remainder);
 
     if (Size == OpSize::i32Bit) {
@@ -3759,11 +3787,9 @@
 }
 
 void OpDispatchBuilder::IDIVOp(OpcodeArgs) {
-  // This loads the divisor
-  Ref Divisor = LoadSourceGPR(Op, Op->Dest, Op->Flags);
-
   const auto GPRSize = GetGPROpSize();
   auto Size = OpSizeFromSrc(Op);
+  Ref ExitBlock = nullptr;
 
   if (Size == OpSize::i64Bit && !Is64BitMode) {
     LogMan::Msg::EFmt("Doesn't exist in 32bit mode");
@@ -3771,16 +3797,66 @@
     return;
   }
 
-  Ref Quotient = _AllocateGPR(true);
-  Ref Remainder = _AllocateGPR(true);
+  if (Size == OpSize::i64Bit) {
+    // Almost every dividend here is 64 bits sign-extended, by CQO. For a real 128-bit one, whether the quotient fits
+    // takes dividing the magnitudes, which fit an unsigned division only below the divisor's. Rare enough for a block,
+    // which finishes the division itself: x86 reads its divisor once, and another thread could change it.
+    Ref Lower = LoadGPRRegister(X86State::REG_RAX);
+    Ref Upper = LoadGPRRegister(X86State::REG_RDX);
+    auto LongBlock = CreateNewCodeBlockAfter(GetCurrentBlock());
+    auto DivideBlock = CreateNewCodeBlockAfter(LongBlock);
+    ExitBlock = CreateNewCodeBlockAfter(DivideBlock);
+    CalculateDeferredFlags();
+    CondJump(_Xor(OpSize::i64Bit, Upper, _Sbfe(OpSize::i64Bit, 1, 63, Lower)), Constant(0), LongBlock, DivideBlock, CondClass::NEQ, OpSize::i64Bit);
+
+    SetCurrentCodeBlock(LongBlock);
+    StartNewBlock();
+    {
+      Ref Divisor = LoadSourceGPR(Op, Op->Dest, Op->Flags);
+      Lower = LoadGPRRegister(X86State::REG_RAX);
+      Upper = LoadGPRRegister(X86State::REG_RDX);
+      Ref DividendSign = _Sbfe(OpSize::i64Bit, 1, 63, Upper);
+      Ref DivisorSign = _Sbfe(OpSize::i64Bit, 1, 63, Divisor);
+      Ref MagnitudeLower = _Sub(OpSize::i64Bit, _Xor(OpSize::i64Bit, Lower, DividendSign), DividendSign);
+      Ref Carry = _Select(OpSize::i64Bit, OpSize::i64Bit, CondClass::EQ, MagnitudeLower, Constant(0), _And(OpSize::i64Bit, DividendSign, Constant(1)), Constant(0));
+      Ref MagnitudeUpper = _Add(OpSize::i64Bit, _Xor(OpSize::i64Bit, Upper, DividendSign), Carry);
+      Ref MagnitudeDivisor = _Sub(OpSize::i64Bit, _Xor(OpSize::i64Bit, Divisor, DivisorSign), DivisorSign);
+      RaiseDivideErrorIf(Op, _Select(OpSize::i32Bit, OpSize::i64Bit, CondClass::UGE, MagnitudeUpper, MagnitudeDivisor, Constant(1), Constant(0)));
 
+      Ref Quotient = _AllocateGPR(true);
+      Ref Remainder = _AllocateGPR(true);
+      _UDiv(OpSize::i64Bit, MagnitudeLower, MagnitudeUpper, MagnitudeDivisor, Quotient, Remainder);
+
+      // 2^63 fits only as a negative result.
+      Ref Negative = _Xor(OpSize::i64Bit, DividendSign, DivisorSign);
+      Ref Limit = _Add(OpSize::i64Bit, Constant(0x7FFF'FFFF'FFFF'FFFFULL), _And(OpSize::i64Bit, Negative, Constant(1)));
+      RaiseDivideErrorIf(Op, _Select(OpSize::i32Bit, OpSize::i64Bit, CondClass::UGT, Quotient, Limit, Constant(1), Constant(0)));
+
+      StoreGPRRegister(X86State::REG_RAX, _Sub(OpSize::i64Bit, _Xor(OpSize::i64Bit, Quotient, Negative), Negative), OpSize::i64Bit);
+      StoreGPRRegister(X86State::REG_RDX, _Sub(OpSize::i64Bit, _Xor(OpSize::i64Bit, Remainder, DividendSign), DividendSign), OpSize::i64Bit);
+      Jump(ExitBlock);
+    }
+
+    SetCurrentCodeBlock(DivideBlock);
+    StartNewBlock();
+  }
+
+  // This loads the divisor
+  Ref Divisor = LoadSourceGPR(Op, Op->Dest, Op->Flags);
+
   if (Size == OpSize::i8Bit) {
     Ref Src1 = LoadGPRRegister(X86State::REG_RAX);
     Src1 = _Sbfe(OpSize::i64Bit, 16, 0, Src1);
     Divisor = _Sbfe(OpSize::i64Bit, 8, 0, Divisor);
+
+    RaiseDivideErrorIf(Op, _Select(OpSize::i32Bit, OpSize::i64Bit, CondClass::EQ, Divisor, Constant(0), Constant(1), Constant(0)));
 
+    Ref Quotient = _AllocateGPR(true);
+    Ref Remainder = _AllocateGPR(true);
     _Div(OpSize::i64Bit, Src1, Invalid(), Divisor, Quotient, Remainder);
 
+    RaiseDivideErrorIf(Op, _Select(OpSize::i32Bit, OpSize::i64Bit, CondClass::NEQ, _Sbfe(OpSize::i64Bit, 8, 0, Quotient), Quotient, Constant(1), Constant(0)));
+
     // AX[15:0] = concat<URem[7:0]:UDiv[7:0]>
     auto ResultAX = _Bfi(GPRSize, 8, 8, Quotient, Remainder);
     StoreGPRRegister(X86State::REG_RAX, ResultAX, OpSize::i16Bit);
@@ -3788,8 +3864,26 @@
     Ref Src1 = LoadGPRRegister(X86State::REG_RAX);
     Ref Src2 = LoadGPRRegister(X86State::REG_RDX);
 
+    const auto CompareSize = Size == OpSize::i64Bit ? OpSize::i64Bit : OpSize::i32Bit;
+    Ref DivideError = _Select(OpSize::i32Bit, CompareSize, CondClass::EQ, Divisor, Constant(0), Constant(1), Constant(0));
+    if (Size == OpSize::i64Bit) {
+      // The dividend is its lower half sign-extended here, so the one quotient that does not fit is the minimum by -1.
+      Ref Differs = _Or(OpSize::i64Bit, _Xor(OpSize::i64Bit, Src1, Constant(0x8000'0000'0000'0000ULL)), _Add(OpSize::i64Bit, Divisor, Constant(1)));
+      DivideError = _Select(OpSize::i32Bit, OpSize::i64Bit, CondClass::EQ, Differs, Constant(0), Constant(1), DivideError);
+    }
+    RaiseDivideErrorIf(Op, DivideError);
+
+    Ref Quotient = _AllocateGPR(true);
+    Ref Remainder = _AllocateGPR(true);
     _Div(Size, Src1, Src2, Divisor, Quotient, Remainder);
 
+    // The smaller sizes divide in a wider register, so the quotient shows whether it fits.
+    if (Size == OpSize::i16Bit) {
+      RaiseDivideErrorIf(Op, _Select(OpSize::i32Bit, OpSize::i32Bit, CondClass::NEQ, _Sbfe(OpSize::i32Bit, 16, 0, Quotient), Quotient, Constant(1), Constant(0)));
+    } else if (Size == OpSize::i32Bit) {
+      RaiseDivideErrorIf(Op, _Select(OpSize::i32Bit, OpSize::i64Bit, CondClass::NEQ, _Sbfe(OpSize::i64Bit, 32, 0, Quotient), Quotient, Constant(1), Constant(0)));
+    }
+
     if (Size == OpSize::i32Bit) {
       Quotient = _Bfe(OpSize::i32Bit, IR::OpSizeAsBits(Size), 0, Quotient);
       Remainder = _Bfe(OpSize::i32Bit, IR::OpSizeAsBits(Size), 0, Remainder);
@@ -3799,6 +3893,12 @@
     StoreGPRRegister(X86State::REG_RAX, Quotient, Size);
     StoreGPRRegister(X86State::REG_RDX, Remainder, Size);
   }
+
+  if (ExitBlock) {
+    Jump(ExitBlock);
+    SetCurrentCodeBlock(ExitBlock);
+    StartNewBlock();
+  }
 }
 
 void OpDispatchBuilder::BSFOp(OpcodeArgs) {
--- a/FEXCore/Source/Interface/Core/OpcodeDispatcher.h
+++ b/FEXCore/Source/Interface/Core/OpcodeDispatcher.h
@@ -167,6 +167,8 @@
     ClearCachedNamedConstants();
   }
 
+  void RaiseDivideErrorIf(FEXCore::X86Tables::DecodedOp Op, Ref Condition);
+
   IRPair<IROp_Jump> Jump() {
     FlushRegisterCache();
     return _Jump();
@@ -188,9 +190,9 @@
     FlushRegisterCache();
     return _CondJump(ssa0, ssa1, ssa2, cond);
   }
-  IRPair<IROp_CondJump> CondJumpNZCV(CondClass Cond) {
+  IRPair<IROp_CondJump> CondJumpNZCV(CondClass Cond, bool NoSuspendCheck = false) {
     FlushRegisterCache();
-    return _CondJump(InvalidNode, InvalidNode, InvalidNode, InvalidNode, Cond, OpSize::iInvalid, true);
+    return _CondJump(InvalidNode, InvalidNode, InvalidNode, InvalidNode, Cond, OpSize::iInvalid, true, NoSuspendCheck);
   }
   IRPair<IROp_CondJump> CondJumpBit(Ref Src, unsigned Bit, bool Set) {
     FlushRegisterCache();
--- a/FEXCore/Source/Interface/IR/IR.json
+++ b/FEXCore/Source/Interface/IR/IR.json
@@ -308,7 +308,7 @@
         "HasSideEffects": true,
         "RAOverride": "0"
       },
-      "CondJump SSA:$Cmp1, SSA:$Cmp2, SSA:$TrueBlock, SSA:$FalseBlock, CondClass:$Cond{CondClass::NEQ}, OpSize:$CompareSize{OpSize::iInvalid}, i1:$FromNZCV{false}": {
+      "CondJump SSA:$Cmp1, SSA:$Cmp2, SSA:$TrueBlock, SSA:$FalseBlock, CondClass:$Cond{CondClass::NEQ}, OpSize:$CompareSize{OpSize::iInvalid}, i1:$FromNZCV{false}, i1:$NoSuspendCheck{false}": {
         "Inline": ["", "AddSub"],
         "HasSideEffects": true,
         "RAOverride": "2"
@@ -322,6 +322,10 @@
         "RAOverride": "2"
       },
       "Break BreakDefinition:$Reason": {
+        "HasSideEffects": true
+      },
+      "BreakIfNonZero GPR:$Value, BreakDefinition:$Reason": {
+        "Desc": ["Break if Value is not zero, and otherwise go on. All guest state must be in the context already."],
         "HasSideEffects": true
       },
       "CallbackReturn": {
--- a/FEXCore/Source/Interface/IR/Passes/RedundantFlagCalculationElimination.cpp
+++ b/FEXCore/Source/Interface/IR/Passes/RedundantFlagCalculationElimination.cpp
@@ -320,6 +320,9 @@
   case OP_STOREPF: return FlagInfo::Pack({.Write = FLAG_P, .CanEliminate = true});
   case OP_STOREAF: return FlagInfo::Pack({.Write = FLAG_A, .CanEliminate = true});
 
+  // The flags are the state of a fault, as at any exit from the block.
+  case OP_BREAKIFNONZERO: return FlagInfo::Pack({.Read = FLAG_ALL});
+
   case OP_NZCVSELECT:
   case OP_NZCVSELECTV:
   case OP_NZCVSELECTINCREMENT:
--- a/FEXCore/include/FEXCore/Core/CoreState.h
+++ b/FEXCore/include/FEXCore/Core/CoreState.h
@@ -416,6 +416,12 @@
    *  - Bit 14-0: Number of static registers spilled
    */
   uint64_t InSyscallInfo {};
+
+  /**
+   * @brief Where the host stack goes back to after this system call: signal frames the guest left without
+   * returning, as with siglongjmp, are done with. Zero for nothing to do.
+   */
+  uint64_t PendingHostSP {};
 
   uint32_t SignalHandlerRefCounter {};
 
--- a/Source/Tools/LinuxEmulation/ArchHelpers/MContext.h
+++ b/Source/Tools/LinuxEmulation/ArchHelpers/MContext.h
@@ -39,6 +39,16 @@
   uint64_t GPRs[23];
   FEXCore::x86_64::_libc_fpstate FPRState;
   uint64_t sa_mask;
+  // For telling when the guest has left this signal frame without returning: the frame next out, the guest's
+  // stack pointer when the signal arrived, and the alternate stack the frame is on, if any.
+  void* PreviousContext;
+  uint64_t PendingHostSP;
+  uint64_t InterruptedGuestSP;
+  uint64_t FrameAltStackLow;
+  uint64_t FrameAltStackHigh;
+  // The registers as the guest's frame had them, to see what its handler changed.
+  uint64_t DeliveredRegs[23];
+  bool SyscallNotStarted;
   uint16_t InSyscallInfo;
   // Host stack the interrupted JIT block has allocated.
   uint32_t JITStackBytes;
@@ -68,6 +78,16 @@
   uint32_t FPCR;
   __uint128_t FPRs[32];
   uint64_t sa_mask;
+  // For telling when the guest has left this signal frame without returning: the frame next out, the guest's
+  // stack pointer when the signal arrived, and the alternate stack the frame is on, if any.
+  void* PreviousContext;
+  uint64_t PendingHostSP;
+  uint64_t InterruptedGuestSP;
+  uint64_t FrameAltStackLow;
+  uint64_t FrameAltStackHigh;
+  // The registers as the guest's frame had them, to see what its handler changed.
+  uint64_t DeliveredRegs[23];
+  bool SyscallNotStarted;
   uint16_t InSyscallInfo;
   // Host stack the interrupted JIT block has allocated.
   uint32_t JITStackBytes;
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator/GuestFramesManagement.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator/GuestFramesManagement.cpp
@@ -6,6 +6,7 @@
 $end_info$
 */
 
+#include "LinuxSyscalls/ThreadManager.h"
 #include "LinuxSyscalls/SignalDelegator.h"
 
 #include <FEXCore/Core/Context.h>
@@ -21,6 +22,27 @@
 #include <cstring>
 
 namespace FEX::HLE {
+
+// The mask a new frame records: the guest's, or inside rt_sigsuspend the one from before the call, as the kernel's does.
+static void RecordDeliveredRegisters(ArchHelpers::Context::ContextBackup* Context, const void* Registers, size_t Size) {
+  LOGMAN_THROW_A_FMT(Size <= sizeof(Context->DeliveredRegs), "Frame registers do not fit");
+  memcpy(Context->DeliveredRegs, Registers, Size);
+}
+
+// A handler may fix a register and let the instruction run again, leaving RIP as it was. In a system call under way this
+// does not apply: its return is still to come. One that has not started just runs with what the handler left.
+static bool HandlerChangedRegisters(const ArchHelpers::Context::ContextBackup* Context, const void* Registers, size_t Size) {
+  return (Context->InSyscallInfo == 0 || Context->SyscallNotStarted) && memcmp(Context->DeliveredRegs, Registers, Size) != 0;
+}
+
+static uint64_t InterruptedGuestMask(FEXCore::Core::InternalThreadState* Thread) {
+  auto& SignalInfo = FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread)->SignalInfo;
+  if (SignalInfo.SuspendActive) {
+    SignalInfo.SuspendActive = false;
+    return SignalInfo.SuspendMaskForFrame;
+  }
+  return SignalInfo.CurrentSignalMask.Val;
+}
 constexpr uint32_t X86_SA_RESTORER = 0x04000000;
 // Total number of layouts that siginfo supports.
 enum class SigInfoLayout {
@@ -125,18 +147,28 @@
 void SignalDelegator::RestoreFrame_x64(FEXCore::Core::InternalThreadState* Thread, ArchHelpers::Context::ContextBackup* Context,
                                        FEXCore::Core::CpuStateFrame* Frame, void* ucontext) {
   auto* guest_uctx = reinterpret_cast<FEXCore::x86_64::ucontext_t*>(Context->UContextLocation);
+  uint64_t FrameMask {};
+  memcpy(&FrameMask, &guest_uctx->uc_sigmask, sizeof(FrameMask));
+  RestoreGuestMask(Thread, ucontext, FrameMask);
   [[maybe_unused]] auto* guest_siginfo = reinterpret_cast<siginfo_t*>(Context->SigInfoLocation);
   // A normal sigreturn also bypasses the syscall epilogue; restore its spill marker.
   Frame->InSyscallInfo = Context->InSyscallInfo;
 
   // If the guest modified the RIP then we need to take special precautions here
-  if (Context->OriginalRIP != guest_uctx->uc_mcontext.gregs[FEXCore::x86_64::FEX_REG_RIP] || Context->FaultToTopAndGeneratedException) {
+  if (Context->OriginalRIP != guest_uctx->uc_mcontext.gregs[FEXCore::x86_64::FEX_REG_RIP] || Context->FaultToTopAndGeneratedException ||
+      HandlerChangedRegisters(Context, guest_uctx->uc_mcontext.gregs, sizeof(guest_uctx->uc_mcontext.gregs))) {
 
     // Hack! Go back to the top of the dispatcher top
     // This is only safe inside the JIT rather than anything outside of it
     // The guest goes elsewhere: an interrupted syscall won't finish, and an interrupted block won't free its stack.
     Frame->InSyscallInfo = 0;
-    ArchHelpers::Context::SetSp(ucontext, ArchHelpers::Context::GetSp(ucontext) + Context->JITStackBytes);
+    Frame->PendingHostSP = 0;
+    if (Context->InSyscallInfo != 0) {
+      // Nothing of the call on the host stack will be used. A live frame's dispatcher runs from its backup.
+      ArchHelpers::Context::SetSp(ucontext, Context->PreviousContext ? reinterpret_cast<uint64_t>(Context->PreviousContext) : Frame->ReturningStackLocation);
+    } else {
+      ArchHelpers::Context::SetSp(ucontext, ArchHelpers::Context::GetSp(ucontext) + Context->JITStackBytes);
+    }
     ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
     ArchHelpers::Context::SetFillSRASingleInst(ucontext, false);
     // Set our state register to point to our guest thread data
@@ -210,15 +242,23 @@
 void SignalDelegator::RestoreFrame_ia32(FEXCore::Core::InternalThreadState* Thread, ArchHelpers::Context::ContextBackup* Context,
                                         FEXCore::Core::CpuStateFrame* Frame, void* ucontext) {
   SigFrame_i32* guest_uctx = reinterpret_cast<SigFrame_i32*>(Context->UContextLocation);
+  RestoreGuestMask(Thread, ucontext, (static_cast<uint64_t>(guest_uctx->extramask[0]) << 32) | guest_uctx->sc.oldmask);
   // A normal sigreturn also bypasses the syscall epilogue; restore its spill marker.
   Frame->InSyscallInfo = Context->InSyscallInfo;
   // If the guest modified the RIP then we need to take special precautions here
-  if (Context->OriginalRIP != guest_uctx->sc.ip || Context->FaultToTopAndGeneratedException) {
+  if (Context->OriginalRIP != guest_uctx->sc.ip || Context->FaultToTopAndGeneratedException ||
+      HandlerChangedRegisters(Context, &guest_uctx->sc, sizeof(guest_uctx->sc))) {
     // Hack! Go back to the top of the dispatcher top
     // This is only safe inside the JIT rather than anything outside of it
     // The guest goes elsewhere: an interrupted syscall won't finish, and an interrupted block won't free its stack.
     Frame->InSyscallInfo = 0;
-    ArchHelpers::Context::SetSp(ucontext, ArchHelpers::Context::GetSp(ucontext) + Context->JITStackBytes);
+    Frame->PendingHostSP = 0;
+    if (Context->InSyscallInfo != 0) {
+      // Nothing of the call on the host stack will be used. A live frame's dispatcher runs from its backup.
+      ArchHelpers::Context::SetSp(ucontext, Context->PreviousContext ? reinterpret_cast<uint64_t>(Context->PreviousContext) : Frame->ReturningStackLocation);
+    } else {
+      ArchHelpers::Context::SetSp(ucontext, ArchHelpers::Context::GetSp(ucontext) + Context->JITStackBytes);
+    }
     ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
     ArchHelpers::Context::SetFillSRASingleInst(ucontext, false);
     // Set our state register to point to our guest thread data
@@ -290,16 +330,26 @@
 void SignalDelegator::RestoreRTFrame_ia32(FEXCore::Core::InternalThreadState* Thread, ArchHelpers::Context::ContextBackup* Context,
                                           FEXCore::Core::CpuStateFrame* Frame, void* ucontext) {
   RTSigFrame_i32* guest_uctx = reinterpret_cast<RTSigFrame_i32*>(Context->UContextLocation);
+  uint64_t FrameMask {};
+  memcpy(&FrameMask, &guest_uctx->uc.uc_sigmask, sizeof(FrameMask));
+  RestoreGuestMask(Thread, ucontext, FrameMask);
   // A normal sigreturn also bypasses the syscall epilogue; restore its spill marker.
   Frame->InSyscallInfo = Context->InSyscallInfo;
   // If the guest modified the RIP then we need to take special precautions here
-  if (Context->OriginalRIP != guest_uctx->uc.uc_mcontext.gregs[FEXCore::x86::FEX_REG_EIP] || Context->FaultToTopAndGeneratedException) {
+  if (Context->OriginalRIP != guest_uctx->uc.uc_mcontext.gregs[FEXCore::x86::FEX_REG_EIP] || Context->FaultToTopAndGeneratedException ||
+      HandlerChangedRegisters(Context, guest_uctx->uc.uc_mcontext.gregs, sizeof(guest_uctx->uc.uc_mcontext.gregs))) {
 
     // Hack! Go back to the top of the dispatcher top
     // This is only safe inside the JIT rather than anything outside of it
     // The guest goes elsewhere: an interrupted syscall won't finish, and an interrupted block won't free its stack.
     Frame->InSyscallInfo = 0;
-    ArchHelpers::Context::SetSp(ucontext, ArchHelpers::Context::GetSp(ucontext) + Context->JITStackBytes);
+    Frame->PendingHostSP = 0;
+    if (Context->InSyscallInfo != 0) {
+      // Nothing of the call on the host stack will be used. A live frame's dispatcher runs from its backup.
+      ArchHelpers::Context::SetSp(ucontext, Context->PreviousContext ? reinterpret_cast<uint64_t>(Context->PreviousContext) : Frame->ReturningStackLocation);
+    } else {
+      ArchHelpers::Context::SetSp(ucontext, ArchHelpers::Context::GetSp(ucontext) + Context->JITStackBytes);
+    }
     ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
     ArchHelpers::Context::SetFillSRASingleInst(ucontext, false);
     // Set our state register to point to our guest thread data
@@ -501,6 +551,10 @@
                  (Frame->State.flags[FEXCore::X86State::X87FLAG_C3_LOC] << 14) | Frame->State.flags[FEXCore::X86State::X87FLAG_IE_LOC];
 
   // Copy over signal stack information
+  // The mask the handler interrupted. At sigreturn whatever is here is the mask.
+  const uint64_t InterruptedMask = InterruptedGuestMask(Thread);
+  memcpy(&guest_uctx->uc_sigmask, &InterruptedMask, sizeof(InterruptedMask));
+  guest_uctx->uc_mcontext.gregs[FEXCore::x86_64::FEX_REG_OLDMASK] = InterruptedMask;
   guest_uctx->uc_stack.ss_flags = GuestStack->ss_flags;
   guest_uctx->uc_stack.ss_sp = GuestStack->ss_sp;
   guest_uctx->uc_stack.ss_size = GuestStack->ss_size;
@@ -523,6 +577,8 @@
     // *(uint64_t*)NewGuestSP = SignalReturn;
   }
 
+  RecordDeliveredRegisters(ContextBackup, guest_uctx->uc_mcontext.gregs, sizeof(guest_uctx->uc_mcontext.gregs));
+
   return NewGuestSP;
 }
 
@@ -556,6 +612,9 @@
   ContextBackup->SigInfoLocation = 0;
 
   SigFrame_i32* guest_uctx = reinterpret_cast<SigFrame_i32*>(SigFrameLocation);
+  const uint64_t InterruptedMask = InterruptedGuestMask(Thread);
+  guest_uctx->sc.oldmask = static_cast<uint32_t>(InterruptedMask);
+  guest_uctx->extramask[0] = static_cast<uint32_t>(InterruptedMask >> 32);
   // Store where the host context lives in the guest stack.
   *(uint64_t*)HostStackLocation = (uint64_t)ContextBackup;
 
@@ -654,6 +713,8 @@
   Frame->State.gregs[FEXCore::X86State::REG_RDX] = 0;
   Frame->State.gregs[FEXCore::X86State::REG_RCX] = 0;
 
+  RecordDeliveredRegisters(ContextBackup, &guest_uctx->sc, sizeof(guest_uctx->sc));
+
   return NewGuestSP;
 }
 
@@ -762,6 +823,9 @@
   fpstate->ftw = FEXCore::FPState::ConvertFromAbridgedFTW(fpstate->fsw, Frame->State.mm, Frame->State.AbridgedFTW);
 
   // Copy over signal stack information
+  const uint64_t InterruptedMask = InterruptedGuestMask(Thread);
+  memcpy(&guest_uctx->uc.uc_sigmask, &InterruptedMask, sizeof(InterruptedMask));
+  guest_uctx->uc.uc_mcontext.oldmask = static_cast<uint32_t>(InterruptedMask);
   guest_uctx->uc.uc_stack.ss_flags = GuestStack->ss_flags;
   guest_uctx->uc.uc_stack.ss_sp = static_cast<uint32_t>(reinterpret_cast<uint64_t>(GuestStack->ss_sp));
   guest_uctx->uc.uc_stack.ss_size = GuestStack->ss_size;
@@ -856,6 +920,8 @@
   Frame->State.gregs[FEXCore::X86State::REG_RDX] = guest_uctx->pinfo;
   Frame->State.gregs[FEXCore::X86State::REG_RCX] = guest_uctx->puc;
 
+  RecordDeliveredRegisters(ContextBackup, guest_uctx->uc.uc_mcontext.gregs, sizeof(guest_uctx->uc.uc_mcontext.gregs));
+
   return NewGuestSP;
 }
 
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
@@ -104,7 +104,7 @@
       // Nothing would end the wait now, so it ends here, and the signal comes back wherever this resumes.
       auto& [HostMaskValues] = static_cast<ucontext_t*>(UContext)->uc_sigmask;
       HostMaskValues[0] = Exact.MaskBeforeWaiting;
-      Exact.WaitingForExactState = false;
+      CancelWaitForExactState(Thread);
     }
     if (Handled) {
       return;
@@ -159,6 +159,130 @@
 }
 
 static bool IsAsyncSignal(const siginfo_t* Info, int Signal);
+
+static void CheckForPendingSignals(const FEX::HLE::ThreadStateObject* Thread);
+
+void SignalDelegator::CancelWaitForExactState(FEX::HLE::ThreadStateObject* ThreadObject) {
+  // What is holding the signal has to give way, so it goes back to the kernel, behind any of its number that came
+  // after it. With the kernel's queue full, it stays with FEX as a pending signal, which keeps it but not its payload.
+  auto& Exact = ThreadObject->SignalInfo;
+  const int SavedErrno = errno;
+  if (::syscall(SYS_rt_tgsigqueueinfo, ::getpid(), FHU::Syscalls::gettid(), Exact.HeldSignal, &Exact.HeldInfo) == -1) {
+    Exact.PendingSignals |= 1ULL << (Exact.HeldSignal - 1);
+  }
+  Exact.WaitingForExactState = false;
+  mprotect(reinterpret_cast<void*>(&ThreadObject->Thread->InterruptFaultPage), sizeof(ThreadObject->Thread->InterruptFaultPage), PROT_READ | PROT_WRITE);
+  errno = SavedErrno;
+}
+
+void SignalDelegator::RestoreGuestMask(FEXCore::Core::InternalThreadState* Thread, void* ucontext, uint64_t Mask) {
+  // What the frame holds at sigreturn is the mask from now on, including what the handler wrote there: musl's
+  // pthread_cancel blocks its signal this way, and would otherwise take it forever.
+  auto ThreadObject = FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread);
+  Mask &= ~((1ULL << (SIGKILL - 1)) | (1ULL << (SIGSTOP - 1)));
+  ThreadObject->SignalInfo.CurrentSignalMask.Val = Mask;
+  uint64_t HostMask = Mask;
+  for (size_t i = 0; i < MAX_SIGNALS; ++i) {
+    if (HostHandlers[i + 1].Required.load(std::memory_order_relaxed)) {
+      HostMask &= ~(1ULL << i);
+    }
+  }
+  memcpy(&static_cast<ucontext_t*>(ucontext)->uc_sigmask, &HostMask, sizeof(HostMask));
+  // Signals raised here wait for the host's sigreturn, which is when the mask above takes effect. One that FEX never
+  // blocks would nest in this handler instead, so it is blocked for the rest of it. It can arrive anywhere after
+  // that, a blocking system call included, the way any other signal does.
+  const uint64_t RequiredNowAllowed = ThreadObject->SignalInfo.PendingSignals & ~GetWaitBlockableSignals() & ~Mask;
+  if (RequiredNowAllowed) {
+    ::syscall(SYS_rt_sigprocmask, SIG_BLOCK, &RequiredNowAllowed, nullptr, 8);
+  }
+  CheckForPendingSignals(ThreadObject);
+}
+
+bool SignalDelegator::UnlinkAbandonedSignalFrames(FEXCore::Core::InternalThreadState* Thread, uint64_t GuestSP) {
+  // A thread nests one frame per signal number, 64 at most, unless a handler allows its own signal, and that keeps
+  // going down the stack, which is never taken for leaving. So more frames than this means the guest left some. The
+  // stack pointer alone cannot say which, since a handler on some other stack looks just like one that left, and a
+  // frame released by mistake cannot resume a system call it interrupted. So below this nothing is released.
+  constexpr uint64_t MaxFramesBeforeRelease = 128;
+  if (Thread->CurrentFrame->SignalHandlerRefCounter <= MaxFramesBeforeRelease) {
+    return false;
+  }
+  auto& SignalInfo = FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread)->SignalInfo;
+  bool Released = false;
+  while (SignalInfo.TopSignalContext) {
+    auto Context = static_cast<ArchHelpers::Context::ContextBackup*>(SignalInfo.TopSignalContext);
+    // A frame is in use while the stack pointer is below where the signal interrupted, on the stack it
+    // interrupted, or anywhere on the frame's alternate stack. A handler may move between those, as .NET's does
+    // from its alternate stack to the interrupted one. Past that the guest has left, as with siglongjmp. A handler
+    // that moved to some other stack at a higher address looks the same; its sigreturn is handled below.
+    const bool InterruptedOnAltStack = Context->FrameAltStackHigh != 0 && Context->InterruptedGuestSP >= Context->FrameAltStackLow &&
+                                       Context->InterruptedGuestSP <= Context->FrameAltStackHigh;
+    const bool InAltStack = Context->FrameAltStackHigh != 0 && GuestSP >= Context->FrameAltStackLow && GuestSP <= Context->FrameAltStackHigh;
+    bool InUse;
+    if (InterruptedOnAltStack && InAltStack) {
+      InUse = GuestSP < Context->InterruptedGuestSP;
+    } else if (InterruptedOnAltStack) {
+      // Nested on the alternate stack and now off it. Compare with whatever first went onto that stack.
+      auto Outer = Context;
+      while (Outer->FrameAltStackHigh != 0 && Outer->InterruptedGuestSP >= Outer->FrameAltStackLow &&
+             Outer->InterruptedGuestSP <= Outer->FrameAltStackHigh && Outer->PreviousContext) {
+        Outer = static_cast<ArchHelpers::Context::ContextBackup*>(Outer->PreviousContext);
+      }
+      InUse = GuestSP < Outer->InterruptedGuestSP || (Outer->InterruptedGuestSP >= Context->FrameAltStackLow && Outer->InterruptedGuestSP <= Context->FrameAltStackHigh);
+    } else {
+      InUse = InAltStack || GuestSP < Context->InterruptedGuestSP;
+    }
+    if (InUse) {
+      break;
+    }
+    SignalInfo.TopSignalContext = Context->PreviousContext;
+    --Thread->CurrentFrame->SignalHandlerRefCounter;
+    Released = true;
+  }
+  if (Released && !SignalInfo.DeferredSignalFrames.empty()) {
+    // Frames waiting for a sigreturn that is not coming: the next check takes them.
+    mprotect(reinterpret_cast<void*>(&Thread->InterruptFaultPage), sizeof(Thread->InterruptFaultPage), PROT_NONE);
+  }
+  return Released;
+}
+
+bool SignalDelegator::ReleaseAbandonedSignalFrames(FEXCore::Core::InternalThreadState* Thread) {
+  auto Frame = Thread->CurrentFrame;
+  if (!UnlinkAbandonedSignalFrames(Thread, Frame->State.gregs[FEXCore::X86State::REG_RSP])) {
+    return false;
+  }
+  // A live frame's dispatcher runs from where its backup is; with none, from the bottom of the stack.
+  auto Top = FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread)->SignalInfo.TopSignalContext;
+  Frame->PendingHostSP = Top ? reinterpret_cast<uint64_t>(Top) : Frame->ReturningStackLocation;
+  return true;
+}
+
+void SignalDelegator::ReleaseAbandonedSignalFramesBeforeDelivery(FEXCore::Core::InternalThreadState* Thread, int Signal, void* info, void* ucontext) {
+  // A program whose only system calls are in its handlers, as with a loop around siglongjmp, reaches no system call
+  // outside a frame. So the arrival of the next signal also counts, where the block's stack use is known: the block's
+  // spill slots move up over what is released, and nothing else of the interrupted code is on the stack.
+  auto Frame = Thread->CurrentFrame;
+  auto& SignalInfo = FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread)->SignalInfo;
+  const uint64_t PC = ArchHelpers::Context::GetPc(ucontext);
+  // A fault the JIT raises itself has already freed its block's stack and saved the guest's registers.
+  const bool Generated = Frame->SynchronousFaultData.FaultToTopAndGeneratedException;
+  if (!SignalInfo.TopSignalContext || Frame->InSyscallInfo != 0 || !(Generated || CTX->IsAddressInCodeBuffer(Thread, PC)) ||
+      !(SignalInfo.AtCheck || !IsAsyncSignal(static_cast<const siginfo_t*>(info), Signal))) {
+    return;
+  }
+  const uint64_t GuestSP = Generated ? Frame->State.gregs[FEXCore::X86State::REG_RSP] :
+                                       ArchHelpers::Context::GetArmReg(ucontext, Config.SRAGPRMapping[FEXCore::X86State::REG_RSP]);
+  if (!UnlinkAbandonedSignalFrames(Thread, GuestSP)) {
+    return;
+  }
+  const uint64_t Bytes = Generated ? 0 : CTX->GetBlockStackBytesFromHostPC(Thread, PC);
+  const uint64_t Base = SignalInfo.TopSignalContext ? reinterpret_cast<uint64_t>(SignalInfo.TopSignalContext) : Frame->ReturningStackLocation;
+  const uint64_t OldSP = ArchHelpers::Context::GetSp(ucontext);
+  if (Base - Bytes > OldSP) {
+    memmove(reinterpret_cast<void*>(Base - Bytes), reinterpret_cast<const void*>(OldSP), Bytes);
+    ArchHelpers::Context::SetSp(ucontext, Base - Bytes);
+  }
+}
 
 ArchHelpers::Context::ContextBackup* SignalDelegator::StoreThreadState(FEXCore::Core::InternalThreadState* Thread, int Signal, void* ucontext) {
   // We can end up getting a signal at any point in our host state
@@ -213,6 +337,7 @@
     // We store a pointer to our host-stack on the guest stack.
     // We need to inspect the guest state coming in, so we can get our host stack back.
     uint64_t GuestSP = Thread->CurrentFrame->State.gregs[FEXCore::X86State::REG_RSP];
+    const uint64_t FrameSP = GuestSP;
 
     if (Is64BitMode) {
       // Signal frame layout on stack needs to be as follows
@@ -274,6 +399,42 @@
     }
 
     OldSP = *reinterpret_cast<uint64_t*>(GuestSP);
+
+    // A frame released as left can still be returned to, by a handler that moved to another stack and came back. Its
+    // backup is gone, and a system call it interrupted runs again. Otherwise the guest frame holds all the guest needs.
+    auto& SignalInfo = FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread)->SignalInfo;
+    const uint64_t ReturningFrame = FrameSP - (Is64BitMode ? 0 : (Type == RestoreType::TYPE_NONREALTIME ? 8 : 4));
+    bool Live = false;
+    uint32_t Skipped = 0;
+    for (auto Walk = static_cast<ArchHelpers::Context::ContextBackup*>(SignalInfo.TopSignalContext); Walk;
+         Walk = static_cast<ArchHelpers::Context::ContextBackup*>(Walk->PreviousContext)) {
+      if (reinterpret_cast<uint64_t>(Walk) == OldSP && Walk->UContextLocation == ReturningFrame) {
+        Live = true;
+        break;
+      }
+      ++Skipped;
+    }
+    if (Live) {
+      // Frames above this one, whose handlers left to it, are gone with this return.
+      Thread->CurrentFrame->SignalHandlerRefCounter -= Skipped;
+    }
+    if (!Live) {
+      auto Frame = Thread->CurrentFrame;
+      ArchHelpers::Context::ContextBackup Released {};
+      Released.UContextLocation = ReturningFrame;
+      Released.OriginalRIP = ~0ULL;
+      ArchHelpers::Context::SetSp(ucontext, SignalInfo.TopSignalContext ? reinterpret_cast<uint64_t>(SignalInfo.TopSignalContext) : Frame->ReturningStackLocation);
+      if (Is64BitMode) {
+        RestoreFrame_x64(Thread, &Released, Frame, ucontext);
+      } else if (Type == RestoreType::TYPE_NONREALTIME) {
+        RestoreFrame_ia32(Thread, &Released, Frame, ucontext);
+      } else {
+        RestoreRTFrame_ia32(Thread, &Released, Frame, ucontext);
+      }
+      // The caller counts this return, and the release already did.
+      ++Frame->SignalHandlerRefCounter;
+      return;
+    }
   }
 
   uintptr_t NewSP = OldSP;
@@ -282,6 +443,13 @@
   // Restore host state
   ArchHelpers::Context::RestoreContext(ucontext, Context);
 
+  if (Type != RestoreType::TYPE_PAUSE) {
+    FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread)->SignalInfo.TopSignalContext = Context->PreviousContext;
+    // What the interrupted system call was going to do to the host stack, which this handler's own calls
+    // did not touch. Also drops anything worked out by the system call that brought us here.
+    Thread->CurrentFrame->PendingHostSP = Context->PendingHostSP;
+  }
+
   // Reset the guest state
   memcpy(&Thread->CurrentFrame->State, &Context->GuestState, sizeof(FEXCore::Core::CPUState));
 
@@ -308,6 +476,7 @@
 
 bool SignalDelegator::HandleDispatcherGuestSignal(FEXCore::Core::InternalThreadState* Thread, int Signal, void* info, void* ucontext,
                                                   GuestSigAction* GuestAction, stack_t* GuestStack) {
+  ReleaseAbandonedSignalFramesBeforeDelivery(Thread, Signal, info, ucontext);
   auto ContextBackup = StoreThreadState(Thread, Signal, ucontext);
 
   auto Frame = Thread->CurrentFrame;
@@ -368,6 +537,15 @@
 
   uint64_t OldGuestSP = Frame->State.gregs[FEXCore::X86State::REG_RSP];
   uint64_t NewGuestSP = OldGuestSP;
+  auto& SignalInfo = FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread)->SignalInfo;
+  ContextBackup->SyscallNotStarted = SignalInfo.AtSyscallStart;
+  ContextBackup->PreviousContext = SignalInfo.TopSignalContext;
+  ContextBackup->InterruptedGuestSP = OldGuestSP;
+  ContextBackup->PendingHostSP = Frame->PendingHostSP;
+  Frame->PendingHostSP = 0;
+  ContextBackup->FrameAltStackLow = 0;
+  ContextBackup->FrameAltStackHigh = 0;
+  SignalInfo.TopSignalContext = ContextBackup;
 
   // altstack is only used if the signal handler was setup with SA_ONSTACK
   if (GuestAction->sa_flags & SA_ONSTACK) {
@@ -377,6 +555,8 @@
       // Then that means we are hitting recursive signals and we need to walk back the stack correctly
       uint64_t AltStackBase = reinterpret_cast<uint64_t>(GuestStack->ss_sp);
       uint64_t AltStackEnd = AltStackBase + GuestStack->ss_size;
+      ContextBackup->FrameAltStackLow = AltStackBase;
+      ContextBackup->FrameAltStackHigh = AltStackEnd;
       if (OldGuestSP >= AltStackBase && OldGuestSP <= AltStackEnd) {
         // We are already in the alt stack, the rest of the code will handle adjusting this
       } else {
@@ -441,7 +621,9 @@
       ArchHelpers::Context::GetPc(ucontext) == Config.SignalHandlerReturnAddressRT) {
     auto ThreadObject = FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread);
     // This restores the interrupted context's mask, and whatever was waiting comes back under that.
-    FEX::HLE::ThreadManager::GetStateObjectFromFEXCoreThread(Thread)->SignalInfo.WaitingForExactState = false;
+    if (ThreadObject->SignalInfo.WaitingForExactState) {
+      CancelWaitForExactState(ThreadObject);
+    }
     RestoreThreadState(Thread, ucontext,
                        ArchHelpers::Context::GetPc(ucontext) == Config.SignalHandlerReturnAddressRT ? RestoreType::TYPE_REALTIME :
                                                                                                       RestoreType::TYPE_NONREALTIME);
@@ -595,10 +777,11 @@
   return Mask;
 }
 
-uint64_t SignalDelegator::GetNewSigMask(int Signal) const {
+uint64_t SignalDelegator::GetNewSigMask(int Signal, uint64_t GuestMask) const {
   const SignalHandler& Handler = HostHandlers[Signal];
-  // Set up a new mask based on this signals signal mask
-  uint64_t NewMask = Handler.GuestAction.sa_mask.Val;
+  // The kernel adds to the mask rather than replacing it: a signal the guest has blocked stays queued in the
+  // kernel, with its payload, while another signal's handler runs.
+  uint64_t NewMask = GuestMask | Handler.GuestAction.sa_mask.Val;
 
   // If NODEFER then the new signal mask includes this signal
   if (!(Handler.GuestAction.sa_flags & SA_NODEFER)) {
@@ -642,6 +825,15 @@
   ucontext_t* _context = (ucontext_t*)UContext;
   auto SigInfo = *static_cast<siginfo_t*>(Info);
 
+  // The JIT raises the guest's divide error with a trap instruction, there being no way to make the host's own.
+  const auto& GeneratedFault = Thread->CurrentFrame->SynchronousFaultData;
+  const int HostSignal = Signal;
+  if (Signal == SIGILL && GeneratedFault.FaultToTopAndGeneratedException && GeneratedFault.Signal == SIGFPE) {
+    Signal = SIGFPE;
+    SigInfo.si_signo = SIGFPE;
+    SigInfo.si_code = GeneratedFault.si_code;
+  }
+
   auto MustDeferSignal = (Thread->CurrentFrame->State.DeferredSignalRefCount.Load() != 0);
   // Outside a system call the guest state FEX can show a handler is not exact. Inside a block it can only
   // name the instruction a signal interrupted, and that instruction may be half done. In the dispatcher
@@ -649,18 +841,25 @@
   // written yet. That is enough for a handler that returns, since the host context resumes exactly, but not
   // for one that moves the guest, as Go's asynchronous preemption does.
   //
-  // So such a signal goes back to the kernel, stays blocked, and arrives again at the next check at a block
-  // entry or loop edge, or at the start of a system call. The kernel keeps its payload and mask. Only two
-  // realtime signals of one number queued to this thread can change order: the first goes behind the second.
+  // So such a signal waits here, with every other one still in the kernel behind the mask, for the next check at a
+  // block entry or loop edge, or at the start of a system call, and is delivered there. This holds one, so no
+  // order, count or payload changes hands.
   auto& Exact = ThreadObject->SignalInfo;
   const uint64_t HostPC = ArchHelpers::Context::GetPc(UContext);
-  // Good for one delivery: the code buffer can be reused, and any further signal comes through the check again.
-  Exact.AtCheck = HostPC == Exact.ExactStatePC;
-  Exact.ExactStatePC = 0;
   auto& [HostMaskValues] = _context->uc_sigmask;
   static_assert(sizeof(HostMaskValues[0]) == sizeof(uint64_t), "Unknown sigset_t layout");
-  if (Exact.WaitingForExactState && Signal == SIGSEGV && SigInfo.si_code == SEGV_ACCERR &&
-      SigInfo.si_addr == reinterpret_cast<void*>(&Thread->InterruptFaultPage)) {
+  const bool FaultAtCheck =
+    Signal == SIGSEGV && SigInfo.si_code == SEGV_ACCERR && SigInfo.si_addr == reinterpret_cast<void*>(&Thread->InterruptFaultPage);
+  // A required signal can nest in here between this being set and being used, so each handler puts back what it found.
+  struct AtCheckRestore {
+    bool& Flag;
+    const bool Value;
+    ~AtCheckRestore() {
+      Flag = Value;
+    }
+  } RestoreAtCheck {Exact.AtCheck, Exact.AtCheck};
+  Exact.AtCheck = false;
+  if (FaultAtCheck && Exact.WaitingForExactState) {
     // The end of a signal-deferring section in the dispatcher or in FEX itself also lands here.
     if (MustDeferSignal || (Thread->CurrentFrame->InSyscallInfo == 0 && !CTX->IsAddressInCodeBuffer(Thread, HostPC))) {
       ArchHelpers::Context::SetPc(UContext, HostPC + 4);
@@ -668,34 +867,25 @@
     }
     HostMaskValues[0] = Exact.MaskBeforeWaiting;
     Exact.WaitingForExactState = false;
-    // A signal that arrives here, as the kernel returns to this check, sees the exact state.
-    Exact.ExactStatePC = HostPC;
     mprotect(reinterpret_cast<void*>(&Thread->InterruptFaultPage), sizeof(Thread->InterruptFaultPage), PROT_READ | PROT_WRITE);
-    return;
-  }
-  const uint64_t Blockable = GetWaitBlockableSignals();
-  // Already waiting and still unblocked means the mask was replaced since, so the new mask is the one to keep.
-  if (IsAsyncSignal(&SigInfo, Signal) && (Blockable & (1ULL << (Signal - 1)))) {
+    Signal = Exact.HeldSignal;
+    SigInfo = Exact.HeldInfo;
+    Exact.AtCheck = true;
+  } else if (!FaultAtCheck && !Exact.WaitingForExactState && IsAsyncSignal(&SigInfo, Signal) && (GetWaitBlockableSignals() & (1ULL << (Signal - 1)))) {
     const auto TargetFunction = HostHandlers[Signal].GuestAction.sigaction_handler.handler;
     const bool GuestWillRunHandler = TargetFunction != SIG_DFL && TargetFunction != SIG_IGN &&
                                      !(ThreadObject->SignalInfo.CurrentSignalMask.Val & (1ULL << (Signal - 1)));
-    if (MustDeferSignal || (GuestWillRunHandler && Thread->CurrentFrame->InSyscallInfo == 0 && !Exact.AtCheck)) {
+    if (MustDeferSignal || (GuestWillRunHandler && Thread->CurrentFrame->InSyscallInfo == 0)) {
       const int SavedErrno = errno;
-      // The page first: once the signal is queued it must not be handled here as well, and without a protected
-      // page nothing would ever end the wait.
+      // Without a protected page nothing would end the wait. Then what follows handles it as before, inexact as that may be.
       if (mprotect(reinterpret_cast<void*>(&Thread->InterruptFaultPage), sizeof(Thread->InterruptFaultPage), PROT_NONE) == 0) {
-        if (::syscall(SYS_rt_tgsigqueueinfo, ::getpid(), FHU::Syscalls::gettid(), Signal, &SigInfo) == 0) {
-          Exact.MaskBeforeWaiting = HostMaskValues[0];
-          HostMaskValues[0] |= Blockable;
-          Exact.WaitingForExactState = true;
-          return;
-        }
-        if (!Exact.WaitingForExactState) {
-          mprotect(reinterpret_cast<void*>(&Thread->InterruptFaultPage), sizeof(Thread->InterruptFaultPage), PROT_READ | PROT_WRITE);
-        }
+        Exact.HeldSignal = Signal;
+        Exact.HeldInfo = SigInfo;
+        Exact.MaskBeforeWaiting = HostMaskValues[0];
+        HostMaskValues[0] |= GetWaitBlockableSignals();
+        Exact.WaitingForExactState = true;
+        return;
       }
-      // No memory for the page's mapping, or the kernel's queue is full. What follows handles it as before,
-      // inexact as that may be.
       errno = SavedErrno;
     }
   }
@@ -755,7 +945,7 @@
     if (Exact.WaitingForExactState) {
       // The mask that frame saves must be the guest's, and the check below now serves both.
       sigmask_val[0] = Exact.MaskBeforeWaiting;
-      Exact.WaitingForExactState = false;
+      CancelWaitForExactState(ThreadObject);
     }
     ThreadObject->SignalInfo.DeferredSignalFrames.emplace_back(ThreadStateObject::DeferredSignalState {
       .Info = SigInfo,
@@ -765,7 +955,7 @@
 
     // Update our host signal mask so we don't hit race conditions with signals
     // This allows us to maintain the expected signal mask through the guest signal handling and then all the way back again
-    sigmask_val[0] = GetNewSigMask(Signal);
+    sigmask_val[0] = GetNewSigMask(Signal, ThreadObject->SignalInfo.CurrentSignalMask.Val);
 
     // Now update the faulting page permissions so it will fault on write.
     mprotect(reinterpret_cast<void*>(&Thread->InterruptFaultPage), sizeof(Thread->InterruptFaultPage), PROT_NONE);
@@ -785,6 +975,12 @@
   // Let the host take first stab at handling the signal
   SignalHandler& Handler = HostHandlers[Signal];
 
+  // A fault cannot wait. If the guest blocks or ignores it, the kernel ends the program rather than run or skip it.
+  if (!IsAsyncSignal(&SigInfo, Signal) && ((ThreadObject->SignalInfo.CurrentSignalMask.Val & (1ULL << (Signal - 1))) ||
+                                           Handler.GuestAction.sigaction_handler.handler == SIG_IGN)) {
+    Handler.GuestAction.sigaction_handler.handler = SIG_DFL;
+  }
+
   // Remove the pending signal
   ThreadObject->SignalInfo.PendingSignals &= ~(1ULL << (Signal - 1));
 
@@ -801,12 +997,23 @@
       // A synchronous fault cannot wait for the check. Its handler must see the mask the guest set, and the
       // signal that was waiting comes back through the kernel as this handler's mask allows.
       HostMaskValues[0] = Exact.MaskBeforeWaiting;
-      Exact.WaitingForExactState = false;
-      mprotect(reinterpret_cast<void*>(&Thread->InterruptFaultPage), sizeof(Thread->InterruptFaultPage), PROT_READ | PROT_WRITE);
+      CancelWaitForExactState(ThreadObject);
     }
+    if (HostSignal == SIGSEGV) {
+      // Writing the guest's frame can land on a code page FEX has protected, and that fault has to get through.
+      const uint64_t Fault = 1ULL << (SIGSEGV - 1);
+      ::syscall(SYS_rt_sigprocmask, SIG_UNBLOCK, &Fault, nullptr, sizeof(Fault));
+    }
     if (Handler.GuestHandler &&
         Handler.GuestHandler(Thread, Signal, &SigInfo, UContext, &Handler.GuestAction, &ThreadObject->SignalInfo.GuestAltStack)) {
-      uint64_t NewMask = GetNewSigMask(Signal);
+      // What the guest sees as its mask from here on, as the kernel would set it. The frame holds the one before.
+      const uint64_t IgnoredSignals = (1ULL << (SIGKILL - 1)) | (1ULL << (SIGSTOP - 1));
+      uint64_t NewMask = GetNewSigMask(Signal, ThreadObject->SignalInfo.CurrentSignalMask.Val);
+      uint64_t GuestMask = ThreadObject->SignalInfo.CurrentSignalMask.Val | Handler.GuestAction.sa_mask.Val;
+      if (!(Handler.GuestAction.sa_flags & SA_NODEFER)) {
+        GuestMask |= 1ULL << (Signal - 1);
+      }
+      ThreadObject->SignalInfo.CurrentSignalMask.Val = GuestMask & ~IgnoredSignals;
 
       // Update our host signal mask so we don't hit race conditions with signals
       // This allows us to maintain the expected signal mask through the guest signal handling and then all the way back again
@@ -847,6 +1054,9 @@
       // If the signal wasn't sent by the kernel then we need to reraise it.
       // This is necessary since returning from this signal handler now might just continue executing.
       // eg: If sent from tgkill then the signal gets dropped and returns.
+      // A fault the guest had blocked is blocked on the host too, unless FEX requires it, and must end the program all the same.
+      const uint64_t SignalBit = 1ULL << (Signal - 1);
+      ::syscall(SYS_rt_sigprocmask, SIG_UNBLOCK, &SignalBit, nullptr, sizeof(SignalBit));
       FHU::Syscalls::tgkill(::getpid(), FHU::Syscalls::gettid(), Signal);
     }
   } else {
@@ -1347,15 +1557,8 @@
       return -EINVAL;
     }
 
-    uint64_t HostMask = Thread->SignalInfo.CurrentSignalMask.Val;
     // Now actually set the host mask
-    // This will hide from the guest that we are not actually setting all of the masks it wants
-    for (size_t i = 0; i < MAX_SIGNALS; ++i) {
-      if (HostHandlers[i + 1].Required.load(std::memory_order_relaxed)) {
-        // If it is a required host signal then we can't mask it
-        HostMask &= ~(1ULL << i);
-      }
-    }
+    const uint64_t HostMask = HostMaskForGuestMask(Thread->SignalInfo.CurrentSignalMask.Val);
 
     ::syscall(SYS_rt_sigprocmask, SIG_SETMASK, &HostMask, nullptr, 8);
   }
@@ -1389,47 +1592,87 @@
     *set |= HostSignals;
   }
   return 0;
+}
+
+uint64_t SignalDelegator::HostMaskForGuestMask(uint64_t GuestMask) const {
+  // This will hide from the guest that we are not actually setting all of the masks it wants
+  for (size_t i = 0; i < MAX_SIGNALS; ++i) {
+    if (HostHandlers[i + 1].Required.load(std::memory_order_relaxed)) {
+      // If it is a required host signal then we can't mask it
+      GuestMask &= ~(1ULL << i);
+    }
+  }
+  return GuestMask;
 }
 
-uint64_t SignalDelegator::GuestSigSuspend(FEX::HLE::ThreadStateObject* Thread, uint64_t* set, size_t sigsetsize) {
-  if (sigsetsize > sizeof(uint64_t)) {
-    return -EINVAL;
-  }
+uint64_t SignalDelegator::BeginTemporaryGuestMask(FEX::HLE::ThreadStateObject* Thread, uint64_t GuestSet) {
+  // Nothing may run between FEX taking this mask and the kernel taking it, which happens as the wait starts, or it
+  // would not wake the wait. That includes what FEX never blocks otherwise: nothing here can fault.
+  const uint64_t All = ~0ULL;
+  ::syscall(SYS_rt_sigprocmask, SIG_BLOCK, &All, nullptr, 8);
 
-  uint64_t IgnoredSignalsMask = ~((1ULL << (SIGKILL - 1)) | (1ULL << (SIGSTOP - 1)));
+  // A frame built during the call records the mask from before it, as the kernel's does, so a sigreturn puts that back.
+  const uint64_t IgnoredSignalsMask = ~((1ULL << (SIGKILL - 1)) | (1ULL << (SIGSTOP - 1)));
+  Thread->SignalInfo.SuspendMaskForFrame = Thread->SignalInfo.CurrentSignalMask.Val;
+  Thread->SignalInfo.SuspendActive = true;
+  Thread->SignalInfo.CurrentSignalMask.Val = GuestSet & IgnoredSignalsMask;
+  // A signal already taken and waiting for this mask goes to the kernel, and is there when the wait starts.
+  CheckForPendingSignals(Thread);
+  return HostMaskForGuestMask(Thread->SignalInfo.CurrentSignalMask.Val);
+}
 
-  // Backup the mask
-  Thread->SignalInfo.PreviousSuspendMask = Thread->SignalInfo.CurrentSignalMask;
-  // Set the new mask
-  Thread->SignalInfo.CurrentSignalMask.Val = *set & IgnoredSignalsMask;
-  sigset_t HostSet {};
+void SignalDelegator::EndTemporaryGuestMask(FEX::HLE::ThreadStateObject* Thread, uint64_t MaskBefore) {
+  const int SavedErrno = errno;
+  // A guest handler's sigreturn has already set the mask from its frame. Otherwise nothing has.
+  if (Thread->SignalInfo.SuspendActive) {
+    Thread->SignalInfo.SuspendActive = false;
+    Thread->SignalInfo.CurrentSignalMask.Val = MaskBefore;
+  }
+  const uint64_t HostMask = HostMaskForGuestMask(Thread->SignalInfo.CurrentSignalMask.Val);
+  ::syscall(SYS_rt_sigprocmask, SIG_SETMASK, &HostMask, nullptr, 8);
+  CheckForPendingSignals(Thread);
+  errno = SavedErrno;
+}
 
-  sigemptyset(&HostSet);
+bool TemporaryGuestMask::IsReadable(const uint64_t* Address) {
+  // The kernel reads this set before it looks at the operation, and an unknown operation changes nothing.
+  const int SavedErrno = errno;
+  const bool Readable = ::syscall(SYS_rt_sigprocmask, -1, Address, nullptr, sizeof(*Address)) == -1 && errno != EFAULT;
+  errno = SavedErrno;
+  return Readable;
+}
 
-  for (int32_t i = 0; i < MAX_SIGNALS; ++i) {
-    if (*set & (1ULL << i)) {
-      sigaddset(&HostSet, i + 1);
-    }
+TemporaryGuestMask::TemporaryGuestMask(FEXCore::Core::CpuStateFrame* Frame, const uint64_t* GuestSet, size_t SetSize)
+  : GuestSet {GuestSet} {
+  // Without a mask this call is like any other, and with a bad one the kernel will say so.
+  if (!GuestSet || SetSize != sizeof(uint64_t) || !IsReadable(GuestSet)) {
+    return;
   }
+  Thread = FEX::HLE::ThreadManager::GetStateObjectFromCPUState(Frame);
+  MaskBefore = Thread->SignalInfo.CurrentSignalMask.Val;
+  HostMask = FEX::HLE::_SyscallHandler->GetSignalDelegator()->BeginTemporaryGuestMask(Thread, *GuestSet);
+}
 
-  // Additionally we must always listen to SIGNAL_FOR_PAUSE
-  // This technically forces us in to a race but should be fine
-  // SIGBUS and SIGILL can't happen so we don't need to listen for them
-  // sigaddset(&HostSet, SIGNAL_FOR_PAUSE);
+TemporaryGuestMask::~TemporaryGuestMask() {
+  if (Thread) {
+    FEX::HLE::_SyscallHandler->GetSignalDelegator()->EndTemporaryGuestMask(Thread, MaskBefore);
+  }
+}
 
-  // Spin this in a loop until we aren't sigsuspended
-  // This can happen in the case that the guest has sent signal that we can't block
-  uint64_t Result = sigsuspend(&HostSet);
+uint64_t SignalDelegator::GuestSigSuspend(FEX::HLE::ThreadStateObject* Thread, uint64_t* set, size_t sigsetsize) {
+  if (sigsetsize != sizeof(uint64_t)) {
+    return -EINVAL;
+  }
+  if (!TemporaryGuestMask::IsReadable(set)) {
+    return -EFAULT;
+  }
 
-  // Restore Previous signal mask we are emulating
-  // XXX: Might be unsafe if the signal handler adjusted the thread's signal mask
-  // But since we don't support the guest adjusting the mask through the context object
-  // then this is safe-ish
-  Thread->SignalInfo.CurrentSignalMask = Thread->SignalInfo.PreviousSuspendMask;
-
-  CheckForPendingSignals(Thread);
-
-  return Result == -1 ? -errno : Result;
+  const uint64_t MaskBefore = Thread->SignalInfo.CurrentSignalMask.Val;
+  const uint64_t HostMask = BeginTemporaryGuestMask(Thread, *set);
+  uint64_t Result = ::syscall(SYS_rt_sigsuspend, &HostMask, sizeof(HostMask));
+  Result = Result == -1 ? -errno : Result;
+  EndTemporaryGuestMask(Thread, MaskBefore);
+  return Result;
 }
 
 uint64_t SignalDelegator::GuestSigTimedWait(uint64_t* set, siginfo_t* info, const struct timespec* timeout, size_t sigsetsize) {
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.h
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.h
@@ -91,6 +91,8 @@
   uint64_t GuestSigProcMask(FEX::HLE::ThreadStateObject* Thread, int how, const uint64_t* set, uint64_t* oldset);
   uint64_t GuestSigPending(FEX::HLE::ThreadStateObject* Thread, uint64_t* set, size_t sigsetsize);
   uint64_t GuestSigSuspend(FEX::HLE::ThreadStateObject* Thread, uint64_t* set, size_t sigsetsize);
+  uint64_t BeginTemporaryGuestMask(FEX::HLE::ThreadStateObject* Thread, uint64_t GuestSet);
+  void EndTemporaryGuestMask(FEX::HLE::ThreadStateObject* Thread, uint64_t MaskBefore);
   uint64_t GuestSigTimedWait(uint64_t* set, siginfo_t* info, const struct timespec* timeout, size_t sigsetsize);
   uint64_t GuestSignalFD(int fd, const uint64_t* set, size_t sigsetsize, int flags);
   /**  @} */
@@ -291,10 +293,46 @@
   bool HandleSignalPause(FEXCore::Core::InternalThreadState* Thread, int Signal, void* info, void* ucontext);
   bool HandleSIGILL(FEXCore::Core::InternalThreadState* Thread, int Signal, void* info, void* ucontext);
 
-  uint64_t GetNewSigMask(int Signal) const;
+  uint64_t GetNewSigMask(int Signal, uint64_t GuestMask) const;
+  void RestoreGuestMask(FEXCore::Core::InternalThreadState* Thread, void* ucontext, uint64_t Mask);
   uint64_t GetWaitBlockableSignals() const;
+  uint64_t HostMaskForGuestMask(uint64_t GuestMask) const;
+  void CancelWaitForExactState(FEX::HLE::ThreadStateObject* ThreadObject);
+  bool UnlinkAbandonedSignalFrames(FEXCore::Core::InternalThreadState* Thread, uint64_t GuestSP);
+  void ReleaseAbandonedSignalFramesBeforeDelivery(FEXCore::Core::InternalThreadState* Thread, int Signal, void* info, void* ucontext);
+
+public:
+  // Called at the start of a system call, where the guest's stack pointer is exact.
+  bool ReleaseAbandonedSignalFrames(FEXCore::Core::InternalThreadState* Thread);
+
+private:
 };
 
 fextl::unique_ptr<FEX::HLE::SignalDelegator>
 CreateSignalDelegator(FEXCore::Context::Context* CTX, const std::string_view ApplicationName, bool SupportsAVX, bool SupportsSVE256);
+/**
+ * @brief For a system call that takes a signal mask of its own: while it waits, that is the guest's mask, and FEX has
+ * to know it to run the handlers it lets in. Set() is what to give the kernel: guest pointers it would refuse stay as they are.
+ */
+class TemporaryGuestMask final {
+public:
+  TemporaryGuestMask(FEXCore::Core::CpuStateFrame* Frame, const uint64_t* GuestSet, size_t SetSize);
+  ~TemporaryGuestMask();
+  TemporaryGuestMask(const TemporaryGuestMask&) = delete;
+  TemporaryGuestMask& operator=(const TemporaryGuestMask&) = delete;
+
+  const uint64_t* Set() const {
+    return Thread ? &HostMask : GuestSet;
+  }
+
+  // Whether the kernel could read this, without the fault a read from FEX would be.
+  static bool IsReadable(const uint64_t* Address);
+
+private:
+  const uint64_t* GuestSet;
+  FEX::HLE::ThreadStateObject* Thread {};
+  uint64_t MaskBefore {};
+  uint64_t HostMask {};
+};
+
 } // namespace FEX::HLE
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls/Passthrough.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls/Passthrough.cpp
@@ -462,8 +462,6 @@
     REGISTER_SYSCALL_IMPL_X64(mq_notify, SyscallPassthrough2<SYSCALL_DEF(mq_notify)>);
     REGISTER_SYSCALL_IMPL_X64(mq_getsetattr, SyscallPassthrough3<SYSCALL_DEF(mq_getsetattr)>);
     REGISTER_SYSCALL_IMPL_X64(waitid, SyscallPassthrough5<SYSCALL_DEF(waitid)>);
-    REGISTER_SYSCALL_IMPL_X64(pselect6, SyscallPassthrough6<SYSCALL_DEF(pselect6)>);
-    REGISTER_SYSCALL_IMPL_X64(ppoll, SyscallPassthrough5<SYSCALL_DEF(ppoll)>);
     REGISTER_SYSCALL_IMPL_X64(set_robust_list, SyscallPassthrough2<SYSCALL_DEF(set_robust_list)>);
     REGISTER_SYSCALL_IMPL_X64(get_robust_list, SyscallPassthrough3<SYSCALL_DEF(get_robust_list)>);
     REGISTER_SYSCALL_IMPL_X64(sync_file_range, SyscallPassthrough4<SYSCALL_DEF(sync_file_range)>);
@@ -482,7 +480,6 @@
     REGISTER_SYSCALL_IMPL_X64(process_vm_writev, SyscallPassthrough6<SYSCALL_DEF(process_vm_writev)>);
     REGISTER_SYSCALL_IMPL_X64(preadv2, SyscallPassthrough6<SYSCALL_DEF(preadv2)>);
     REGISTER_SYSCALL_IMPL_X64(pwritev2, SyscallPassthrough6<SYSCALL_DEF(pwritev2)>);
-    REGISTER_SYSCALL_IMPL_X64(io_pgetevents, SyscallPassthrough6<SYSCALL_DEF(io_pgetevents)>);
     REGISTER_SYSCALL_IMPL_X64(pidfd_send_signal, SyscallPassthrough4<SYSCALL_DEF(pidfd_send_signal)>);
     REGISTER_SYSCALL_IMPL_X64(process_madvise, SyscallPassthrough5<SYSCALL_DEF(process_madvise)>);
     REGISTER_SYSCALL_IMPL_X64(fadvise64, SyscallPassthrough4<SYSCALL_DEF(fadvise64)>);
@@ -530,7 +527,6 @@
     REGISTER_SYSCALL_IMPL_X32(timerfd_gettime64, SyscallPassthrough2<SYSCALL_DEF(timerfd_gettime)>);
     REGISTER_SYSCALL_IMPL_X32(timerfd_settime64, SyscallPassthrough4<SYSCALL_DEF(timerfd_settime)>);
     REGISTER_SYSCALL_IMPL_X32(utimensat_time64, SyscallPassthrough4<SYSCALL_DEF(utimensat)>);
-    REGISTER_SYSCALL_IMPL_X32(ppoll_time64, SyscallPassthrough5<SYSCALL_DEF(ppoll)>);
     REGISTER_SYSCALL_IMPL_X32(io_pgetevents_time64, SyscallPassthrough6<SYSCALL_DEF(io_pgetevents)>);
     REGISTER_SYSCALL_IMPL_X32(mq_timedsend_time64, SyscallPassthrough5<SYSCALL_DEF(mq_timedsend)>);
     REGISTER_SYSCALL_IMPL_X32(mq_timedreceive_time64, SyscallPassthrough5<SYSCALL_DEF(mq_timedreceive)>);
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls/Thread.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls/Thread.cpp
@@ -208,6 +208,7 @@
 
     // The clone call that was in progress ends here, in the child.
     Thread->Thread->CurrentFrame->InSyscallInfo = 0;
+    Thread->Thread->CurrentFrame->PendingHostSP = 0;
 
     ::syscall(SYS_rt_sigprocmask, SIG_SETMASK, &CloneArgs->SignalMask, nullptr, sizeof(CloneArgs->SignalMask));
 
@@ -288,6 +289,8 @@
   const bool IsVFork = flags & CLONE_VFORK;
   pid_t Result {};
   int VForkFDs[2];
+  int VForkChildFD = -1;
+  bool VForkChildGone = false;
   if (IsVFork) {
     // Use pipes as a mechanism for knowing when the child process is exiting.
     // FEX can't use `waitpid` for this since the child process may want to use it.
@@ -305,6 +308,13 @@
     } else {
       // Close the write end of the pipe.
       close(VForkFDs[1]);
+      // Before the signal mask comes back, so that no handler can reap the child first.
+      if (Result != -1) {
+        const int SavedErrno = errno;
+        VForkChildFD = ::syscall(SYS_pidfd_open, Result, 0);
+        VForkChildGone = VForkChildFD == -1 && errno == ESRCH;
+        errno = SavedErrno;
+      }
     }
   } else {
     Result = CloneFork(flags, exit_signal);
@@ -397,19 +407,27 @@
 
     // VFork needs the parent to wait for the child to exit.
     if (IsVFork) {
-      // Wait for the read end of the pipe to close.
-      pollfd PollFD {};
-      PollFD.fd = VForkFDs[0];
-      PollFD.events = POLLIN | POLLOUT | POLLRDHUP | POLLERR | POLLHUP | POLLNVAL;
+      // Wait for the read end of the pipe to close, or for the child to exit: a descendant that shares the
+      // child's descriptors or that this code never sees holds the pipe open longer than the child lives.
+      pollfd PollFD[2] {};
+      PollFD[0].fd = VForkFDs[0];
+      PollFD[0].events = POLLIN | POLLOUT | POLLRDHUP | POLLERR | POLLHUP | POLLNVAL;
+      const int ChildFD = VForkChildFD;
+      PollFD[1].fd = ChildFD;
+      PollFD[1].events = POLLIN;
 
       // Mask all signals until the child process returns.
       sigset_t SignalMask {};
       sigfillset(&SignalMask);
-      while (ppoll(&PollFD, 1, nullptr, &SignalMask) == -1 && errno == EINTR)
+      // If it has already been reaped, by SIG_IGN or another thread, it has exited, and that is what this waits for.
+      while (!VForkChildGone && ppoll(PollFD, ChildFD >= 0 ? 2 : 1, nullptr, &SignalMask) == -1 && errno == EINTR)
         ;
 
       // Close the read end now.
       close(VForkFDs[0]);
+      if (ChildFD >= 0) {
+        close(ChildFD);
+      }
     }
 
     // Parent
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls.cpp
@@ -899,8 +899,16 @@
   const uint64_t JITPC = reinterpret_cast<uint64_t>(__builtin_extract_return_addr(__builtin_return_address(0)));
   // Take any signal still waiting for an exact state: the guest state is written back here, and the
   // call may block with that signal masked.
+  FEX::HLE::ThreadManager::GetStateObjectFromCPUState(Frame)->SignalInfo.AtSyscallStart = true;
   reinterpret_cast<FEXCore::Core::NonAtomicRefCounter<uint64_t>*>(&FEX::HLE::ThreadManager::GetStateObjectFromCPUState(Frame)->Thread->InterruptFaultPage)
     ->Store(0);
+  FEX::HLE::ThreadManager::GetStateObjectFromCPUState(Frame)->SignalInfo.AtSyscallStart = false;
+  // Frames the guest left: the dispatcher drops them and comes back to the same `syscall` instruction, since nothing
+  // has happened yet. A signal this call brings would otherwise land below them, and its handler may leave as well.
+  if (FEX::HLE::ThreadManager::GetStateObjectFromCPUState(Frame)->SignalInfo.TopSignalContext &&
+      GetSignalDelegator()->ReleaseAbandonedSignalFrames(FEX::HLE::ThreadManager::GetStateObjectFromCPUState(Frame)->Thread)) {
+    return;
+  }
   const auto Is64Bit = Is64BitMode();
 
   // TODO: At some point these will be runtime selectable based on `syscall` versus `int 0x80` entrypoint.
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls.h
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/Syscalls.h
@@ -288,6 +288,7 @@
   ///// VMA (Virtual Memory Area) tracking /////
   static bool HandleSegfault(FEXCore::Core::InternalThreadState* Thread, int Signal, void* info, void* ucontext);
   void MarkGuestExecutableRange(FEXCore::Core::InternalThreadState* Thread, uint64_t Start, uint64_t Length) override;
+  void ProtectWritableViewsOfCode(uint64_t Start, uint64_t Length);
   void InvalidateGuestCodeRange(FEXCore::Core::InternalThreadState* Thread, uint64_t Start, uint64_t Length) override;
   std::optional<FEXCore::ExecutableFileSectionInfo>
   LookupExecutableFileSection(FEXCore::Core::InternalThreadState* Thread, uint64_t GuestAddr) final override;
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsSMCTracking.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsSMCTracking.cpp
@@ -90,6 +90,7 @@
       LogMan::Throw::AFmt(rv == 0, "mprotect({}, {}) failed", Start, Length);
     };
 
+    bool MirrorInCurrentBlock = false;
     if (Entry->second.Flags.Shared) {
       LOGMAN_THROW_A_FMT(Entry->second.Resource, "VMA tracking error");
 
@@ -102,6 +103,9 @@
       do {
         if (VMA->Offset <= Offset && (VMA->Offset + VMA->Length) > Offset) {
           auto FaultBaseMirrored = Offset - VMA->Offset + VMA->Base;
+          MirrorInCurrentBlock = MirrorInCurrentBlock ||
+                                 (Thread->CTX->IsAddressInCodeBuffer(Thread, ArchHelpers::Context::GetPc(ucontext)) &&
+                                  Thread->CTX->IsAddressInCurrentBlock(Thread, FaultBaseMirrored, FEXCore::Utils::FEX_PAGE_SIZE));
 
           if (VMA->Prot.Writable) {
             _SyscallHandler->TM.InvalidateGuestCodeRange(Thread, FaultBaseMirrored, FEXCore::Utils::FEX_PAGE_SIZE, UnprotectRegionCallback);
@@ -118,13 +122,14 @@
 
     auto CTX = Thread->CTX;
     if (CTX->IsAddressInCodeBuffer(Thread, ArchHelpers::Context::GetPc(ucontext)) && !CTX->IsCurrentBlockSingleInst(Thread) &&
-        CTX->IsAddressInCurrentBlock(Thread, FaultAddress & FEXCore::Utils::FEX_PAGE_MASK, FEXCore::Utils::FEX_PAGE_SIZE)) {
+        (MirrorInCurrentBlock || CTX->IsAddressInCurrentBlock(Thread, FaultAddress & FEXCore::Utils::FEX_PAGE_MASK, FEXCore::Utils::FEX_PAGE_SIZE))) {
       // If we are not in a single-instruction block, and the SMC write address could intersect with the current block,
       // reconstruct the context and repeat the faulting instruction as a single-instruction block so any SMC it performs
       // is immediately picked up.
       ThreadObject->SignalInfo.Delegator->SpillSRA(Thread, ucontext, Thread->CurrentFrame->InSyscallInfo & 0xFFFF);
 
-      // Adjust context to return to the dispatcher, reloading SRA from thread state
+      // Adjust context to return to the dispatcher, reloading SRA from thread state, without this block's stack
+      ArchHelpers::Context::SetSp(ucontext, ArchHelpers::Context::GetSp(ucontext) + CTX->GetBlockStackBytesFromHostPC(Thread, ArchHelpers::Context::GetPc(ucontext)));
       const auto& Config = ThreadObject->SignalInfo.Delegator->GetConfig();
       ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
       ArchHelpers::Context::SetArmReg(ucontext, 1, 1); // Set ENTRY_FILL_SRA_SINGLE_INST_REG to force a single step
@@ -165,6 +170,9 @@
         if (Mapping->second.Flags.Shared) {
           LOGMAN_THROW_A_FMT(Mapping->second.Resource, "VMA tracking error");
 
+          // Atomic because several threads hold this lock shared. A view made later holds it exclusively.
+          __atomic_store_n(&Mapping->second.Resource->HasTranslatedCode, true, __ATOMIC_RELAXED);
+
           const auto OffsetBase = ProtectBase - Mapping->first + Mapping->second.Offset;
           const auto OffsetTop = OffsetBase + ProtectSize;
 
@@ -191,7 +199,47 @@
 
           LogMan::Throw::AFmt(rv == 0, "mprotect({}, {}) failed", ProtectBase, ProtectSize);
         }
+      }
+    }
+  }
+}
+
+void SyscallHandler::ProtectWritableViewsOfCode(uint64_t Start, uint64_t Length) {
+  // .NET changes its code through a writable view of the memory it runs from, one it maps for each change, so
+  // MarkGuestExecutableRange never saw it. Writes to such a view fault first and invalidate the mirrors, as with any other.
+  // A system call writing there gets EFAULT instead, as with any page FEX protects, so this waits until there is code.
+  if (SMCChecks != FEXCore::Config::CONFIG_SMC_MTRACK) {
+    return;
+  }
+
+  const auto Base = Start & FEXCore::Utils::FEX_PAGE_MASK;
+  const auto Top = FEXCore::AlignUp(Start + Length, FEXCore::Utils::FEX_PAGE_SIZE);
+  auto Mapping = VMATracking.VMAs.lower_bound(Top);
+
+  while (Mapping != VMATracking.VMAs.begin()) {
+    Mapping--;
+    const auto MapBase = Mapping->first;
+    const auto MapTop = MapBase + Mapping->second.Length;
+    if (MapTop <= Base) {
+      break;
+    }
+    if (!Mapping->second.Flags.Shared || !Mapping->second.Prot.Writable || !Mapping->second.Resource ||
+        !__atomic_load_n(&Mapping->second.Resource->HasTranslatedCode, __ATOMIC_RELAXED)) {
+      continue;
+    }
+
+    const auto ViewBase = std::max(MapBase, Base);
+    const auto OffsetBase = ViewBase - MapBase + Mapping->second.Offset;
+    const auto OffsetTop = OffsetBase + (std::min(MapTop, Top) - ViewBase);
+
+    for (auto VMA = Mapping->second.Resource->FirstVMA; VMA; VMA = VMA->ResourceNextVMA) {
+      if (!VMA->Prot.Executable || VMA->Offset >= OffsetTop || VMA->Offset + VMA->Length <= OffsetBase) {
+        continue;
       }
+      const auto OverlapBase = std::max(VMA->Offset, OffsetBase);
+      const auto OverlapSize = std::min(VMA->Offset + VMA->Length, OffsetTop) - OverlapBase;
+      auto rv = mprotect(reinterpret_cast<void*>(OverlapBase - Mapping->second.Offset + MapBase), OverlapSize, PROT_READ);
+      LogMan::Throw::AFmt(rv == 0, "mprotect({}, {}) failed", OverlapBase, OverlapSize);
     }
   }
 }
@@ -334,6 +382,7 @@
     }
 
     LateMetadata = TrackMmap(Thread, Result, length, prot, flags, fd, offset, CachedSection);
+    ProtectWritableViewsOfCode(Result, Size);
     PendingResourceDeletion = VMATracking.HasPendingResourceDeletions();
   }
 
@@ -408,6 +457,7 @@
       }
     }
     TrackMremap(Thread, reinterpret_cast<uint64_t>(old_address), old_size, new_size, flags, Result);
+    ProtectWritableViewsOfCode(Result, new_size);
   }
 
   InvalidateCodeRangeIfNecessaryOnRemap(Thread, reinterpret_cast<uint64_t>(old_address), Result, old_size, new_size);
@@ -479,6 +529,7 @@
     }
 
     TrackMprotect(Thread, addr, len, prot);
+    ProtectWritableViewsOfCode(reinterpret_cast<uint64_t>(addr), len);
   }
 
   InvalidateCodeRangeIfNecessary(Thread, reinterpret_cast<uint64_t>(addr), len, false);
@@ -544,6 +595,7 @@
 
     Length = stat.shm_segsz;
     TrackShmat(Thread, shmid, Result, shmflg, Length);
+    ProtectWritableViewsOfCode(Result, Length);
     PendingResourceDeletion = VMATracking.HasPendingResourceDeletions();
   }
 
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsVMATracking.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsVMATracking.cpp
@@ -368,7 +368,7 @@
       // This will have the original VMA's protection flags.
 
       // Make new VMA with new flags, insert for length of range
-      auto NewOffset = OffsetDiff + CurrentBase;
+      auto NewOffset = OffsetDiff + Top;
       auto NewLength = CurrentTop - Top;
 
       auto [Iter, Inserted] = VMAs.emplace(Top, VMAEntry {.Resource = Current->Resource,
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsVMATracking.h
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsVMATracking.h
@@ -64,6 +64,9 @@
 
   bool RequiresDelayedCacheLoad = false;
   fextl::vector<Elf64_Phdr> ProgramHeaders;
+
+  // Code from this memory has been translated, so a new writable view of it must not bypass that code's protection.
+  bool HasTranslatedCode = false;
 };
 
 union VMAProt {
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/ThreadManager.h
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/ThreadManager.h
@@ -83,12 +83,19 @@
     // Queue of thread local signal frames that have been deferred.
     // Async signals aren't guaranteed to be delivered in any particular order, but FEX treats them as FILO.
     fextl::vector<DeferredSignalState> DeferredSignalFrames;
-    // A signal went back to the kernel until the guest state is exact. See HandleGuestSignal.
+    // A signal held until the guest state is exact. See HandleGuestSignal.
     bool WaitingForExactState {};
     bool AtCheck {};
     uint32_t CheckPageOpenDepth {};
+    // The innermost signal frame the guest may still return to.
+    void* TopSignalContext {};
+    // While rt_sigsuspend waits, the mask from before the call, for a frame to record.
+    bool SuspendActive {};
+    uint64_t SuspendMaskForFrame {};
     uint64_t MaskBeforeWaiting {};
-    uint64_t ExactStatePC {};
+    int HeldSignal {};
+    bool AtSyscallStart {};
+    siginfo_t HeldInfo {};
   } SignalInfo {};
 
   // Seccomp thread specific data.
@@ -222,7 +229,8 @@
   }
 
   void InvalidateGuestCodeRange(FEXCore::Core::InternalThreadState* CallingThread, uint64_t Start, uint64_t Length) {
-    std::lock_guard lk(ThreadCreationMutex);
+    // This section ends after the lock is gone: a signal waiting for its end runs a handler, which may come back here.
+    auto lk = FEXCore::GuardSignalDeferringSectionWithFallback(ThreadCreationMutex, CallingThread);
 
     // Potential deferred since Thread might not be valid.
     // Thread object isn't valid very early in frontend's initialization.
@@ -236,7 +244,8 @@
 
   void InvalidateGuestCodeRange(FEXCore::Core::InternalThreadState* CallingThread, uint64_t Start, uint64_t Length,
                                 FEXCore::Context::CodeRangeInvalidationFn after_callback) {
-    std::lock_guard lk(ThreadCreationMutex);
+    // This section ends after the lock is gone: a signal waiting for its end runs a handler, which may come back here.
+    auto lk = FEXCore::GuardSignalDeferringSectionWithFallback(ThreadCreationMutex, CallingThread);
 
     // Potential deferred since Thread might not be valid.
     // Thread object isn't valid very early in frontend's initialization.
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/x32/EPoll.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/x32/EPoll.cpp
@@ -6,6 +6,7 @@
 $end_info$
 */
 
+#include "LinuxSyscalls/SignalDelegator.h"
 #include "LinuxSyscalls/Syscalls.h"
 #include "LinuxSyscalls/Types.h"
 #include "LinuxSyscalls/x32/Syscalls.h"
@@ -68,7 +69,11 @@
                                int timeout, const uint64_t* sigmask, size_t sigsetsize) -> uint64_t {
                               fextl::vector<struct epoll_event> Events(std::max(0, maxevent));
 
-                              uint64_t Result = ::syscall(SYSCALL_DEF(epoll_pwait), epfd, Events.data(), maxevent, timeout, sigmask, sigsetsize);
+                              uint64_t Result;
+                              {
+                                FEX::HLE::TemporaryGuestMask Mask(Frame, sigmask, sigsetsize);
+                                Result = ::syscall(SYSCALL_DEF(epoll_pwait), epfd, Events.data(), maxevent, timeout, Mask.Set(), sigsetsize);
+                              }
 
                               if (Result != -1) {
                                 FaultSafeUserMemAccess::VerifyIsWritable(events, sizeof(FEX::HLE::x32::epoll_event32) * Result);
@@ -92,8 +97,11 @@
                                 timed_ptr = &tp64;
                               }
 
-                              uint64_t Result =
-                                ::syscall(SYSCALL_DEF(epoll_pwait2), epfd, Events.data(), maxevent, timed_ptr, sigmask, sigsetsize);
+                              uint64_t Result;
+                              {
+                                FEX::HLE::TemporaryGuestMask Mask(Frame, sigmask, sigsetsize);
+                                Result = ::syscall(SYSCALL_DEF(epoll_pwait2), epfd, Events.data(), maxevent, timed_ptr, Mask.Set(), sigsetsize);
+                              }
 
                               if (Result != -1) {
                                 FaultSafeUserMemAccess::VerifyIsWritable(events, sizeof(FEX::HLE::x32::epoll_event32) * Result);
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/x32/FD.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/x32/FD.cpp
@@ -5,6 +5,7 @@
 $end_info$
 */
 
+#include "LinuxSyscalls/SignalDelegator.h"
 #include "LinuxSyscalls/Syscalls.h"
 #include "LinuxSyscalls/x32/IoctlEmulation.h"
 #include "LinuxSyscalls/x32/Syscalls.h"
@@ -237,6 +238,14 @@
 };
 
 void RegisterFD(FEX::HLE::SyscallHandler* Handler) {
+  REGISTER_SYSCALL_IMPL_X32(ppoll_time64,
+                            [](FEXCore::Core::CpuStateFrame* Frame, struct pollfd* fds, nfds_t nfds, struct timespec* timeout,
+                               const uint64_t* sigmask, size_t sigsetsize) -> uint64_t {
+                              FEX::HLE::TemporaryGuestMask Mask(Frame, sigmask, sigsetsize);
+                              uint64_t Result = ::syscall(SYSCALL_DEF(ppoll), fds, nfds, timeout, Mask.Set(), sigsetsize);
+                              SYSCALL_ERRNO();
+                            });
+
   REGISTER_SYSCALL_IMPL_X32(ppoll,
                             [](FEXCore::Core::CpuStateFrame* Frame, struct pollfd* fds, nfds_t nfds, timespec32* timeout_ts,
                                const uint64_t* sigmask, size_t sigsetsize) -> uint64_t {
@@ -253,7 +262,11 @@
                                 timed_ptr = &tp64;
                               }
 
-                              uint64_t Result = ::syscall(SYSCALL_DEF(ppoll), fds, nfds, timed_ptr, sigmask, sigsetsize);
+                              uint64_t Result;
+                              {
+                                FEX::HLE::TemporaryGuestMask Mask(Frame, sigmask, sigsetsize);
+                                Result = ::syscall(SYSCALL_DEF(ppoll), fds, nfds, timed_ptr, Mask.Set(), sigsetsize);
+                              }
 
                               if (timeout_ts) {
                                 struct timespec32 timeout {};
@@ -613,12 +626,10 @@
                               fd_set Host_readfds;
                               fd_set Host_writefds;
                               fd_set Host_exceptfds;
-                              sigset_t HostSet {};
 
                               FD_ZERO(&Host_readfds);
                               FD_ZERO(&Host_writefds);
                               FD_ZERO(&Host_exceptfds);
-                              sigemptyset(&HostSet);
 
                               // Round up to the full 32bit word
                               const uint32_t NumWords = FEXCore::AlignUp(nfds, 32) / 32;
@@ -634,20 +645,14 @@
                               }
 
                               FaultSafeUserMemAccess::VerifyIsReadableOrNull(sigmaskpack, sizeof(*sigmaskpack));
-                              if (sigmaskpack && sigmaskpack->sigset) {
-                                FaultSafeUserMemAccess::VerifyIsReadable(sigmaskpack->sigset, sizeof(*sigmaskpack->sigset));
-                                uint64_t* sigmask = sigmaskpack->sigset;
-                                size_t sigsetsize = sigmaskpack->size;
-                                for (int32_t i = 0; i < (sigsetsize * 8); ++i) {
-                                  if (*sigmask & (1ULL << i)) {
-                                    sigaddset(&HostSet, i + 1);
-                                  }
-                                }
+                              const uint64_t* sigmask = sigmaskpack ? static_cast<const uint64_t*>(sigmaskpack->sigset) : nullptr;
+                              uint64_t Result;
+                              {
+                                FEX::HLE::TemporaryGuestMask Mask(Frame, sigmask, sigmaskpack ? sigmaskpack->size : 0);
+                                Result = ::pselect(nfds, readfds ? &Host_readfds : nullptr, writefds ? &Host_writefds : nullptr,
+                                                   exceptfds ? &Host_exceptfds : nullptr, timeout ? &tp64 : nullptr, reinterpret_cast<const sigset_t*>(Mask.Set()));
                               }
 
-                              uint64_t Result = ::pselect(nfds, readfds ? &Host_readfds : nullptr, writefds ? &Host_writefds : nullptr,
-                                                          exceptfds ? &Host_exceptfds : nullptr, timeout ? &tp64 : nullptr, &HostSet);
-
                               if (readfds) {
                                 SetGuestFDSet(nfds, NumWords, Host_readfds, readfds);
                               }
@@ -723,12 +728,10 @@
                               fd_set Host_readfds;
                               fd_set Host_writefds;
                               fd_set Host_exceptfds;
-                              sigset_t HostSet {};
 
                               FD_ZERO(&Host_readfds);
                               FD_ZERO(&Host_writefds);
                               FD_ZERO(&Host_exceptfds);
-                              sigemptyset(&HostSet);
 
                               // Round up to the full 32bit word
                               const uint32_t NumWords = FEXCore::AlignUp(nfds, 32) / 32;
@@ -744,20 +747,14 @@
                               }
 
                               FaultSafeUserMemAccess::VerifyIsReadableOrNull(sigmaskpack, sizeof(*sigmaskpack));
-                              if (sigmaskpack && sigmaskpack->sigset) {
-                                FaultSafeUserMemAccess::VerifyIsReadable(sigmaskpack->sigset, sizeof(*sigmaskpack->sigset));
-                                uint64_t* sigmask = sigmaskpack->sigset;
-                                size_t sigsetsize = sigmaskpack->size;
-                                for (int32_t i = 0; i < (sigsetsize * 8); ++i) {
-                                  if (*sigmask & (1ULL << i)) {
-                                    sigaddset(&HostSet, i + 1);
-                                  }
-                                }
+                              const uint64_t* sigmask = sigmaskpack ? static_cast<const uint64_t*>(sigmaskpack->sigset) : nullptr;
+                              uint64_t Result;
+                              {
+                                FEX::HLE::TemporaryGuestMask Mask(Frame, sigmask, sigmaskpack ? sigmaskpack->size : 0);
+                                Result = ::pselect(nfds, readfds ? &Host_readfds : nullptr, writefds ? &Host_writefds : nullptr,
+                                                   exceptfds ? &Host_exceptfds : nullptr, timeout, reinterpret_cast<const sigset_t*>(Mask.Set()));
                               }
 
-                              uint64_t Result = ::pselect(nfds, readfds ? &Host_readfds : nullptr, writefds ? &Host_writefds : nullptr,
-                                                          exceptfds ? &Host_exceptfds : nullptr, timeout, &HostSet);
-
                               if (readfds) {
                                 SetGuestFDSet(nfds, NumWords, Host_readfds, readfds);
                               }
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/x64/EPoll.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/x64/EPoll.cpp
@@ -6,6 +6,7 @@
 $end_info$
 */
 
+#include "LinuxSyscalls/SignalDelegator.h"
 #include "LinuxSyscalls/Syscalls.h"
 #include "LinuxSyscalls/Types.h"
 #include "LinuxSyscalls/x64/Syscalls.h"
@@ -62,7 +63,11 @@
                                const uint64_t* sigmask, size_t sigsetsize) -> uint64_t {
                               fextl::vector<struct epoll_event> Events(std::max(0, maxevent));
 
-                              uint64_t Result = ::syscall(SYSCALL_DEF(epoll_pwait), epfd, Events.data(), maxevent, timeout, sigmask, sigsetsize);
+                              uint64_t Result;
+                              {
+                                FEX::HLE::TemporaryGuestMask Mask(Frame, sigmask, sigsetsize);
+                                Result = ::syscall(SYSCALL_DEF(epoll_pwait), epfd, Events.data(), maxevent, timeout, Mask.Set(), sigsetsize);
+                              }
 
                               if (Result != -1) {
                                 FaultSafeUserMemAccess::VerifyIsWritable(events, sizeof(FEX::HLE::epoll_event_x86) * Result);
@@ -79,7 +84,11 @@
                                timespec* timeout, const uint64_t* sigmask, size_t sigsetsize) -> uint64_t {
                               fextl::vector<struct epoll_event> Events(std::max(0, maxevent));
 
-                              uint64_t Result = ::syscall(SYSCALL_DEF(epoll_pwait2), epfd, Events.data(), maxevent, timeout, sigmask, sigsetsize);
+                              uint64_t Result;
+                              {
+                                FEX::HLE::TemporaryGuestMask Mask(Frame, sigmask, sigsetsize);
+                                Result = ::syscall(SYSCALL_DEF(epoll_pwait2), epfd, Events.data(), maxevent, timeout, Mask.Set(), sigsetsize);
+                              }
 
                               if (Result != -1) {
                                 FaultSafeUserMemAccess::VerifyIsWritable(events, sizeof(FEX::HLE::epoll_event_x86) * Result);
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/x64/FD.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/x64/FD.cpp
@@ -6,6 +6,7 @@
 */
 
 #include "LinuxSyscalls/FileManagement.h"
+#include "LinuxSyscalls/SignalDelegator.h"
 #include "LinuxSyscalls/Syscalls.h"
 #include "LinuxSyscalls/x64/Syscalls.h"
 #include "LinuxSyscalls/x64/Types.h"
@@ -14,6 +15,7 @@
 #include <FEXCore/Utils/MathUtils.h>
 
 #include <fcntl.h>
+#include <linux/aio_abi.h>
 #include <poll.h>
 #include <stdint.h>
 #include <sys/select.h>
@@ -28,7 +30,55 @@
 #include <unistd.h>
 
 namespace FEX::HLE::x64 {
+// pselect6 and io_pgetevents pass their mask and its size in one of these.
+struct SigsetArgs {
+  const uint64_t* Set;
+  size_t Size;
+};
+
 void RegisterFD(FEX::HLE::SyscallHandler* Handler) {
+  REGISTER_SYSCALL_IMPL_X64(ppoll,
+                            [](FEXCore::Core::CpuStateFrame* Frame, struct pollfd* fds, nfds_t nfds, struct timespec* timeout,
+                               const uint64_t* sigmask, size_t sigsetsize) -> uint64_t {
+                              FEX::HLE::TemporaryGuestMask Mask(Frame, sigmask, sigsetsize);
+                              uint64_t Result = ::syscall(SYSCALL_DEF(ppoll), fds, nfds, timeout, Mask.Set(), sigsetsize);
+                              SYSCALL_ERRNO();
+                            });
+
+  REGISTER_SYSCALL_IMPL_X64(pselect6,
+                            [](FEXCore::Core::CpuStateFrame* Frame, int nfds, fd_set* readfds, fd_set* writefds, fd_set* exceptfds,
+                               struct timespec* timeout, const SigsetArgs* args) -> uint64_t {
+                              SigsetArgs Guest {};
+                              const auto* Words = reinterpret_cast<const uint64_t*>(args);
+                              const bool HaveArgs = args && FEX::HLE::TemporaryGuestMask::IsReadable(Words) && FEX::HLE::TemporaryGuestMask::IsReadable(Words + 1);
+                              if (HaveArgs) {
+                                Guest = *args;
+                              }
+                              FEX::HLE::TemporaryGuestMask Mask(Frame, Guest.Set, Guest.Size);
+                              SigsetArgs Host;
+                              Host.Set = Mask.Set();
+                              Host.Size = Guest.Size;
+                              uint64_t Result = ::syscall(SYSCALL_DEF(pselect6), nfds, readfds, writefds, exceptfds, timeout, HaveArgs ? &Host : args);
+                              SYSCALL_ERRNO();
+                            });
+
+  REGISTER_SYSCALL_IMPL_X64(io_pgetevents,
+                            [](FEXCore::Core::CpuStateFrame* Frame, aio_context_t ctx_id, long min_nr, long nr, struct io_event* events,
+                               struct timespec* timeout, const SigsetArgs* args) -> uint64_t {
+                              SigsetArgs Guest {};
+                              const auto* Words = reinterpret_cast<const uint64_t*>(args);
+                              const bool HaveArgs = args && FEX::HLE::TemporaryGuestMask::IsReadable(Words) && FEX::HLE::TemporaryGuestMask::IsReadable(Words + 1);
+                              if (HaveArgs) {
+                                Guest = *args;
+                              }
+                              FEX::HLE::TemporaryGuestMask Mask(Frame, Guest.Set, Guest.Size);
+                              SigsetArgs Host;
+                              Host.Set = Mask.Set();
+                              Host.Size = Guest.Size;
+                              uint64_t Result = ::syscall(SYSCALL_DEF(io_pgetevents), ctx_id, min_nr, nr, events, timeout, HaveArgs ? &Host : args);
+                              SYSCALL_ERRNO();
+                            });
+
   REGISTER_SYSCALL_IMPL_X64(
     select, [](FEXCore::Core::CpuStateFrame* Frame, int nfds, fd_set* readfds, fd_set* writefds, fd_set* exceptfds, struct timeval* timeout) -> uint64_t {
       ///< All FD arrays need to be writable
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
@@ -976,8 +976,10 @@
   SignalHandler& Handler = HostHandlers[Signal];
 
   // A fault cannot wait. If the guest blocks or ignores it, the kernel ends the program rather than run or skip it.
-  if (!IsAsyncSignal(&SigInfo, Signal) && ((ThreadObject->SignalInfo.CurrentSignalMask.Val & (1ULL << (Signal - 1))) ||
-                                           Handler.GuestAction.sigaction_handler.handler == SIG_IGN)) {
+  const bool ForceDefault = !IsAsyncSignal(&SigInfo, Signal) &&
+                            ((ThreadObject->SignalInfo.CurrentSignalMask.Val & (1ULL << (Signal - 1))) ||
+                             Handler.GuestAction.sigaction_handler.handler == SIG_IGN);
+  if (ForceDefault) {
     Handler.GuestAction.sigaction_handler.handler = SIG_DFL;
   }
 
@@ -1026,12 +1028,18 @@
   }
 
   // Unhandled crash
+  // A forced fatal guest fault must not return to an inherited ignored or custom host action.
+  auto OldAction = Handler.OldAction;
+  if (ForceDefault) {
+    OldAction = {};
+    OldAction.handler = SIG_DFL;
+  }
   // Call back in to the previous handler
-  if (Handler.OldAction.sa_flags & SA_SIGINFO) {
-    Handler.OldAction.sigaction(Signal, &SigInfo, UContext);
-  } else if (Handler.OldAction.handler == SIG_IGN || (Handler.OldAction.handler == SIG_DFL && Handler.DefaultBehaviour == DEFAULT_IGNORE)) {
+  if (OldAction.sa_flags & SA_SIGINFO) {
+    OldAction.sigaction(Signal, &SigInfo, UContext);
+  } else if (OldAction.handler == SIG_IGN || (OldAction.handler == SIG_DFL && Handler.DefaultBehaviour == DEFAULT_IGNORE)) {
     // Do nothing
-  } else if (Handler.OldAction.handler == SIG_DFL && (Handler.DefaultBehaviour == DEFAULT_COREDUMP || Handler.DefaultBehaviour == DEFAULT_TERM)) {
+  } else if (OldAction.handler == SIG_DFL && (Handler.DefaultBehaviour == DEFAULT_COREDUMP || Handler.DefaultBehaviour == DEFAULT_TERM)) {
     CTX->FlushAndCloseCodeMap();
 
 #ifndef FEX_DISABLE_TELEMETRY
@@ -1060,7 +1068,7 @@
       FHU::Syscalls::tgkill(::getpid(), FHU::Syscalls::gettid(), Signal);
     }
   } else {
-    Handler.OldAction.handler(Signal);
+    OldAction.handler(Signal);
   }
 }
 
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
@@ -1030,7 +1030,7 @@
   // Unhandled crash
   // A forced fatal guest fault must not return to an inherited ignored or custom host action.
   auto OldAction = Handler.OldAction;
-  if (ForceDefault) {
+  if (ForceDefault || (!IsAsyncSignal(&SigInfo, Signal) && OldAction.handler == SIG_IGN)) {
     OldAction = {};
     OldAction.handler = SIG_DFL;
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
