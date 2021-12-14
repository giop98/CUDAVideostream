
#include <stdio.h>
#include <fcntl.h>    /* For O_RDWR */
#include <sys/ioctl.h>
#include <unistd.h>   /* For open(), creat() */
#include <netdb.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <time.h>
#include <stdint.h>
#include "opencv2/opencv.hpp"
#include <pthread.h>
#include "v4l.h"

#define NSTREAMS 1
#define GPU

using namespace cv;

struct mat_ready {
    Mat *pframe;
    int *h_xs;
    unsigned int h_pos;
};

struct ctxs {
    VideoCapture *cap;
    int cap_w_fd;
    Mat *sampleMat;
    int show_r_fd;
    int ptr_w_fd;
    int ptr_r_fd;
    int proc_w_fd;
    int proc_w_fd_B;
    // unsigned int **phpos;
    // int **pxs;
};

#ifdef GPU
__global__ void kernel(uint8_t *current, uint8_t *previous, uint8_t *diff, int maxSect, unsigned int *pos, int *xs) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int npos;
    int df;

    int max = x * maxSect + maxSect;
    for (int i = x * maxSect; i < max; i++) {

        df = current[i] - previous[i];
        if (df < -20 || df > 20) {
            npos = atomicInc(pos, 6220801);
            diff[npos] = df;
            xs[npos] = i;
        } else {
            current[i] -= df;
        }

    }
}
#endif

void *th_cap_hdl(void *args) {

    struct mat_ready *pready;
    struct ctxs *pctx = (struct ctxs *)args;

    while(1) {
        read(pctx->ptr_r_fd, &pready, sizeof pready);
        *pctx->cap >> *(pready->pframe);

        write(pctx->cap_w_fd, &pready, sizeof pready);
    }

    return NULL;
}

void *th_show_hdl(void *args) {
    struct epoll_event ev, events[10];
    struct addrinfo *result, *rp;
    int sfd, epollfd, nfds, sfd2;
    struct mat_ready *pready;
    bool skip = true;

    getaddrinfo("127.0.0.1", "2734", NULL, &result);
    for (rp = result; rp != NULL; rp = rp->ai_next) {
        if ((sfd = socket(AF_INET, SOCK_STREAM, 0)) == -1) {
            continue;
        }

        if (bind(sfd, rp->ai_addr, rp->ai_addrlen) != -1) {
            break;
        }

        close(sfd);
        perror("MOH!");
    }

    epollfd = epoll_create1(0);
    ev.events = EPOLLIN;
    ev.data.fd = sfd;
    epoll_ctl(epollfd, 1, sfd, &ev);

    if (listen(sfd, 10) < 0) {
        perror("OH!");
        exit(errno);
    }

    nfds = epoll_wait(epollfd, events, 10, -1);

    for (int i = 0; i < nfds; i++) {
        if (events[i].data.fd == sfd) {
            sfd2 = accept(sfd, NULL, NULL);
            if (sfd2 < 0) perror("ACCEPT");
        }
    }

    struct ctxs *pctx = (struct ctxs *)args;
    int tot = 3 * pctx->sampleMat->cols * pctx->sampleMat->rows;

    // uint8_t *mem = new uint8_t[sizeof **pctx->phpos + tot * sizeof **pctx->phpos + tot];
    write(sfd2, pctx->sampleMat->data, tot);
    // Mat previous = pctx->sampleMat->clone();

    while(1) {
        read(pctx->show_r_fd, &pready, sizeof pready);
        // printf("show on %p\n", pframe);

        if (skip ^= 1) {
            skip = true;
        }

        // memcpy(mem, *pctx->phpos, sizeof **pctx->phpos);
        // memcpy(mem + sizeof **pctx->phpos, pready->h_xs, **pctx->phpos * sizeof *pready->h_xs);
        // memcpy(mem + sizeof **pctx->phpos + **pctx->phpos * sizeof *pready->h_xs, pready->pframe->data, **pctx->phpos);
        // printf("Writing all, xs %ld\n", **pctx->phpos * sizeof **pctx->pxs);
        // for (int i = 0; i < 10; i++) {
        //     printf(" ## xs %i = %d\n", (*(pctx->pxs))[i], pframe->data[i]);
        // }

        // for (int i = 0; i < 10; i++) {
        //     printf(" -- xs %i = %d\n", (mem + sizeof **pctx->phpos)[i], (mem + sizeof **pctx->phpos + **pctx->phpos * sizeof **pctx->pxs)[i]);
        // }

        int ret = write(sfd2, &pready->h_pos, sizeof pready->h_pos);
        if (ret != sizeof pready->h_pos) {
            perror("write1");
        }

        ret = write(sfd2, pready->h_xs, pready->h_pos * sizeof *pready->h_xs);
        if (ret != pready->h_pos * sizeof *pready->h_xs) {
            perror("write2");
        }

        ret = write(sfd2, pready->pframe->data, pready->h_pos);
        if (ret != pready->h_pos) {
            perror("write3");
        }


        write(pctx->ptr_w_fd, &pready, sizeof pready);
    }

    return NULL;
}

