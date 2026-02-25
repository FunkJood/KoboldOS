#include "pty_bridge.h"
#include <util.h>      // forkpty() on macOS
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <errno.h>
#include <pthread.h>

// Mutex für Thread-Sicherheit
static pthread_mutex_t pty_mutex = PTHREAD_MUTEX_INITIALIZER;

int kobold_forkpty(pid_t *child_pid, const char *shell_path, int rows, int cols) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;

    // Mutex lock für Thread-Sicherheit
    pthread_mutex_lock(&pty_mutex);

    int master_fd = -1;
    pid_t pid = forkpty(&master_fd, NULL, NULL, &ws);

    if (pid < 0) {
        // fork failed
        pthread_mutex_unlock(&pty_mutex);
        return -1;
    }

    if (pid == 0) {
        // Child process — exec the shell as login shell
        // Unlock mutex bevor wir exec aufrufen (kein return mehr möglich)
        pthread_mutex_unlock(&pty_mutex);

        setenv("TERM", "xterm-256color", 1);
        setenv("LANG", "de_DE.UTF-8", 1);
        setenv("COLORTERM", "truecolor", 1);

        // Terminal-Groesse als Environment-Variablen (fuer CLIs die ENV statt TIOCGWINSZ lesen)
        char cols_str[32], rows_str[32];
        snprintf(cols_str, sizeof(cols_str), "%d", cols);
        snprintf(rows_str, sizeof(rows_str), "%d", rows);
        setenv("COLUMNS", cols_str, 1);
        setenv("LINES", rows_str, 1);

        // Build login-shell argument (-zsh or -bash)
        const char *shell_name = strrchr(shell_path, '/');
        if (shell_name) {
            shell_name++; // skip '/'
        } else {
            shell_name = shell_path;
        }

        // Create "-shellname" for login shell behavior
        char login_arg[256];
        snprintf(login_arg, sizeof(login_arg), "-%s", shell_name);

        // Umfassendes Signalhandling mit sigaction
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = SIG_DFL;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0;

        sigaction(SIGINT, &sa, NULL);
        sigaction(SIGQUIT, &sa, NULL);
        sigaction(SIGTSTP, &sa, NULL);
        sigaction(SIGPIPE, &sa, NULL);
        sigaction(SIGCHLD, &sa, NULL);
        sigaction(SIGHUP, &sa, NULL);
        sigaction(SIGTERM, &sa, NULL);

        execl(shell_path, login_arg, (char *)NULL);
        // If execl fails
        _exit(127);
    }

    // Parent process
    *child_pid = pid;
    pthread_mutex_unlock(&pty_mutex);
    return master_fd;
}

// Signalhandler für ordnungsgemäßes Beenden von Kindprozessen
static void sigchld_handler(int sig) {
    // Verarbeite alle beendeten Kindprozesse
    while (waitpid(-1, NULL, WNOHANG) > 0);
}

int kobold_pty_resize(int master_fd, int rows, int cols) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;

    // Mutex lock für Thread-Sicherheit
    pthread_mutex_lock(&pty_mutex);

    if (ioctl(master_fd, TIOCSWINSZ, &ws) < 0) {
        pthread_mutex_unlock(&pty_mutex);
        return -1;
    }

    pthread_mutex_unlock(&pty_mutex);
    return 0;
}

// Funktion zum Initialisieren des Signalhandlings
void kobold_init_signal_handlers() {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigchld_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;

    sigaction(SIGCHLD, &sa, NULL);
}
