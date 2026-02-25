#ifndef PTY_BRIDGE_H
#define PTY_BRIDGE_H

#include <sys/types.h>

/// Fork a new process with a pseudo-terminal.
/// Returns the master fd on success, -1 on failure.
/// child_pid is set to the child's PID (0 in child process).
int kobold_forkpty(pid_t *child_pid, const char *shell_path, int rows, int cols);

/// Resize the terminal window of a pseudo-terminal.
/// Returns 0 on success, -1 on failure.
int kobold_pty_resize(int master_fd, int rows, int cols);

/// Initialize signal handlers for proper child process cleanup
void kobold_init_signal_handlers();

#endif /* PTY_BRIDGE_H */
