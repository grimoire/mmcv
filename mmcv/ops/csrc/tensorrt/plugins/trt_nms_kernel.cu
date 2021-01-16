#include <stdio.h>
#include <thrust/execution_policy.h>
#include <thrust/gather.h>
#include <thrust/sort.h>
#include <thrust/transform.h>

#include <chrono>
#include <thread>
#include <vector>

#include "common_cuda_helper.hpp"
#include "nms_cuda_kernel.cuh"
#include "trt_cuda_helper.cuh"
struct NMSBox {
  float box[4];
};

struct nms_centerwh2xyxy {
  __host__ __device__ NMSBox operator()(const NMSBox box) {
    NMSBox out;
    out.box[0] = box.box[0] - box.box[2] / 2.0f;
    out.box[1] = box.box[1] - box.box[3] / 2.0f;
    out.box[2] = box.box[0] + box.box[2] / 2.0f;
    out.box[3] = box.box[1] + box.box[3] / 2.0f;
    return out;
  }
};

struct nms_sbox_idle {
  const float* idle_box_;
  __host__ __device__ nms_sbox_idle(const float* idle_box) {
    idle_box_ = idle_box;
  }

  __host__ __device__ NMSBox operator()(const NMSBox box) {
    return {idle_box_[0], idle_box_[1], idle_box_[2], idle_box_[3]};
  }
};

struct nms_score_threshold {
  float score_threshold_;
  __host__ __device__ nms_score_threshold(const float score_threshold) {
    score_threshold_ = score_threshold;
  }

  __host__ __device__ bool operator()(const float score) {
    return score < score_threshold_;
  }
};

__global__ void nms_reindex_kernel(int n, int* output, int* index_cache) {
  CUDA_1D_KERNEL_LOOP(index, n) {
    const int old_index = output[index * 3 + 2];
    output[index * 3 + 2] = index_cache[old_index];
  }
}

__global__ void mask_to_output_kernel(const unsigned long long* dev_mask,
                                      const int* index, int* output,
                                      int* output_count, int batch_id,
                                      int cls_id, int spatial_dimension,
                                      int col_blocks,
                                      int max_output_boxes_per_class) {
  extern __shared__ unsigned long long remv[];

  // fill remv with 0
  CUDA_1D_KERNEL_LOOP(i, col_blocks) { remv[i] = 0; }
  __syncthreads();

  int start = *output_count;
  int out_per_class_count = 0;
  for (int i = 0; i < spatial_dimension; i++) {
    const int nblock = i / threadsPerBlock;
    const int inblock = i % threadsPerBlock;
    if (!(remv[nblock] & (1ULL << inblock))) {
      if (threadIdx.x == 0) {
        output[start * 3 + 0] = batch_id;
        output[start * 3 + 1] = cls_id;
        output[start * 3 + 2] = index[i];
        start += 1;
      }
      out_per_class_count += 1;
      if (out_per_class_count >= max_output_boxes_per_class) {
        break;
      }
      __syncthreads();
      // set every overlap box with bit 1 in remv
      const unsigned long long* p = dev_mask + i * col_blocks;
      CUDA_1D_KERNEL_LOOP(j, col_blocks) {
        if (j >= nblock) {
          remv[j] |= p[j];
        }
      }  // j
      __syncthreads();
    }
  }  // i
  if (threadIdx.x == 0) {
    *output_count = start;
  }
}

size_t get_onnxnms_workspace_size(size_t num_batches, size_t spatial_dimension,
                                  size_t num_classes, size_t boxes_word_size,
                                  int center_point_box, size_t output_length) {
  size_t boxes_xyxy_workspace = 0;
  if (center_point_box == 1) {
    boxes_xyxy_workspace =
        num_batches * spatial_dimension * 4 * boxes_word_size;
  }
  size_t scores_workspace = spatial_dimension * boxes_word_size;
  size_t boxes_workspace = spatial_dimension * 4 * boxes_word_size;
  const int col_blocks = DIVUP(spatial_dimension, threadsPerBlock);
  size_t mask_workspace =
      spatial_dimension * col_blocks * sizeof(unsigned long long);
  size_t index_workspace = spatial_dimension * 2 * sizeof(int);
  size_t count_workspace = sizeof(int);
  return scores_workspace + boxes_xyxy_workspace + boxes_workspace +
         mask_workspace + index_workspace + count_workspace;
}

