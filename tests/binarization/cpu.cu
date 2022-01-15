#include <iostream>
#include <opencv2/opencv.hpp>

using namespace std;
using namespace cv;

#define NAIVE

#define H 360
#define W 620

int main(int argc, char const *argv[]) {

    // VideoCapture cap(video_file);
    VideoCapture cap(0, CAP_V4L2);

    if (!cap.isOpened())
        cerr << "Error opening video stream\n";

    auto codec = cv::VideoWriter::fourcc('M', 'J', 'P', 'G');
    cap.set(cv::CAP_PROP_FOURCC, codec);
    cap.set(3, W);
    cap.set(4, H);

    Mat frame, bw, binarize;
    frame.create(H, W, CV_8UC3);
    bw.create(H, W, CV_8UC1);
    binarize.create(H, W, CV_8UC1);
    int sum = 0;
    while (1) {
        cap >> frame;
        if (frame.empty())
            return 0;

        imshow("input", frame);

        if (waitKey(10) == 27) {
            break; // stop capturing by pressing ESC
        }

        // generate black & white image

        for (int row = 0; row < H; row++) {
            for (int col = 0; col < W; col++) {
                bw.at<uchar>(row, col) = 0.114 * frame.at<Vec3b>(row, col)[0] + 0.587 * frame.at<Vec3b>(row, col)[1] + 0.299 * frame.at<Vec3b>(row, col)[2];
            }
        }

        imshow("bw", bw);
        // waitKey(0);
        if (waitKey(10) == 27) {
            break; // stop capturing by pressing ESC
        }

        // find the histogram of the occurency of the values from 0 to 255
        // Naive implementation is a for loop from 0 to 255 and then a loop inside on the matrix
        int histogram[256] = {0};
#ifdef NAIVE
        auto start = std::chrono::high_resolution_clock::now();
        for (int row = 0; row < H; row++) {
            for (int col = 0; col < W; col++) {
                int index = bw.at<uchar>(row, col);
                histogram[index]++;
            }
        }

        for (int i = 0; i < 256; i++) {
            printf("%d \n", histogram[i]);
        }
        int trash;
        // scanf("%d", &trash);
        int max = -1, sec_max = -1;
        int index_max = -1, index_sec_max = -1;
        for (int i = 0; i < 256; i++) {
            if (histogram[i] >= max) {
                index_sec_max = index_max;
                index_max = i;
                max = histogram[i];
                sec_max = max;
            } else if (histogram[i] > sec_max && histogram[i] < max) {
                sec_max = histogram[i];
                index_sec_max = i;
            }
        }
        int threshold = (index_max + index_sec_max) / 2;
        if(threshold < 20)
            threshold = 20;
        printf("%d %d", index_max, index_sec_max);
        // scanf("%d", &trash);

        for (int row = 0; row < H; row++) {
            for (int col = 0; col < W; col++) {
                if (bw.at<uchar>(row, col) > threshold) {
                    binarize.at<uchar>(row, col) = 255;
                } else {
                    binarize.at<uchar>(row, col) = 0;
                }
            }
        }

        imshow("binarize", binarize);


        auto end = std::chrono::high_resolution_clock::now();
        auto elaps = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start);
        printf("\rHeatmap time generation: %.3f ms", (float)elaps.count() * 1e-6);
        fflush(stdout);
#endif
        // Optimized implementation is a for loop inside on the matrix, and then value of the pixel is used to insert the value in the histogram
    }

    cap.release();
    return 0;
}