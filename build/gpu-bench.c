/* GPU 真实渲染基准：GBM 显示 + EGL pbuffer（失败回退 gbm-window），GLES2 clear + glFinish */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <stdint.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#ifndef EGL_PLATFORM_GBM_KHR
#define EGL_PLATFORM_GBM_KHR 0x31D7
#endif
#define GBM_FORMAT_XRGB8888 0x34325258u
#define GBM_BO_USE_SCANOUT  (1u << 0)
#define GBM_BO_USE_RENDERING (1u << 2)

struct gbm_device;
struct gbm_surface;
extern struct gbm_device *gbm_create_device(int fd);
extern struct gbm_surface *gbm_surface_create(struct gbm_device *g, uint32_t w, uint32_t h,
                                              uint32_t format, uint32_t flags);
extern void gbm_surface_destroy(struct gbm_surface *s);
extern void gbm_device_destroy(struct gbm_device *g);

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
    const char *node = argc > 1 ? argv[1] : "/dev/dri/renderD128";
    int frames = argc > 2 ? atoi(argv[2]) : 300;
    int W = 1920, H = 1080;

    int fd = open(node, O_RDWR);
    if (fd < 0) { printf("FAIL open %s: %s\n", node, strerror(errno)); return 2; }
    struct gbm_device *gbm = gbm_create_device(fd);
    if (!gbm) { printf("FAIL gbm_create_device: %s\n", strerror(errno)); return 2; }

    PFNEGLGETPLATFORMDISPLAYEXTPROC getPD =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLDisplay dpy = getPD(EGL_PLATFORM_GBM_KHR, gbm, NULL);
    EGLint maj, min;
    if (!eglInitialize(dpy, &maj, &min)) { printf("FAIL eglInitialize 0x%x\n", eglGetError()); return 2; }
    printf("EGL %d.%d  vendor=%s\n", maj, min, eglQueryString(dpy, EGL_VENDOR));
    printf("EGL_VERSION=%s\n", eglQueryString(dpy, EGL_VERSION));
    eglBindAPI(EGL_OPENGL_ES_API);

    EGLSurface surf = EGL_NO_SURFACE;
    EGLConfig cfg = NULL;
    EGLint n = 0;
    const char *surfkind = "none";
    struct gbm_surface *gs = NULL;

    /* 先试 pbuffer（离屏，最稳） */
    EGLint pbufAttr[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                          EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                          EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
                          EGL_NONE };
    if (eglChooseConfig(dpy, pbufAttr, &cfg, 1, &n) && n > 0) {
        EGLint sa[] = { EGL_WIDTH, W, EGL_HEIGHT, H, EGL_NONE };
        surf = eglCreatePbufferSurface(dpy, cfg, sa);
        if (surf != EGL_NO_SURFACE) surfkind = "pbuffer";
    }
    if (surf == EGL_NO_SURFACE) {
        EGLint winAttr[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                             EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                             EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
                             EGL_NONE };
        if (eglChooseConfig(dpy, winAttr, &cfg, 1, &n) && n > 0) {
            gs = gbm_surface_create(gbm, W, H, GBM_FORMAT_XRGB8888,
                                    GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
            if (gs) {
                surf = eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)(uintptr_t)gs, NULL);
                if (surf != EGL_NO_SURFACE) surfkind = "gbm-window";
            }
        }
    }
    if (surf == EGL_NO_SURFACE) {
        printf("FAIL 无可用的 EGLSurface（pbuffer 与 gbm-window 都失败, err=0x%x）\n", eglGetError());
        return 2;
    }
    printf("SURFACE_TYPE=%s\n", surfkind);

    EGLint ctxattr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxattr);
    if (ctx == EGL_NO_CONTEXT) { printf("FAIL eglCreateContext 0x%x\n", eglGetError()); return 2; }
    if (!eglMakeCurrent(dpy, surf, surf, ctx)) { printf("FAIL eglMakeCurrent 0x%x\n", eglGetError()); return 2; }

    printf("GL_VENDOR   = %s\n", glGetString(GL_VENDOR));
    printf("GL_RENDERER = %s\n", glGetString(GL_RENDERER));
    printf("GL_VERSION  = %s\n", glGetString(GL_VERSION));

    glViewport(0, 0, W, H);
    glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish();
    unsigned char px[4] = {0, 0, 0, 0};
    glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    printf("READPIXEL   = %u,%u,%u,%u (期望 255,0,0,255)\n", px[0], px[1], px[2], px[3]);
    if (!(px[0] > 240 && px[1] < 15 && px[2] < 15)) { printf("FAIL 像素回读不符\n"); return 3; }

    double t0 = now_ms();
    for (int i = 0; i < frames; i++) {
        glClearColor((float)(i & 0xff) / 255.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glFinish();
    }
    double dt = now_ms() - t0;
    printf("FRAMES=%d  TOTAL=%.1f ms  PER_FRAME=%.3f ms  FPS=%.1f  PIXELFILL=%.1f Gpix/s\n",
           frames, dt, dt / frames, frames * 1000.0 / dt,
           (double)frames * W * H / (dt / 1000.0) / 1e9);

    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(dpy, surf);
    eglDestroyContext(dpy, ctx);
    eglTerminate(dpy);
    if (gs) gbm_surface_destroy(gs);
    gbm_device_destroy(gbm);
    close(fd);
    printf("RESULT=PASS\n");
    return 0;
}