void TRTONNXNMSCUDAKernelLauncher_float(const float* boxes, const float* scores,
                                        const int max_output_boxes_per_class,
                                        const float iou_threshold,
                                        const float score_threshold,
                                        int* output, int center_point_box,
                                        int num_batches, int spatial_dimension,
                                        int num_classes, size_t output_length,
                                        void* workspace, cudaStream_t stream) {
  /**
   * describe of inputs:
   * bboxes: [num_batch, spatial_dimension, 4], input boxes
   * scores: [num_batch, num_classes, spatial_dimension], input scores
   * max_output_boxes_per_class: [1] or nullptr, max output boxes per class
   * iou_threshold: [1] or nullptr, threshold of iou
   * score_threshold: [1] or nullptr, threshold of scores
   *
   * describe of outputs:
   * output: [output_length, 3], each row
   *         (batch_id, class_id, boxes_id), filling -1 if invalid.
   *
   * shapes of workspace:
   * boxes_sorted: [spatial_dimension, 4], the boxes which will
   *               be sorted by scores.
   * boxes_xyxy: [num_batch, spatial_dimension, 4], will be used if
   *             center_point_box == 1.
   * scores_sorted: [spatial_dimension], the workspace used to sort scores.
   * dev_mask: [spatial_dimension, col_blocks], intersect mask,
   *           where col_block = DIVUP(spatial_dimension, threadsPerBlock)
   * index_template: [spatial_dimension], sequence (0,1,2,3,...), workspace
   *                 for argsort.
   * index_cache: [num_batches, spatial_dimension], argsort of
   *              each classes.
   *
   */

  const int col_blocks = DIVUP(spatial_dimension, threadsPerBlock);
  float* boxes_sorted = (float*)workspace;
  workspace =
      static_cast<char*>(workspace) + spatial_dimension * 4 * sizeof(float);

  float* boxes_xyxy = nullptr;
  if (center_point_box == 1) {
    boxes_xyxy = (float*)workspace;
    workspace = static_cast<char*>(workspace) +
                num_batches * spatial_dimension * 4 * sizeof(float);
    thrust::transform(thrust::cuda::par.on(stream), (NMSBox*)boxes,
                      (NMSBox*)(boxes + num_batches * spatial_dimension * 4),
                      (NMSBox*)boxes_xyxy, nms_centerwh2xyxy());
    cudaCheckError();
  }

  float* scores_sorted = (float*)workspace;
  workspace = static_cast<char*>(workspace) + spatial_dimension * sizeof(float);

  unsigned long long* dev_mask = (unsigned long long*)workspace;
  workspace = static_cast<char*>(workspace) +
              spatial_dimension * col_blocks * sizeof(unsigned long long);

  int* index_cache = (int*)workspace;
  workspace = static_cast<char*>(workspace) + spatial_dimension * sizeof(int);

  // generate sequence [0,1,2,3,4 ....]
  int* index_template = (int*)workspace;
  workspace = static_cast<char*>(workspace) + spatial_dimension * sizeof(int);
  thrust::sequence(thrust::cuda::par.on(stream), index_template,
                   index_template + spatial_dimension, 0);

  int max_output_boxes_per_class_cpu = max_output_boxes_per_class;
  if (max_output_boxes_per_class_cpu <= 0) {
    max_output_boxes_per_class_cpu = spatial_dimension;
  }

  int* output_count = (int*)workspace;
  workspace = static_cast<char*>(workspace) + sizeof(int);
  cudaMemsetAsync(output_count, 0, sizeof(int), stream);

  // fill output with -1
  thrust::fill(thrust::cuda::par.on(stream), output, output + output_length * 3,
               -1);
  cudaCheckError();

  dim3 blocks(col_blocks, col_blocks);
  dim3 threads(threadsPerBlock);
  const int offset = 0;

  for (int batch_id = 0; batch_id < num_batches; ++batch_id) {
    for (int cls_id = 0; cls_id < num_classes; ++cls_id) {
      const int batch_cls_id = batch_id * num_classes + cls_id;

      // sort boxes by score
      cudaMemcpyAsync(scores_sorted, scores + batch_cls_id * spatial_dimension,
                      spatial_dimension * sizeof(float),
                      cudaMemcpyDeviceToDevice, stream);
      cudaCheckError();

      cudaMemcpyAsync(index_cache, index_template,
                      spatial_dimension * sizeof(int), cudaMemcpyDeviceToDevice,
                      stream);
      cudaCheckError();

      thrust::sort_by_key(thrust::cuda::par.on(stream), scores_sorted,
                          scores_sorted + spatial_dimension, index_cache,
                          thrust::greater<float>());

      if (center_point_box == 1) {
        thrust::gather(thrust::cuda::par.on(stream), index_cache,
                       index_cache + spatial_dimension,
                       (NMSBox*)(boxes_xyxy + batch_id * spatial_dimension * 4),
                       (NMSBox*)boxes_sorted);
      } else {
        thrust::gather(thrust::cuda::par.on(stream), index_cache,
                       index_cache + spatial_dimension,
                       (NMSBox*)(boxes + batch_id * spatial_dimension * 4),
                       (NMSBox*)boxes_sorted);
      }

      cudaCheckError();

      if (score_threshold > 0.0f) {
        thrust::transform_if(
            thrust::cuda::par.on(stream), (NMSBox*)boxes_sorted,
            (NMSBox*)(boxes_sorted + spatial_dimension * 4), scores_sorted,
            (NMSBox*)boxes_sorted, nms_sbox_idle(boxes_sorted),
            nms_score_threshold(score_threshold));
      }

      nms_cuda<<<blocks, threads, 0, stream>>>(spatial_dimension, iou_threshold,
                                               offset, boxes_sorted, dev_mask);
      // process cpu
      // will be performed when dev_mask is full.
      mask_to_output_kernel<<<1, threadsPerBlock,
                              col_blocks * sizeof(unsigned long long),
                              stream>>>(
          dev_mask, index_cache, output, output_count, batch_id, cls_id,
          spatial_dimension, col_blocks, max_output_boxes_per_class_cpu);
    }  // cls_id
  }    // batch_id
}
