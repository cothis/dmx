#include <poll.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>
static _Atomic int socket_polls = 0;
static int gated_poll(struct pollfd *fds, nfds_t count, int timeout) {
    const char *orig = getenv("DMX_GATE_ORIGINAL"), *copy = getenv("DMX_GATE_COPY");
    if (count == 1 && orig && (fds[0].fd == atoi(orig) || (copy && fds[0].fd == atoi(copy))) &&
        atomic_fetch_add(&socket_polls, 1) == 1) {
        char byte = 'G';
        if (write(atoi(getenv("DMX_GATE_NOTIFY")), &byte, 1) != 1) _exit(91);
        if (read(atoi(getenv("DMX_GATE_RELEASE")), &byte, 1) != 1) _exit(92);
    }
    return poll(fds, count, timeout);
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
interpose __attribute__((section("__DATA,__interpose"))) = { (const void *)gated_poll, (const void *)poll };
