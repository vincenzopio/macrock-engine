/* WinHTTP TLS probe: does the runtime's WinHTTP reject bad server certificates?
 *
 * Games' HTTP (libHttpClient) relies on WinHTTP's own certificate validation; the GDK's
 * XNetworkingVerifyServerCertificate only adds pinning. This makes default-flag HTTPS requests
 * to badssl.com: the valid host must succeed, the broken ones (expired, wrong host, self-signed,
 * untrusted root) must fail. Prints one line per host and exits 0 when all behave. Needs the
 * network.
 *
 * Build: x86_64-w64-mingw32-clang -O2 -o winhttp-tls-probe.exe winhttp-tls-probe.c -lwinhttp */
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>

static DWORD request(const WCHAR *host)
{
    HINTERNET session, connection = NULL, req = NULL;
    DWORD error = ERROR_SUCCESS;

    session = WinHttpOpen(L"macrock-tls-probe", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME,
                          WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) return GetLastError();
    WinHttpSetTimeouts(session, 10000, 10000, 10000, 10000);
    if (!(connection = WinHttpConnect(session, host, INTERNET_DEFAULT_HTTPS_PORT, 0)) ||
        !(req = WinHttpOpenRequest(connection, L"GET", L"/", NULL, WINHTTP_NO_REFERER,
                                   WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE)) ||
        !WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(req, NULL))
        error = GetLastError();
    if (req) WinHttpCloseHandle(req);
    if (connection) WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session);
    return error;
}

int main(void)
{
    static const struct { const WCHAR *host; BOOL valid; } hosts[] =
    {
        { L"badssl.com", TRUE },
        { L"expired.badssl.com", FALSE },
        { L"wrong.host.badssl.com", FALSE },
        { L"self-signed.badssl.com", FALSE },
        { L"untrusted-root.badssl.com", FALSE },
    };
    int failures = 0;

    setvbuf(stdout, NULL, _IONBF, 0);
    for (int i = 0; i < (int)(sizeof(hosts) / sizeof(hosts[0])); i++)
    {
        DWORD error = request(hosts[i].host);
        BOOL accepted = error == ERROR_SUCCESS;
        BOOL right = accepted == hosts[i].valid;

        printf("%s %ls: %s (error %lu)\n", right ? "ok  " : "BAD ", hosts[i].host,
               accepted ? "accepted" : "rejected", error);
        if (!right) failures++;
    }
    return failures != 0;
}
