/*
 * Resource-limit and confinement launcher for the decoder (DESIGN.md
 * sections 3 and 7).
 *
 *   launcher [--seccomp POLICY] [--landlock-ro PATH]... [--landlock-rw PATH]...
 *            [--require-landlock]
 *            CPU_SECONDS ADDRESS_SPACE_BYTES WALL_SECONDS OUTPUT_BYTES
 *            -- PROGRAM ARGS...
 *
 * Forks once. The child confines itself and execs the program with an
 * empty environment:
 *   - Landlock (when given paths): filesystem access is limited to the
 *     listed read-only and read-write paths (needs no privileges);
 *   - rlimits: CPU, address space, output file size, 16 open files, no new
 *     processes (RLIMIT_NPROC=0) and no core dumps;
 *   - a wall-clock alarm that survives exec (SIGALRM kills the program);
 *   - no_new_privs and the seccomp allowlist (via libminijail, BSD-3).
 * The parent waits and exits with the child's status, or 128 + signal, so
 * callers can tell a crash (SIGSEGV), CPU limit (SIGKILL after SIGXCPU),
 * wall-clock limit (SIGALRM) and seccomp violation (SIGSYS) apart.
 *
 * Under minijail (namespaces, pivot_root, uid change) this adds the wall
 * clock and precise status. Without namespaces (unprivileged workers) the
 * Landlock + seccomp + rlimit tier is the documented fallback.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/landlock.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#include "libminijail.h"

#define MAX_PATHS 8

static rlim_t number(const char *text) {
  char *end = NULL;
  errno = 0;
  unsigned long long value = strtoull(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0') {
    fprintf(stderr, "launcher: bad numeric argument\n");
    exit(4);
  }
  return (rlim_t)value;
}

static void limit(int resource, rlim_t value) {
  struct rlimit l = {value, value};
  if (setrlimit(resource, &l) != 0) {
    perror("launcher: setrlimit");
    _exit(4);
  }
}

/* Returns 0 on success, -1 if Landlock is unavailable on this kernel. */
static int apply_landlock(char **ro, int nro, char **rw, int nrw) {
  int abi = (int)syscall(SYS_landlock_create_ruleset, NULL, 0,
                         LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 1) return -1;
  uint64_t read_access = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR |
                         LANDLOCK_ACCESS_FS_EXECUTE;
  uint64_t write_access = LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_MAKE_REG |
                          LANDLOCK_ACCESS_FS_REMOVE_FILE;
  uint64_t handled = read_access | write_access | LANDLOCK_ACCESS_FS_REMOVE_DIR |
                     LANDLOCK_ACCESS_FS_MAKE_CHAR | LANDLOCK_ACCESS_FS_MAKE_DIR |
                     LANDLOCK_ACCESS_FS_MAKE_SOCK | LANDLOCK_ACCESS_FS_MAKE_FIFO |
                     LANDLOCK_ACCESS_FS_MAKE_BLOCK | LANDLOCK_ACCESS_FS_MAKE_SYM;
  if (abi >= 2) handled |= LANDLOCK_ACCESS_FS_REFER;
  if (abi >= 3) handled |= LANDLOCK_ACCESS_FS_TRUNCATE;
  if (abi >= 3) write_access |= LANDLOCK_ACCESS_FS_TRUNCATE;
  struct landlock_ruleset_attr attr = {.handled_access_fs = handled};
  int ruleset = (int)syscall(SYS_landlock_create_ruleset, &attr, sizeof attr, 0);
  if (ruleset < 0) return -1;
  for (int pass = 0; pass < 2; pass++) {
    char **paths = pass == 0 ? ro : rw;
    int n = pass == 0 ? nro : nrw;
    for (int i = 0; i < n; i++) {
      int fd = open(paths[i], O_PATH | O_CLOEXEC);
      if (fd < 0) {
        perror("launcher: landlock path");
        _exit(4);
      }
      struct landlock_path_beneath_attr rule = {
          .allowed_access = pass == 0 ? read_access : (read_access | write_access),
          .parent_fd = fd,
      };
      /* Files (not directories) accept only file rights. */
      if (syscall(SYS_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH, &rule, 0) != 0) {
        rule.allowed_access &= LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_EXECUTE |
                               LANDLOCK_ACCESS_FS_WRITE_FILE |
                               (abi >= 3 ? LANDLOCK_ACCESS_FS_TRUNCATE : 0);
        if (syscall(SYS_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH, &rule, 0) != 0) {
          perror("launcher: landlock rule");
          _exit(4);
        }
      }
      close(fd);
    }
  }
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 ||
      syscall(SYS_landlock_restrict_self, ruleset, 0) != 0) {
    perror("launcher: landlock restrict");
    _exit(4);
  }
  close(ruleset);
  return 0;
}

int main(int argc, char **argv) {
  const char *policy = NULL;
  char *ro[MAX_PATHS], *rw[MAX_PATHS];
  int nro = 0, nrw = 0, require_landlock = 0, i = 1;
  for (; i < argc && strncmp(argv[i], "--", 2) == 0 && argv[i][2] != '\0'; i++) {
    if (strcmp(argv[i], "--seccomp") == 0 && i + 1 < argc) policy = argv[++i];
    else if (strcmp(argv[i], "--landlock-ro") == 0 && i + 1 < argc && nro < MAX_PATHS) ro[nro++] = argv[++i];
    else if (strcmp(argv[i], "--landlock-rw") == 0 && i + 1 < argc && nrw < MAX_PATHS) rw[nrw++] = argv[++i];
    else if (strcmp(argv[i], "--require-landlock") == 0) require_landlock = 1;
    else {
      fprintf(stderr, "launcher: unknown option %s\n", argv[i]);
      return 4;
    }
  }
  if (argc - i < 6 || strcmp(argv[i + 4], "--") != 0) {
    fprintf(stderr, "usage: launcher [options] CPU AS WALL FSIZE -- PROGRAM ARGS...\n");
    return 4;
  }
  rlim_t cpu = number(argv[i]), as = number(argv[i + 1]), wall = number(argv[i + 2]),
         fsize = number(argv[i + 3]);
  char **program = argv + i + 5;

  pid_t child = fork();
  if (child < 0) {
    perror("launcher: fork");
    return 4;
  }
  if (child == 0) {
    /* Parse the seccomp policy before Landlock forbids reading it. */
    struct minijail *jail = NULL;
    if (policy) {
      jail = minijail_new();
      minijail_no_new_privs(jail);
      minijail_parse_seccomp_filters(jail, policy);
      minijail_use_seccomp_filter(jail);
    }
    if (nro + nrw > 0 && apply_landlock(ro, nro, rw, nrw) != 0) {
      if (require_landlock) {
        fprintf(stderr, "launcher: Landlock is unavailable on this kernel\n");
        _exit(4);
      }
      fprintf(stderr, "launcher: warning: Landlock unavailable; filesystem not confined\n");
    }
    limit(RLIMIT_CPU, cpu);
    limit(RLIMIT_AS, as);
    limit(RLIMIT_FSIZE, fsize);
    limit(RLIMIT_NOFILE, 16);
    limit(RLIMIT_NPROC, 0);
    limit(RLIMIT_CORE, 0);
    if (jail) {
      minijail_enter(jail);
      minijail_destroy(jail);
    }
    alarm((unsigned)wall);
    char *empty_env[] = {NULL};
    execve(program[0], program, empty_env);
    perror("launcher: exec");
    _exit(4);
  }
  int status = 0;
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) {
      perror("launcher: wait");
      return 4;
    }
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 4;
}
