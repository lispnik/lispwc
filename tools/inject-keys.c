/* uinput injector for the keybinding demo: a virtual keyboard that types
   Alt+Tab (cycle focus), Alt+F4 (close the focused window), then Alt+Esc
   (quit).  libinput in the compositor picks it up like a real keyboard.
   Run as root (needs /dev/uinput).  cc -o inject-keys inject-keys.c */
#include <linux/uinput.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <sys/ioctl.h>

static void emit(int fd, int type, int code, int val) {
    struct input_event ie; memset(&ie, 0, sizeof ie);
    ie.type = type; ie.code = code; ie.value = val;
    write(fd, &ie, sizeof ie);
}
static void syn(int fd) { emit(fd, EV_SYN, SYN_REPORT, 0); }

static void tap(int fd, int code) {       /* press + release one key */
    emit(fd, EV_KEY, code, 1); syn(fd); usleep(60000);
    emit(fd, EV_KEY, code, 0); syn(fd); usleep(60000);
}

/* hold Alt, tap KEY, release Alt -- one compositor shortcut */
static void combo(int fd, int key) {
    emit(fd, EV_KEY, KEY_LEFTALT, 1); syn(fd); usleep(80000);
    tap(fd, key);
    emit(fd, EV_KEY, KEY_LEFTALT, 0); syn(fd); usleep(250000);
}

int main(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) return 1;
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_KEYBIT, KEY_LEFTALT);
    ioctl(fd, UI_SET_KEYBIT, KEY_TAB);
    ioctl(fd, UI_SET_KEYBIT, KEY_F4);
    ioctl(fd, UI_SET_KEYBIT, KEY_ESC);
    struct uinput_setup us; memset(&us, 0, sizeof us);
    us.id.bustype = BUS_USB; us.id.vendor = 0x1234; us.id.product = 4;
    strncpy(us.name, "lispwc-key-injector", sizeof us.name - 1);
    ioctl(fd, UI_DEV_SETUP, &us);
    ioctl(fd, UI_DEV_CREATE);

    sleep(2);                /* let libinput detect it + both windows map */
    combo(fd, KEY_TAB);      /* Alt+Tab  -> cycle focus to the other window */
    combo(fd, KEY_F4);       /* Alt+F4   -> close the focused window         */
    combo(fd, KEY_ESC);      /* Alt+Esc  -> quit the compositor              */

    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
    return 0;
}
