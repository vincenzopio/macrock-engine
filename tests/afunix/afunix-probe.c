/* AF_UNIX probe: can a Windows program talk to a Unix domain socket of the host?
 *
 *   afunix-probe client PATH   connect to PATH, send "ping", expect "pong"
 *   afunix-probe server PATH   bind PATH, listen, accept one connection, expect "ping",
 *                              send "pong", then delete PATH
 *
 * PATH is a Windows path (e.g. Z:\tmp\x.sock) that Wine maps to a host file; this is how
 * xgameruntime reaches the Xodus service socket. Prints "OK <mode>" and exits 0 on success,
 * "FAIL <mode> <step> <WSA error>" and exits 1 otherwise.
 *
 * Build: x86_64-w64-mingw32-clang -O2 -o afunix-probe.exe afunix-probe.c -lws2_32 */
#include <winsock2.h>
#include <afunix.h>
#include <stdio.h>
#include <string.h>

static int fail(const char *mode, const char *step)
{
    printf("FAIL %s %s %d\n", mode, step, WSAGetLastError());
    return 1;
}

static int exchange(SOCKET s, const char *mode, const char *expect, const char *reply, BOOL send_first)
{
    char buffer[4];

    if (send_first && send(s, reply, 4, 0) != 4) return fail(mode, "send");
    if (recv(s, buffer, 4, MSG_WAITALL) != 4 || memcmp(buffer, expect, 4)) return fail(mode, "recv");
    if (!send_first && send(s, reply, 4, 0) != 4) return fail(mode, "send");
    return 0;
}

int main(int argc, char **argv)
{
    SOCKADDR_UN addr = {0};
    WSADATA wsa;
    SOCKET s, client;
    const char *mode;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc != 3 || (strcmp(argv[1], "client") && strcmp(argv[1], "server")))
    {
        printf("usage: afunix-probe client|server PATH\n");
        return 2;
    }
    mode = argv[1];
    if (strlen(argv[2]) >= sizeof(addr.sun_path)) return fail(mode, "path-length");
    if (WSAStartup(MAKEWORD(2, 2), &wsa)) return fail(mode, "startup");
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, argv[2]);
    if ((s = socket(AF_UNIX, SOCK_STREAM, 0)) == INVALID_SOCKET) return fail(mode, "socket");

    if (!strcmp(mode, "client"))
    {
        if (connect(s, (SOCKADDR *)&addr, sizeof(addr))) return fail(mode, "connect");
        if (exchange(s, mode, "pong", "ping", TRUE)) return 1;
        closesocket(s);
    }
    else
    {
        if (bind(s, (SOCKADDR *)&addr, sizeof(addr))) return fail(mode, "bind");
        if (listen(s, 1)) return fail(mode, "listen");
        if ((client = accept(s, NULL, NULL)) == INVALID_SOCKET) return fail(mode, "accept");
        if (exchange(client, mode, "ping", "pong", FALSE)) return 1;
        closesocket(client);
        closesocket(s);
        if (!DeleteFileA(argv[2]))
        {
            printf("FAIL %s delete %lu\n", mode, GetLastError());
            return 1;
        }
    }
    printf("OK %s\n", mode);
    return 0;
}
