/* uinput injector for the move/resize demo: create a virtual pointer with both
   buttons, then drag with the LEFT button (interactive move) and drag with the
   RIGHT button (interactive resize).  libinput in the compositor picks this up
   like a real mouse.  Run as root (needs /dev/uinput).  cc -o inject-drag inject-drag.c */
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

static int make_pointer(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) return -1;
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_KEYBIT, BTN_LEFT);
    ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT);
    ioctl(fd, UI_SET_EVBIT, EV_REL);
    ioctl(fd, UI_SET_RELBIT, REL_X);
    ioctl(fd, UI_SET_RELBIT, REL_Y);
    struct uinput_setup us; memset(&us, 0, sizeof us);
    us.id.bustype = BUS_USB; us.id.vendor = 0x1234; us.id.product = 3;
    strncpy(us.name, "lispwc-drag-pointer", sizeof us.name - 1);
    ioctl(fd, UI_DEV_SETUP, &us);
    ioctl(fd, UI_DEV_CREATE);
    return fd;
}

static void drag(int fd, int btn, int dx, int dy) {
    emit(fd, EV_KEY, btn, 1); syn(fd); usleep(80000);   /* press   */
    for (int i = 0; i < 8; i++) {                        /* drag    */
        emit(fd, EV_REL, REL_X, dx); emit(fd, EV_REL, REL_Y, dy); syn(fd);
        usleep(90000);
    }
    emit(fd, EV_KEY, btn, 0); syn(fd); usleep(150000);   /* release */
}

int main(void) {
    int p = make_pointer();
    if (p < 0) return 1;
    sleep(2);                          /* let libinput hotplug-detect it      */
    drag(p, BTN_LEFT, 12, 8);          /* interactive MOVE                    */
    usleep(200000);
    drag(p, BTN_RIGHT, 10, 6);         /* interactive RESIZE (bottom-right)   */
    usleep(200000);
    ioctl(p, UI_DEV_DESTROY);
    close(p);
    return 0;
}
