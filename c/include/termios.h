/* Minimal <termios.h>: a WASI sandbox has no terminal to configure. */
#ifndef KETTLECORN_TERMIOS_H
#define KETTLECORN_TERMIOS_H
typedef unsigned int tcflag_t;
typedef unsigned char cc_t;
typedef unsigned int speed_t;
#define NCCS 32
struct termios {
    tcflag_t c_iflag, c_oflag, c_cflag, c_lflag;
    cc_t c_line;
    cc_t c_cc[NCCS];
};
#define TCSANOW 0
#define TCSADRAIN 1
#define TCSAFLUSH 2
#define ICANON 0000002
#define ECHO 0000010
#define ISIG 0000001
#define VMIN 6
#define VTIME 5
#define VINTR 0
#define VQUIT 1
#define VERASE 2
#define VKILL 3
#define VEOF 4
int tcgetattr(int, struct termios *);
int tcsetattr(int, int, const struct termios *);
#endif
