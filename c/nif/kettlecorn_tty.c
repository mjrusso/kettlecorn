#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>

#include "kettlecorn_nif.h"

static int dimension(const char *name, int fallback) {
  const char *value = getenv(name);
  char *end;
  long size;
  if (value == NULL) return fallback;
  errno = 0;
  size = strtol(value, &end, 10);
  if (errno || end == value || *end != '\0' || size > INT_MAX ||
      (size <= 0 && size != -1)) return fallback;
  return (int)size;
}

ERL_NIF_TERM kettlecorn_tty_window_size(ErlNifEnv *env, int width, int height) {
  width = dimension("COLUMNS", width);
  height = dimension("LINES", height);
  const char *path = getenv("KETTLECORN_TTY_SIZE");
  if (path != NULL) {
    FILE *file = fopen(path, "r");
    int columns, rows;
    if (file != NULL) {
      if (fscanf(file, "%d %d", &columns, &rows) == 2 && columns > 0 && rows > 0) {
        width = columns;
        height = rows;
      }
      fclose(file);
    }
  }
  if (width == -1 && height == -1)
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "enotsup"));
  return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_tuple2(
      env, enif_make_int(env, width), enif_make_int(env, height)));
}
