#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define DRM_IOCTL_BASE 'd'
#define DRM_IOCTL_WAIT_VBLANK _IOWR(DRM_IOCTL_BASE, 0x3a, drm_wait_vblank)

#define DRM_VBLANK_ABSOLUTE 0x0
#define DRM_VBLANK_RELATIVE 0x1
#define DRM_VBLANK_NEXTONMISS 0x10000000
#define DRM_VBLANK_SECONDARY 0x20000000
#define DRM_VBLANK_SIGNAL 0x40000000
#define DRM_VBLANK_FLIP 0x80000000

typedef struct _drm_wait_vblank_request {
    int type;
    unsigned int sequence;
    unsigned long signal;
} drm_wait_vblank_request;

typedef struct _drm_wait_vblank_reply {
    int type;
    unsigned int sequence;
    unsigned long tval_sec;
    unsigned long tval_usec;
} drm_wait_vblank_reply;

typedef union drm_wait_vblank {
    drm_wait_vblank_request request;
    drm_wait_vblank_reply reply;
} drm_wait_vblank;

/*
 * Probe whether the kernel DRM device serves WAIT_VBLANK.
 * On the Shark 8 stock kernel (mtk_drm, card0) crtc0 replies OK with a real
 * timestamp; the vendor hwcomposer's DrmModeResource::waitNextVsync uses the
 * same ioctl. This tool was used to prove the vblank pump works and the
 * tearing was caused by periodic vblank_off windows, not by a dead vblank.
 *
 * Build (Android NDK):
 *   clang --target=aarch64-linux-android31 -fPIE -pie -O2 -o vblank_probe vblank_probe.c
 * Run:
 *   adb push vblank_probe /data/local/tmp/ && adb shell /data/local/tmp/vblank_probe
 */
static void try_wait(int fd, const char *label, unsigned int type, unsigned int seq) {
    drm_wait_vblank v;
    memset(&v, 0, sizeof(v));
    errno = 0;
    v.request.type = type;
    v.request.sequence = seq;
    int r = ioctl(fd, DRM_IOCTL_WAIT_VBLANK, &v);
    if (r == 0) {
        printf("%s => OK tval=%lu.%06lu seq=%u\n", label,
               v.reply.tval_sec, v.reply.tval_usec, v.reply.sequence);
    } else {
        printf("%s => FAIL r=%d errno=%d (%s)\n", label, r, errno, strerror(errno));
    }
}

int main(void) {
    int fd = open("/dev/dri/card0", O_RDWR);
    if (fd < 0) {
        perror("open /dev/dri/card0");
        return 1;
    }
    printf("opened /dev/dri/card0 fd=%d\n", fd);

    try_wait(fd, "crtc0 REL seq=1", DRM_VBLANK_RELATIVE, 1);
    try_wait(fd, "crtc0 NEXTONMISS REL seq=1",
             DRM_VBLANK_NEXTONMISS | DRM_VBLANK_RELATIVE, 1);
    try_wait(fd, "crtc1 REL seq=1", (1 << 1) | DRM_VBLANK_RELATIVE, 1);
    try_wait(fd, "crtc0 REL seq=10000", DRM_VBLANK_RELATIVE, 10000);

    close(fd);
    return 0;
}