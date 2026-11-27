/* TCP IPv4 сокеты поверх fiber event loop. */
#define _WIN32_WINNT 0x0601

#include "cvnrt_net.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
typedef SOCKET cvn_fd_t;
#define CVN_INVALID_FD INVALID_SOCKET
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int cvn_fd_t;
#define CVN_INVALID_FD (-1)
#endif

#define CVN_NET_MAX_READ (16 * 1024 * 1024)
#define CVN_NET_BACKLOG 64

static cvn_error net_err(int32_t code) {
  return cvn_error_make(code);
}

static cvn_result_obj_cvn_socket sock_ok(cvn_socket s) {
  cvn_result_obj_cvn_socket r;
  memset(&r, 0, sizeof r);
  r.tag = 0u;
  r.u.ok = s;
  return r;
}

static cvn_result_obj_cvn_socket sock_err(int32_t code) {
  cvn_result_obj_cvn_socket r;
  memset(&r, 0, sizeof r);
  r.tag = 1u;
  r.u.err = net_err(code);
  return r;
}

static cvn_result_string str_ok(cvn_string s) {
  cvn_result_string r;
  memset(&r, 0, sizeof r);
  r.tag = 0u;
  r.u.ok = s;
  return r;
}

static cvn_result_string str_err(int32_t code) {
  cvn_result_string r;
  memset(&r, 0, sizeof r);
  r.tag = 1u;
  r.u.err = net_err(code);
  return r;
}

static cvn_result_i64 i64_ok(int64_t v) {
  cvn_result_i64 r;
  memset(&r, 0, sizeof r);
  r.tag = 0u;
  r.u.ok = v;
  return r;
}

static cvn_result_i64 i64_err(int32_t code) {
  cvn_result_i64 r;
  memset(&r, 0, sizeof r);
  r.tag = 1u;
  r.u.err = net_err(code);
  return r;
}

static int host_to_addr(cvn_string host, struct sockaddr_in *addr) {
  char buf[256];
  if (host.ptr == NULL || host.len <= 0 || host.len >= (int64_t)sizeof buf)
    return -1;
  memcpy(buf, host.ptr, (size_t)host.len);
  buf[host.len] = '\0';
  memset(addr, 0, sizeof *addr);
  addr->sin_family = AF_INET;
  if (strcmp(buf, "localhost") == 0) {
    if (inet_pton(AF_INET, "127.0.0.1", &addr->sin_addr) != 1)
      return -1;
    return 0;
  }
  if (inet_pton(AF_INET, buf, &addr->sin_addr) != 1)
    return -1;
  return 0;
}

static int set_nonblock(cvn_fd_t fd) {
#ifdef _WIN32
  u_long nb = 1;
  return ioctlsocket(fd, FIONBIO, &nb) == 0 ? 0 : -1;
#else
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0)
    return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 ? 0 : -1;
#endif
}

static void close_fd(cvn_fd_t fd) {
#ifdef _WIN32
  closesocket(fd);
#else
  close(fd);
#endif
}

static int wait_fd_events(cvn_fd_t fd, uint32_t events) {
  return cvn_task_wait_fd((int)fd, events);
}

static void wait_fd(cvn_fd_t fd, uint32_t events) {
  (void)wait_fd_events(fd, events);
}

static bool valid_socket(cvn_socket s, int kind) {
  return s.fd >= 0 && s.kind == kind;
}

