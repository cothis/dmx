#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
static _Atomic int client_dups = 0;
static int review_fcntl(int fd, int command, ...) {
    uintptr_t argument = 0;
    va_list args;
    va_start(args, command);
    switch (command) {
        case F_GETFD: case F_GETFL: case F_GETOWN: break;
        case F_DUPFD: case F_DUPFD_CLOEXEC: case F_SETFD: case F_SETFL: case F_SETOWN:
        case F_NOCACHE: case F_RDAHEAD: case F_SETNOSIGPIPE:
            argument = (uintptr_t)va_arg(args, int); break;
        default: argument = (uintptr_t)va_arg(args, void *); break;
    }
    va_end(args);
    const char *target = getenv("DMX_REVIEW_CLIENT_FD");
    if (target && fd == atoi(target) && command == F_DUPFD_CLOEXEC &&
        atomic_fetch_add(&client_dups, 1) == 1) {
        static const char message[] = "fault injected: second client frame dup returns EMFILE\n";
        write(2, message, sizeof(message) - 1);
        errno = EMFILE;
        return -1;
    }
    return fcntl(fd, command, argument);
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
interpose __attribute__((section("__DATA,__interpose"))) = { (const void *)review_fcntl, (const void *)fcntl };
