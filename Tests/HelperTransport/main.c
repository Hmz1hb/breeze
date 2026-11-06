#include "CHardware.h"
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// Real separate, signed processes exercise the Unix socket audit-token check.
// This fixture does not open the SMC or change fan settings.
int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--client")) {
        int fd = breeze_connect(argv[2]);
        if (fd < 0) return 2;
        char reply[8];
        int received = breeze_receive(fd, reply, sizeof(reply), 5000);
        close(fd);
        return received > 0 ? 0 : 3;
    }
    if (argc != 4) return 4;
    char path[] = "/private/tmp/breeze-transport.XXXXXX";
    if (!mkdtemp(path)) return 5;
    char socket_path[104];
    snprintf(socket_path, sizeof(socket_path), "%s/control.sock", path);
    int listener = breeze_listen(socket_path);
    if (listener < 0) return 6;
    pid_t child;
    char *child_args[] = {argv[1], "--client", socket_path, NULL};
    if (posix_spawn(&child, argv[1], NULL, NULL, child_args, environ)) return 7;
    int fd = breeze_accept(listener, 5000);
    if (fd < 0) return 8;
    int accepted = breeze_authenticate_peer(fd, argv[3]) == 0;
    int expected = atoi(argv[2]);
    breeze_send(fd, "done\n", 5);
    close(fd);
    close(listener);
    int status;
    waitpid(child, &status, 0);
    unlink(socket_path);
    rmdir(path);
    if (accepted != expected || !WIFEXITED(status) || WEXITSTATUS(status)) {
        fprintf(stderr, "Peer authentication: expected %d, got %d; child status %d\n", expected, accepted, status);
        return 9;
    }
    printf("PASS: %s (%s)\n", argv[1], accepted ? "accepted" : "rejected");
    return 0;
}