cvn_result_obj_cvn_socket cvn_net_listen(cvn_string host, int64_t port) {
  struct sockaddr_in addr;
  cvn_fd_t fd;
  cvn_socket s;
  int opt = 1;
  if (port < 0 || port > 65535)
    return sock_err(CVN_ERR_INVALID);
  if (host_to_addr(host, &addr) != 0)
    return sock_err(CVN_ERR_INVALID);
  addr.sin_port = htons((unsigned short)port);
  fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (fd == CVN_INVALID_FD)
    return sock_err(CVN_ERR_IO);
  (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&opt,
                   (socklen_t)sizeof opt);
  if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 ||
      listen(fd, CVN_NET_BACKLOG) != 0) {
    close_fd(fd);
    return sock_err(CVN_ERR_IO);
  }
  if (set_nonblock(fd) != 0) {
    close_fd(fd);
    return sock_err(CVN_ERR_IO);
  }
  s.fd = (int64_t)fd;
  s.kind = CVN_SOCK_LISTENER;
  s._pad = 0;
  return sock_ok(s);
}

cvn_result_obj_cvn_socket cvn_net_accept(cvn_socket s) {
  if (!valid_socket(s, CVN_SOCK_LISTENER))
    return sock_err(CVN_ERR_INVALID);
  for (;;) {
    cvn_fd_t c = accept((cvn_fd_t)s.fd, NULL, NULL);
    if (c != CVN_INVALID_FD) {
      cvn_socket out;
      if (set_nonblock(c) != 0) {
        close_fd(c);
        return sock_err(CVN_ERR_IO);
      }
      out.fd = (int64_t)c;
      out.kind = CVN_SOCK_CONN;
      out._pad = 0;
      return sock_ok(out);
    }
#ifdef _WIN32
    if (WSAGetLastError() == WSAEWOULDBLOCK) {
#else
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
#endif
      wait_fd((cvn_fd_t)s.fd, CVN_IO_READ);
      continue;
    }
    return sock_err(CVN_ERR_IO);
  }
}

cvn_result_obj_cvn_socket cvn_net_connect(cvn_string host, int64_t port) {
  struct sockaddr_in addr;
  cvn_fd_t fd;
  cvn_socket s;
  int rc;
  if (port < 0 || port > 65535)
    return sock_err(CVN_ERR_INVALID);
  if (host_to_addr(host, &addr) != 0)
    return sock_err(CVN_ERR_INVALID);
  addr.sin_port = htons((unsigned short)port);
  fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (fd == CVN_INVALID_FD)
    return sock_err(CVN_ERR_IO);
  if (set_nonblock(fd) != 0) {
    close_fd(fd);
    return sock_err(CVN_ERR_IO);
  }
  rc = connect(fd, (struct sockaddr *)&addr, sizeof addr);
  if (rc != 0) {
#ifdef _WIN32
    int e = WSAGetLastError();
    if (e != WSAEWOULDBLOCK && e != WSAEINPROGRESS) {
#else
    if (errno != EINPROGRESS && errno != EWOULDBLOCK) {
#endif
      close_fd(fd);
      return sock_err(CVN_ERR_IO);
    }
    {
      for (;;) {
        int r = wait_fd_events(fd, CVN_IO_WRITE);
        int soerr = 0;
        socklen_t slen = (socklen_t)sizeof soerr;
        if (r == 0)
          continue;
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, (char *)&soerr, &slen) != 0 ||
            soerr != 0) {
          close_fd(fd);
          return sock_err(CVN_ERR_IO);
        }
        break;
      }
    }
  }
  s.fd = (int64_t)fd;
  s.kind = CVN_SOCK_CONN;
  s._pad = 0;
  return sock_ok(s);
}

/* Возвращает число прочитанных байт, 0 на EOF, -1 на ошибку. */
static int64_t read_into_raw(cvn_socket s, char *buf, int64_t max_bytes) {
  if (!valid_socket(s, CVN_SOCK_CONN) || buf == NULL || max_bytes <= 0)
    return -1;
  for (;;) {
#ifdef _WIN32
    int n = recv((cvn_fd_t)s.fd, buf, (int)max_bytes, 0);
#else
    ssize_t n = recv((cvn_fd_t)s.fd, buf, (size_t)max_bytes, 0);
#endif
    if (n > 0)
      return (int64_t)n;
    if (n == 0)
      return 0;
#ifdef _WIN32
    if (WSAGetLastError() == WSAEWOULDBLOCK) {
#else
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
#endif
      wait_fd((cvn_fd_t)s.fd, CVN_IO_READ);
      continue;
    }
    return -1;
  }
}

