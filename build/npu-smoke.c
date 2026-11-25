/*
 * npu-smoke —— 最小 NPU 推理自测
 *
 * 只依赖 rknn_api.h + librknnrt.so，不依赖 OpenCV（SDK 的 rknn_benchmark 要 OpenCV，
 * 本镜像没装）。用固定填充的输入跑 N 次 rknn_run，给出平均耗时，用来证明
 * "NPU 真的能算"，而不只是"驱动 probe 成功"。
 *
 * 编译（板端，无需 cmake）：
 *   gcc -O2 -I include npu-smoke.c -o npu-smoke -L/usr/lib64 -lrknnrt -lpthread -ldl -lm
 * 用法：
 *   ./npu-smoke model/resnet18_for_rk3576.rknn [loop=100]
 * 退出码：0 成功；1 失败
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "rknn_api.h"

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static unsigned char *read_file(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    long n;
    unsigned char *buf;

    if (!f)
        return NULL;

    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return NULL;
    }
    n = ftell(f);
    if (n <= 0) {
        fclose(f);
        return NULL;
    }
    rewind(f);

    buf = (unsigned char *)malloc((size_t)n);
    if (buf && fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        buf = NULL;
    }
    fclose(f);
    *len = (size_t)n;
    return buf;
}

int main(int argc, char **argv)
{
    const char *model_path;
    int loop, i, run_fail = 0;
    size_t model_len = 0;
    unsigned char *model, *inbuf;
    rknn_context ctx = 0;
    rknn_sdk_version ver;
    rknn_input_output_num io;
    rknn_tensor_attr in;
    rknn_input inputs[1];
    rknn_output outs[1];
    size_t elems = 1, in_size;
    uint32_t k;
    double t0, t1;

    if (argc < 2) {
        fprintf(stderr, "usage: %s <model.rknn> [loop]\n", argv[0]);
        return 1;
    }
    model_path = argv[1];
    loop = (argc > 2) ? atoi(argv[2]) : 100;
    if (loop <= 0)
        loop = 100;

    model = read_file(model_path, &model_len);
    if (!model) {
        printf("FAIL: 读不到模型 %s\n", model_path);
        return 1;
    }
    printf("model   : %s (%zu bytes)\n", model_path, model_len);

    if (rknn_init(&ctx, model, (uint32_t)model_len, 0, NULL) != 0) {
        printf("FAIL: rknn_init 失败（模型与 SoC 不匹配？）\n");
        free(model);
        return 1;
    }

    memset(&ver, 0, sizeof(ver));
    if (rknn_query(ctx, RKNN_QUERY_SDK_VERSION, &ver, sizeof(ver)) == 0)
        printf("sdk     : api=%s driver=%s\n", ver.api_version, ver.drv_version);
    else
        printf("sdk     : (query 失败)\n");

    memset(&io, 0, sizeof(io));
    if (rknn_query(ctx, RKNN_QUERY_IN_OUT_NUM, &io, sizeof(io)) != 0) {
        printf("FAIL: RKNN_QUERY_IN_OUT_NUM 失败\n");
        rknn_destroy(ctx);
        free(model);
        return 1;
    }
    printf("io      : n_input=%u n_output=%u\n", io.n_input, io.n_output);

    memset(&in, 0, sizeof(in));
    in.index = 0;
    if (rknn_query(ctx, RKNN_QUERY_INPUT_ATTR, &in, sizeof(in)) != 0) {
        printf("FAIL: RKNN_QUERY_INPUT_ATTR 失败\n");
        rknn_destroy(ctx);
        free(model);
        return 1;
    }
    printf("input   : n_dims=%u dims=[", in.n_dims);
    for (k = 0; k < in.n_dims; k++) {
        printf("%u%s", in.dims[k], (k + 1 < in.n_dims) ? "," : "");
        elems *= in.dims[k];
    }
    printf("] n_elems=%u fmt=%d type=%d\n", in.n_elems, (int)in.fmt, (int)in.type);
    if (elems == 0)
        elems = in.n_elems;
    if (elems == 0) {
        printf("FAIL: 输入尺寸为 0\n");
        rknn_destroy(ctx);
        free(model);
        return 1;
    }

    in_size = elems; /* UINT8：1 字节/元素 */
    inbuf = (unsigned char *)malloc(in_size);
    if (!inbuf) {
        printf("FAIL: malloc %zu 字节失败\n", in_size);
        rknn_destroy(ctx);
        free(model);
        return 1;
    }
    memset(inbuf, 0x40, in_size);

    memset(inputs, 0, sizeof(inputs));
    inputs[0].index = 0;
    inputs[0].buf = inbuf;
    inputs[0].size = (uint32_t)in_size;
    inputs[0].pass_through = 0;
    inputs[0].type = RKNN_TENSOR_UINT8;
    inputs[0].fmt = RKNN_TENSOR_NHWC;
    if (rknn_inputs_set(ctx, 1, inputs) != 0) {
        printf("FAIL: rknn_inputs_set 失败\n");
        free(inbuf);
        rknn_destroy(ctx);
        free(model);
        return 1;
    }

    for (i = 0; i < 5; i++) /* warmup：让频率与缓存稳定 */
        (void)rknn_run(ctx, NULL);

    t0 = now_ms();
    for (i = 0; i < loop; i++) {
        if (rknn_run(ctx, NULL) != 0)
            run_fail++;
    }
    t1 = now_ms();

    memset(outs, 0, sizeof(outs));
    outs[0].index = 0;
    outs[0].want_float = 1;
    outs[0].is_prealloc = 0;
    if (rknn_outputs_get(ctx, 1, outs, NULL) == 0 && outs[0].buf) {
        float *p = (float *)outs[0].buf;
        uint32_t n = outs[0].size / (uint32_t)sizeof(float), j;
        double sum = 0.0;
        for (j = 0; j < n; j++)
            sum += p[j];
        printf("output  : n_float=%u sum=%.4f\n", n, sum);
        rknn_outputs_release(ctx, 1, outs);
    } else {
        printf("output  : (get 失败)\n");
    }

    printf("run     : loop=%d fail=%d avg=%.3f ms  %.1f fps\n",
           loop, run_fail, (t1 - t0) / loop, loop * 1000.0 / (t1 - t0));

    free(inbuf);
    rknn_destroy(ctx);
    free(model);

    if (run_fail) {
        printf("FAIL: %d/%d 次 rknn_run 失败\n", run_fail, loop);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
