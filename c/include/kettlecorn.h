/* Kettlecorn: the frames of the host <-> VM stdio protocol (PROTOCOL.md). */
#ifndef KETTLECORN_H
#define KETTLECORN_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/* Each frame: length:u32 (big-endian, type + payload size), type:u8, payload. */

/* VM -> host frame types */
#define KETTLECORN_FRAME_STDOUT  1  /* raw bytes written to fd 1 */
#define KETTLECORN_FRAME_STDERR  2  /* raw bytes written to fd 2 */
#define KETTLECORN_FRAME_MESSAGE 3  /* ETF term sent with :wasm.send/1 */
#define KETTLECORN_FRAME_FATAL   4  /* UTF-8 text, the VM is about to exit */
/* id:u32 status:u8 (enum kettlecorn_send_status), the outcome of a SEND */
#define KETTLECORN_FRAME_SEND_RESULT 5

/* A SEND_RESULT's status, as in PROTOCOL.md and Kettlecorn.Protocol's
 * send_status/1. */
enum kettlecorn_send_status {
  KETTLECORN_SEND_DELIVERED = 0,
  KETTLECORN_SEND_NO_PROCESS = 1,
  KETTLECORN_SEND_BAD_TERM = 2,
  KETTLECORN_SEND_BAD_TARGET = 3,
  KETTLECORN_SEND_MALFORMED = 4
};

enum kettlecorn_target_kind {
  KETTLECORN_TARGET_NAME = 0,
  KETTLECORN_TARGET_PID = 1,
  KETTLECORN_TARGET_PROXY = 2
};

/* host -> VM frame types */
#define KETTLECORN_FRAME_SEND    16 /* id:u32 kind:u8 name_len:u32 name ETF payload */
#define KETTLECORN_FRAME_STDIN   17 /* raw bytes for standard input */
#define KETTLECORN_FRAME_STDIN_EOF 19 /* no payload: end of standard input */

/* Max frame length accepted from the host. */
#define KETTLECORN_MAX_IN_FRAME (64 * 1024 * 1024)

/* Whether stdio is framed (KETTLECORN_FRAMED=1 in the environment). */
int kettlecorn_framed(void);
uint32_t kettlecorn_read_u32(const unsigned char *data);
/* Drops frames in raw mode. 0 or -1 with errno. */
int kettlecorn_frame_write(int type, const void *data, size_t size);

/* 1: a complete body owned by the caller; 0: clean EOF; -1: *error explains
 * the failure. The length is checked before allocating the body. */
int kettlecorn_frame_read(int fd, unsigned char **body, size_t *size, const char **error);
_Noreturn void kettlecorn_fatal(const char *reason);

#endif
