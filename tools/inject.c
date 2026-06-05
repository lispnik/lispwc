/* Minimal uinput injector: create a virtual pointer + keyboard, emit a few
   events, destroy.  libinput in the compositor picks these up like real
   devices.  Run as root (needs /dev/uinput).  cc -o inject inject.c */
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

static int make_dev(const char *name, int is_pointer) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) return -1;
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    if (is_pointer) {
        ioctl(fd, UI_SET_KEYBIT, BTN_LEFT);
        ioctl(fd, UI_SET_EVBIT, EV_REL);
        ioctl(fd, UI_SET_RELBIT, REL_X);
        ioctl(fd, UI_SET_RELBIT, REL_Y);
    } else {
        ioctl(fd, UI_SET_KEYBIT, KEY_A);
    }
    struct uinput_setup us; memset(&us, 0, sizeof us);
    us.id.bustype = BUS_USB; us.id.vendor = 0x1234; us.id.product = is_pointer ? 1 : 2;
    strncpy(us.name, name, sizeof us.name - 1);
    ioctl(fd, UI_DEV_SETUP, &us);
    ioctl(fd, UI_DEV_CREATE);
    return fd;
}

int main(void) {
    int ptr = make_dev("lispwc-test-pointer", 1);
    int kbd = make_dev("lispwc-test-keyboard", 0);
    if (ptr < 0 || kbd < 0) return 1;
    sleep(2);                       /* let libinput hotplug-detect them */
    for (int i = 0; i < 5; i++) {   /* move the pointer */
        emit(ptr, EV_REL, REL_X, 15); emit(ptr, EV_REL, REL_Y, 10); syn(ptr);
        usleep(120000);
    }
    emit(ptr, EV_KEY, BTN_LEFT, 1); syn(ptr); usleep(60000);  /* click */
    emit(ptr, EV_KEY, BTN_LEFT, 0); syn(ptr); usleep(120000);
    emit(kbd, EV_KEY, KEY_A, 1); syn(kbd); usleep(60000);     /* press A */
    emit(kbd, EV_KEY, KEY_A, 0); syn(kbd); usleep(300000);
    ioctl(ptr, UI_DEV_DESTROY); ioctl(kbd, UI_DEV_DESTROY);
    close(ptr); close(kbd);
    return 0;
}