int main() {

    VideoCapture cap;
    if (!cap.open(0, CAP_V4L2)) return 1;
    auto codec = cv::VideoWriter::fourcc('M','J','P','G');
    cap.set(cv::CAP_PROP_FOURCC, codec);


    cap.set(3, 1920);
    cap.set(4, 1080);

    Mat base;
    cap >> base;

    int cap_pipe[2];
    int show_pipe[2];
    int ptr_pipe[2];
    int fork_pipe[2];
    int fork_pipe_B[2];
    pipe(cap_pipe);
    pipe(show_pipe);
    pipe(ptr_pipe);
    pipe(fork_pipe);
    pipe(fork_pipe_B);

    pthread_mutex_t fifosize_mtx;
    pthread_mutex_init(&fifosize_mtx, NULL);

    int *h_xs;
    unsigned int *h_pos;
    struct ctxs ctx = { 
        .cap = &cap,
        .cap_w_fd = cap_pipe[1], 
        .sampleMat = &base ,
        .show_r_fd = show_pipe[0],
        .ptr_w_fd = ptr_pipe[1],
        .ptr_r_fd = ptr_pipe[0],
        .proc_w_fd = fork_pipe[1],
        .proc_w_fd_B = fork_pipe_B[1]
    };

    pthread_t th_cap;
    pthread_t th_show;
    pthread_create(&th_cap, NULL, th_cap_hdl, &ctx);
    pthread_create(&th_show, NULL, th_show_hdl, &ctx);

    struct mat_ready *pready;
    for (int i = 0; i < 20; i++) {

        pready = new struct mat_ready;

#ifdef GPU
        uint8_t *h_frame;
        cudaMallocHost((void **)&h_frame, 3 * ctx.sampleMat->rows * ctx.sampleMat->cols * sizeof *h_frame);
        cudaMallocHost((void **)&pready->h_xs, 3 * ctx.sampleMat->rows * ctx.sampleMat->cols * sizeof *pready->h_xs);
        pready->pframe = new Mat(ctx.sampleMat->rows, ctx.sampleMat->cols, ctx.sampleMat->type(), h_frame);
#else
        pready->pframe = new Mat(ctx.sampleMat->rows, ctx.sampleMat->cols, ctx.sampleMat->type());
        pready->h_xs = new int[3 * ctx.sampleMat->rows * ctx.sampleMat->cols];
#endif

        pready->h_pos = 0;
        write(ctx.ptr_w_fd, &pready, sizeof pready);
    }

    int total = 3 * ctx.sampleMat->rows * ctx.sampleMat->cols;

#ifdef CPU
    uint8_t *h_diff = new uint8_t[total];
    h_xs = new int[total];
    h_pos = new unsigned int[1];
#elif defined(GPU)
    struct cudaDeviceProp prop;
    uint8_t *d_current, *d_previous;
    uint8_t *d_diff;
    int *d_xs;
    unsigned int *d_pos;
    cudaStream_t streams[4];

    cudaGetDeviceProperties(&prop, 0);
    cudaStreamCreate(&streams[0]);
    cudaStreamCreate(&streams[1]);
    cudaStreamCreate(&streams[2]);
    cudaStreamCreate(&streams[3]);

    cudaMalloc((void **)&d_diff, total * sizeof *d_diff);
    cudaMalloc((void **)&d_xs, total * sizeof *d_xs);
    cudaMalloc((void **)&d_current, total * sizeof *d_current);
    cudaMalloc((void **)&d_previous, total * sizeof *d_previous);

    cudaMalloc((void **)&d_pos, sizeof *d_pos);
    // cudaMemset((void *)d_pos, 0, sizeof *d_pos);

    uint8_t *h_diff, *h_diff2, *h_current;
    int *h_xs2;
    cudaMallocHost((void **)&h_diff, total * sizeof *h_diff);
    cudaMallocHost((void **)&h_diff2, total * sizeof *h_diff2);
    cudaMallocHost((void **)&h_current, total * sizeof *h_current);
    cudaMallocHost((void **)&h_pos, sizeof *h_pos);
    cudaMallocHost((void **)&h_xs, total * sizeof *h_xs);
    cudaMallocHost((void **)&h_xs2, total * sizeof *h_xs2);

    int maxAtTime = total / prop.maxThreadsPerBlock;
    cudaMemcpy(d_current, ctx.sampleMat->data, total * sizeof *ctx.sampleMat->data, cudaMemcpyHostToDevice);

    int tot4 = total / 1;
    int max4 = maxAtTime / 1;
    uint8_t *dcurr4_0 = d_current;
    uint8_t *dcurr4_1 = d_current + tot4;
    uint8_t *dcurr4_2 = d_current + tot4;
    uint8_t *dcurr4_3 = d_current + 3*tot4;
    uint8_t *dprev4_0 = d_previous;
    uint8_t *dprev4_1 = d_previous + tot4;
    uint8_t *dprev4_2 = d_previous + tot4;
    uint8_t *dprev4_3 = d_previous + 3*tot4;
    uint8_t *ddiff_0 = d_diff;
    uint8_t *ddiff_1 = d_diff + tot4;
    uint8_t *ddiff_2 = d_diff + tot4;
    uint8_t *ddiff_3 = d_diff + 3*tot4;
    // uint8_t *pframe_0 = pframe->data;
    // uint8_t *pframe_1 = pframe->data + total/4;
    // uint8_t *pframe_2 = pframe->data + total/2;
    // uint8_t *pframe_3 = pframe->data + 3*total/4;

#endif

    Mat previous = ctx.sampleMat->clone();

    auto begin0 = std::chrono::high_resolution_clock::now();
    while (1) {
        auto begin = std::chrono::high_resolution_clock::now();

        auto begin2 = std::chrono::high_resolution_clock::now();
        read(cap_pipe[0], &pready, sizeof pready);
        auto end2 = std::chrono::high_resolution_clock::now();

        auto begin3 = std::chrono::high_resolution_clock::now();
#ifdef CPU
        Mat pvs = pready->pframe->clone();

        *h_pos = 0;
        for (int i = total-1; i >= 0; i--) {
            pready->pframe->data[*h_pos] = pready->pframe->data[i] - previous.data[i];
            pready->h_xs[*h_pos] = i;
            (*h_pos)++;
        }

        previous = pvs;

#elif defined(GPU)

        uint8_t *d_prev = dcurr4_0;
        dcurr4_0 = dprev4_0;
        dprev4_0 = d_prev;

        d_prev = dcurr4_1;
        dcurr4_1 = dprev4_1;
        dprev4_1 = d_prev;

        // d_prev = d_current;
        // d_current = d_previous;
        // d_previous = d_prev;

        // d_prev = dcurr4_1;
        // dcurr4_1 = dprev4_1;
        // dprev4_1 = d_prev;

        // d_prev = dcurr4_2;
        // dcurr4_2 = dprev4_2;
        // dprev4_2 = d_prev;

        // d_prev = dcurr4_3;
        // dcurr4_3 = dprev4_3;
        // dprev4_3 = d_prev;

        cudaMemset(d_pos, 0, sizeof *d_pos);

        cudaMemcpyAsync(dcurr4_0, pready->pframe->data, tot4, cudaMemcpyHostToDevice, streams[0]);
        kernel<<<1, prop.maxThreadsPerBlock, 0, streams[0]>>>(dcurr4_0, dprev4_0, ddiff_0, max4, d_pos, d_xs);
        cudaMemcpyAsync(pready->pframe->data, ddiff_0, tot4, cudaMemcpyDeviceToHost, streams[0]);//TODO: *h_pos instead of tot4
        cudaMemcpyAsync(pready->h_xs, d_xs, tot4 * sizeof *d_xs, cudaMemcpyDeviceToHost, streams[0]);

        // cudaMemcpyAsync(dcurr4_1, pready->pframe->data + tot4, tot4, cudaMemcpyHostToDevice, streams[1]);
        // kernel<<<1, prop.maxThreadsPerBlock, 0, streams[1]>>>(dcurr4_1, dprev4_1, ddiff_1, max4, d_pos, d_xs);
        // cudaMemcpyAsync(pready->pframe->data + tot4, ddiff_1, tot4, cudaMemcpyDeviceToHost, streams[1]);//TODO: *h_pos instead of tot4
        // cudaMemcpyAsync(pready->h_xs + tot4, d_xs + tot4, tot4 * sizeof *d_xs, cudaMemcpyDeviceToHost, streams[1]);


        // cudaMemcpyAsync(dcurr4_1, pframe_1, tot4, cudaMemcpyHostToDevice, streams[1]);
        // kernel<<<1, prop.maxThreadsPerBlock, 0, streams[1]>>>(dcurr4_1, dprev4_1, ddiff_1, max4, d_pos);
        // cudaMemcpyAsync(pframe_1, ddiff_1, tot4, cudaMemcpyDeviceToHost, streams[1]);

        // cudaMemcpyAsync(dcurr4_2, pframe_2, tot4, cudaMemcpyHostToDevice, streams[2]);
        // kernel<<<1, prop.maxThreadsPerBlock, 0, streams[2]>>>(dcurr4_2, dprev4_2, ddiff_2, max4, d_pos);
        // cudaMemcpyAsync(pframe_2, ddiff_2, tot4, cudaMemcpyDeviceToHost, streams[2]);

        // cudaMemcpyAsync(dcurr4_3, pframe_3, tot4, cudaMemcpyHostToDevice, streams[3]);
        // kernel<<<1, prop.maxThreadsPerBlock, 0, streams[3]>>>(dcurr4_3, dprev4_3, ddiff_3, max4, d_pos);
        // cudaMemcpyAsync(pframe_3, ddiff_3, tot4, cudaMemcpyDeviceToHost, streams[3]);

        cudaDeviceSynchronize();
        cudaMemcpy(&pready->h_pos, d_pos, sizeof *d_pos, cudaMemcpyDeviceToHost); 

#endif
        auto end3 = std::chrono::high_resolution_clock::now();

        write(show_pipe[1], &pready, sizeof pready);

        auto end = std::chrono::high_resolution_clock::now();

        auto end0 = std::chrono::high_resolution_clock::now();
        if (std::chrono::duration_cast<std::chrono::nanoseconds>(end0 - begin0).count() > 1e9) {
            begin0 = end0;

            auto elaps = std::chrono::duration_cast<std::chrono::nanoseconds>(end - begin);
            auto elaps2 = std::chrono::duration_cast<std::chrono::nanoseconds>(end2 - begin2);
            auto elaps3 = std::chrono::duration_cast<std::chrono::nanoseconds>(end3 - begin3);

            float unit = 1 / ((float)elaps.count() * 1e-9);
            printf("\rFPS: %5.0f\tFOR: %5.2f ms\tREAD: %9.2f\tPOS: %7d\t BW: %5d kbps", unit, (float)elaps3.count() * 1e-6, (float)elaps2.count() * 1e-6, pready->h_pos, (int)((pready->h_pos<<4)*unit*1e-3));
            fflush(stdout);
        }

    }

    return 0;
}