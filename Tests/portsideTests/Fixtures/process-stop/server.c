#include <arpa/inet.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

// Disposable loopback listener. EOF on stdin exits even when SIGTERM is ignored.
int main(int argc, char **argv) {
    if (argc > 1) signal(SIGTERM, SIG_IGN);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof(address)) || listen(fd, 1)) return 2;
    socklen_t size = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &size)) return 3;
    printf("%u\n", ntohs(address.sin_port));
    fflush(stdout);
    char byte;
    while (read(STDIN_FILENO, &byte, 1) > 0) {}
    close(fd);
    return 0;
}