cvn_result_i64 cvn_net_read_into(cvn_socket s, void *buf,
                                 int64_t max_bytes) {
  int64_t n;
  if (max_bytes <= 0)
    return i64_err(CVN_ERR_INVALID);
  n = read_into_raw(s, (char *)buf, max_bytes);
  if (n < 0)
    return i64_err(CVN_ERR_IO);
  if (n == 0)
    return i64_err(CVN_ERR_CLOSED);
  return i64_ok(n);
}

cvn_result_string cvn_net_read(cvn_socket s, cvn_allocator a,
                               int64_t max_bytes) {
  cvn_result_ptr pr;
  char *buf;
  int64_t n;
  cvn_string out;
  if (max_bytes <= 0 || max_bytes > CVN_NET_MAX_READ)
    return str_err(CVN_ERR_INVALID);
  pr = cvn_alloc_aligned(a, max_bytes + 1, 8);
  if (pr.tag != 0u)
    return str_err(pr.u.err.code);
  buf = (char *)pr.u.ok;
  n = read_into_raw(s, buf, max_bytes);
  if (n < 0) {
    cvn_free_bytes(a, buf, max_bytes + 1);
    return str_err(CVN_ERR_IO);
  }
  if (n == 0) {
    cvn_free_bytes(a, buf, max_bytes + 1);
    return str_err(CVN_ERR_CLOSED);
  }
  buf[n] = '\0';
  out.ptr = buf;
  out.len = n;
  out.cap = max_bytes + 1;
  out.alloc = a;
  return str_ok(out);
}

static cvn_error write_bytes_raw(cvn_socket s, const char *buf, int64_t n) {
  int64_t off = 0;
  if (!valid_socket(s, CVN_SOCK_CONN) || buf == NULL || n < 0)
    return net_err(CVN_ERR_INVALID);
  while (off < n) {
#ifdef _WIN32
    int sent = send((cvn_fd_t)s.fd, buf + off, (int)(n - off), 0);
#else
    ssize_t sent = send((cvn_fd_t)s.fd, buf + off, (size_t)(n - off), 0);
#endif
    if (sent > 0) {
      off += (int64_t)sent;
      continue;
    }
    if (sent < 0) {
#ifdef _WIN32
      if (WSAGetLastError() == WSAEWOULDBLOCK) {
#else
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
#endif
        wait_fd((cvn_fd_t)s.fd, CVN_IO_WRITE);
        continue;
      }
      return net_err(CVN_ERR_IO);
    }
  }
  return net_err(CVN_OK);
}

cvn_error cvn_net_write_bytes(cvn_socket s, void *buf, int64_t n) {
  return write_bytes_raw(s, (const char *)buf, n);
}

cvn_error cvn_net_write(cvn_socket s, cvn_string data) {
  return write_bytes_raw(s, data.ptr, data.len);
}

void cvn_net_close(cvn_socket s) {
  if (s.fd >= 0)
    close_fd((cvn_fd_t)s.fd);
}

void cvn_net_shutdown_write(cvn_socket s) {
  if (!valid_socket(s, CVN_SOCK_CONN))
    return;
#ifdef _WIN32
  shutdown((cvn_fd_t)s.fd, SD_SEND);
#else
  shutdown((cvn_fd_t)s.fd, SHUT_WR);
#endif
}

int64_t cvn_net_local_port(cvn_socket s) {
  struct sockaddr_in addr;
  socklen_t len = (socklen_t)sizeof addr;
  if (s.fd < 0)
    return -1;
  memset(&addr, 0, sizeof addr);
  if (getsockname((cvn_fd_t)s.fd, (struct sockaddr *)&addr, &len) != 0)
    return -1;
  return (int64_t)ntohs(addr.sin_port);
}

