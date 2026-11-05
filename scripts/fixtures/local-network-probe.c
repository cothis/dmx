// Reports once a second what macOS's local network privacy does to this process. Each build gets a
// new Mach-O UUID from TAG, which is what a release changes. It never exits on a failure: macOS does
// not show its alert to a launchd agent that gives up at once (Apple TN3179).
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static const char *multicast(void) {
    static char result[64];
    int fd = socket(AF_INET, SOCK_DGRAM, 0), on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    struct sockaddr_in to = {.sin_len = sizeof to, .sin_family = AF_INET, .sin_port = htons(9)};
    to.sin_addr.s_addr = inet_addr("224.0.0.251");
    int failed = connect(fd, (void *)&to, sizeof to) || send(fd, 0, 0, 0) < 0;
    snprintf(result, sizeof result, "%s", failed ? strerror(errno) : "ok");
    close(fd);
    return result;
}

static const char *gateway(const char *host) {
    static char result[64];
    int fd = socket(AF_INET, SOCK_STREAM, 0), error = 0;
    fcntl(fd, F_SETFL, O_NONBLOCK);
    struct sockaddr_in to = {.sin_len = sizeof to, .sin_family = AF_INET, .sin_port = htons(80)};
    to.sin_addr.s_addr = inet_addr(host);
    if (connect(fd, (void *)&to, sizeof to)) error = errno;
    if (error == EINPROGRESS) {
        fd_set writable;
        FD_ZERO(&writable);
        FD_SET(fd, &writable);
        struct timeval wait = {0, 500000};
        socklen_t size = sizeof error;
        if (select(fd + 1, 0, &writable, 0, &wait) <= 0) error = ETIMEDOUT;
        else getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size);
    }
    snprintf(result, sizeof result, "%s", error ? strerror(error) : "ok");
    close(fd);
    return result;
}

int main(int argc, char **argv) {
    if (argc < 2 || !strcmp(argv[1], "--version")) {
        puts(TAG);
        return 0;
    }
    for (int i = 0; i < 1800; i++) {
        printf("%.3f %s multicast=%s", (double)time(0), TAG, multicast());
        printf(" gateway=%s\n", gateway(argv[1]));
        fflush(stdout);
        sleep(1);
    }
}
