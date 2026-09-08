/* Runtime half of gate 5: linking libchdb.a must not change what posix_spawn does
 * (chdb-io/chdb-core#216).
 *
 * The archive used to carry base/glibc-compatibility's posix_spawn, a partial
 * reimplementation that ignores file actions and reports success anyway. A strong
 * definition in an archive displaces libc's for the whole program, so every consumer that
 * spawns with a redirection lost it silently - Rust's std::process::Command spawns that
 * way, and ten chdb-rust tests printed their answers into the CI log while the parent read
 * an empty pipe.
 *
 * That is what this reproduces: spawn `echo` with its stdout dup2'd onto a pipe and read
 * the word back. The symbol half of the gate checks the archive defines no posix_spawn;
 * this half checks the one that gets called behaves like libc's, which is the property that
 * actually matters and the only one that survives a change in how the archive is assembled.
 *
 * The pipe is O_CLOEXEC so a stub that drops the file actions fails as a short read rather
 * than as a hang: the child then inherits the parent's stdout, both of its pipe descriptors
 * close at exec, and the parent sees EOF. alarm() covers the rest.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char ** environ;

#define WORD "chdb-spawn-ok"
#define PROBE_TIMEOUT_SECONDS 30

int main(void)
{
    int fds[2];
    if (pipe(fds) != 0)
    {
        fprintf(stderr, "spawn probe: pipe failed: %s\n", strerror(errno));
        return 1;
    }
    /* Set after the fact rather than with pipe2(): pipe2 is one of the calls
       base/glibc-compatibility also replaces, and the probe should not depend on it. */
    for (int i = 0; i < 2; ++i)
    {
        if (fcntl(fds[i], F_SETFD, FD_CLOEXEC) != 0)
        {
            fprintf(stderr, "spawn probe: FD_CLOEXEC failed: %s\n", strerror(errno));
            return 1;
        }
    }

    posix_spawn_file_actions_t actions;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc != 0)
    {
        fprintf(stderr, "spawn probe: file_actions_init failed: %s\n", strerror(rc));
        return 1;
    }
    /* dup2 clears FD_CLOEXEC on the new descriptor, so the child's stdout survives exec
       while the two originals do not. */
    rc = posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    if (rc == 0)
        rc = posix_spawn_file_actions_addclose(&actions, fds[0]);
    if (rc == 0)
        rc = posix_spawn_file_actions_addclose(&actions, fds[1]);
    if (rc != 0)
    {
        fprintf(stderr, "spawn probe: adding a file action failed: %s\n", strerror(rc));
        return 1;
    }

    char * const argv[] = {(char *)"echo", (char *)WORD, NULL};
    pid_t pid = -1;
    rc = posix_spawnp(&pid, "echo", &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0)
    {
        fprintf(stderr, "spawn probe: posix_spawnp failed: %s\n", strerror(rc));
        return 1;
    }
    close(fds[1]);

    alarm(PROBE_TIMEOUT_SECONDS);

    char buffer[64] = {0};
    size_t filled = 0;
    for (;;)
    {
        ssize_t n = read(fds[0], buffer + filled, sizeof(buffer) - 1 - filled);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            break;
        filled += (size_t)n;
        if (filled == sizeof(buffer) - 1)
            break;
    }
    close(fds[0]);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
        ;
    alarm(0);

    if (strncmp(buffer, WORD, strlen(WORD)) != 0)
    {
        fprintf(stderr,
                "spawn probe: expected \"%s\" on the pipe, read %zu byte(s): \"%s\"\n",
                WORD, filled, buffer);
        fprintf(stderr,
                "spawn probe: the posix_spawn that ran ignored its file actions, so the "
                "archive is still overriding libc's - see chdb-io/chdb-core#216\n");
        return 1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
    {
        fprintf(stderr, "spawn probe: child did not exit cleanly (status %d)\n", status);
        return 1;
    }

    printf("spawn probe: file actions honoured, read \"%s\" from the pipe\n", WORD);
    return 0;
}
