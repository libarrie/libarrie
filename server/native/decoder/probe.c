/* Test-only misbehaving "decoder" used to prove the sandbox contains it.
 * Each mode uses only syscalls the seccomp policy allows, except those
 * meant to be blocked (socket, fork). */
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
#ifdef FORCE_MODE
  /* Built as a stand-in "decoder" that always misbehaves this way. */
  const char *mode = FORCE_MODE;
#else
  const char *mode = argc > 1 ? argv[1] : "";
#endif
  if (strcmp(mode, "segv") == 0) { volatile int *p = (int *)0; return *p; }
  if (strcmp(mode, "spin") == 0) { volatile unsigned long n = 0; for (;;) n++; }
  if (strcmp(mode, "block") == 0) { char c; return (int)read(0, &c, 1); }
  if (strcmp(mode, "socket") == 0) return socket(AF_INET, SOCK_STREAM, 0) >= 0 ? 0 : 7;
  if (strcmp(mode, "fork") == 0) return fork() >= 0 ? 0 : 7;
  if (strcmp(mode, "write-bin") == 0) return fopen("/bin/evil", "w") ? 0 : 7;
  if (strcmp(mode, "write-work") == 0) return fopen("/work/ok", "w") ? 0 : 7;
  if (argc > 2 && strcmp(mode, "read") == 0) return fopen(argv[2], "r") ? 0 : 7;
  if (argc > 2 && strcmp(mode, "write") == 0) return fopen(argv[2], "w") ? 0 : 7;
  return 9;
}
