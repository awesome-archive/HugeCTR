/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cub/cub/cub.cuh>
#include <diagnose.hpp>
#include <metrics.hpp>
#include <utils.cuh>

namespace HugeCTR {

namespace metrics {

namespace {

const float eps = 1e-32;

__global__ void unique_flag_kernel(const float* data, char* flag, int num_elems) {
  int gid_base = blockIdx.x * blockDim.x + threadIdx.x;
  for (int gid = gid_base; gid < num_elems - 1; gid += blockDim.x * gridDim.x) {
    float lhs = data[gid];
    float rhs = data[gid + 1];
    // assume the elements are in descending order
    flag[gid] = ((lhs - rhs) > eps) ? 1 : 0;
  }
  if (gid_base == 0) {
    flag[num_elems - 1] = 1;
  }
}

__global__ void unique_index_kernel(const char* flag, const int* flag_inc_sum, int* unique_index,
                                    int num_elems) {
  int gid_base = blockIdx.x * blockDim.x + threadIdx.x;
  for (int gid = gid_base; gid < num_elems; gid += blockDim.x * gridDim.x) {
    if (flag[gid] == 1) {
      int id = flag_inc_sum[gid] - 1;
      unique_index[id] = gid;
    }
  }
}

__global__ void create_fpr_kernel(float* tpr, const int* unique_index, float* fpr, int num_selected,
                                  int num_total) {
  float pos_cnt = tpr[num_selected - 1];
  float neg_cnt = num_total - pos_cnt;
  int gid_base = blockIdx.x * blockDim.x + threadIdx.x;
  for (int gid = gid_base; gid < num_selected; gid += blockDim.x * gridDim.x) {
    float tp = tpr[gid];
    fpr[gid] = (1.0f + unique_index[gid] - tp) / neg_cnt;
    tpr[gid] = tp / pos_cnt;
  }
}

__global__ void trapz_kernel(float* y, float* x, float* auc, int num_selected) {
  __shared__ float s_auc;
  s_auc = 0.0f;
  __syncthreads();
  int gid_base = blockIdx.x * blockDim.x + threadIdx.x;
  for (int gid = gid_base; gid < num_selected - 1; gid += blockDim.x * gridDim.x) {
    float a = x[gid];
    float b = x[gid + 1];
    float fa = y[gid];
    float fb = y[gid + 1];
    float area = (b - a) * (fa + fb) / 2.0f;
    if (gid == 0) {
      area += (a * fa / 2.0f);
    }
    atomicAdd(&s_auc, area);
  }
  __syncthreads();
  if (threadIdx.x == 0) {
    atomicAdd(auc, s_auc);
  }
}

/* __global__ void half2float_kernel(float* y, const __half* x, int num_elems) {
  int gid_base = blockIdx.x * blockDim.x + threadIdx.x;
  for (int gid = gid_base; gid < num_elems; gid += blockDim.x * gridDim.x) {
    y[gid] = __half2float(x[gid]);
  }
} */

__global__ void copy_all_kernel(float* y_pred, float* y_label, const __half* x_pred,
                                const float* x_label, int num_elems) {
  int gid_base = blockIdx.x * blockDim.x + threadIdx.x;
  for (int gid = gid_base; gid < num_elems; gid += blockDim.x * gridDim.x) {
    float pred_val = __half2float(x_pred[gid]);
    float label_val = x_label[gid];
    y_pred[gid] = pred_val;
    y_label[gid] = label_val;
  }
}

template <typename SrcType>
void copy_pred(float* y, SrcType* x, int num_elems, int num_sms, cudaStream_t stream);

template <>
void copy_pred<float>(float* y, float* x, int num_elems, int num_sms, cudaStream_t stream) {
  CK_CUDA_THROW_(
      cudaMemcpyAsync(y, x, num_elems * sizeof(float), cudaMemcpyDeviceToDevice, stream));
}

/* template <>
void copy_pred<__half>(float* y, __half* x, int num_elems, int num_sms, cudaStream_t stream) {
  dim3 grid(num_sms * 2, 1, 1);
  dim3 block(1024, 1, 1);
  half2float_kernel<<<grid, block, 0, stream>>>(y, x, num_elems);
} */

template <typename PredType>
void copy_all(float* y_pred, float* y_label, PredType* x_pred, float* x_label, int num_elems,
              int num_sms, cudaStream_t stream);

template <>
void copy_all<float>(float* y_pred, float* y_label, float* x_pred, float* x_label, int num_elems,
                     int num_sms, cudaStream_t stream) {
  copy_pred<float>(y_pred, x_pred, num_elems, num_sms, stream);
  CK_CUDA_THROW_(cudaMemcpyAsync(y_label, x_label, num_elems * sizeof(float),
                                 cudaMemcpyDeviceToDevice, stream));
}

template <>
void copy_all<__half>(float* y_pred, float* y_label, __half* x_pred, float* x_label, int num_elems,
                      int num_sms, cudaStream_t stream) {
  dim3 grid(num_sms * 2, 1, 1);
  dim3 block(1024, 1, 1);
  copy_all_kernel<<<grid, block, 0, stream>>>(y_pred, y_label, x_pred, x_label, num_elems);
}

}  // namespace

std::unique_ptr<Metric> Metric::Create(const Type type, bool use_mixed_precision,
                                       int batch_size_eval, int n_batches,
                                       const std::shared_ptr<ResourceManager>& resource_manager) {
  std::unique_ptr<Metric> ret;
  switch (type) {
    case Type::AUC:
      if (use_mixed_precision) {
        ret.reset(new AUC<__half>(batch_size_eval, n_batches, resource_manager));
      } else {
        ret.reset(new AUC<float>(batch_size_eval, n_batches, resource_manager));
      }
      break;
    case Type::AverageLoss:
      ret.reset(new AverageLoss<float>(resource_manager));
      break;
  }
  return ret;
}

Metric::Metric() : num_procs_(1), pid_(0), current_batch_size_(0) {
#ifdef ENABLE_MPI
  CK_MPI_THROW_(MPI_Comm_rank(MPI_COMM_WORLD, &pid_));
  CK_MPI_THROW_(MPI_Comm_size(MPI_COMM_WORLD, &num_procs_));
#endif
}
Metric::~Metric() {}

template <typename T>
AverageLoss<T>::AverageLoss(const std::shared_ptr<ResourceManager>& resource_manager)
    : Metric(),
      resource_manager_(resource_manager),
      loss_local_(std::vector<float>(resource_manager->get_local_gpu_count(), 0.0f)),
      loss_global_(0.0f),
      n_batches_(0) {}

template <typename T>
AverageLoss<T>::~AverageLoss() {}

template <typename T>
void AverageLoss<T>::local_reduce(int local_gpu_id, RawMetricMap raw_metrics) {
  float loss_host = 0.0f;
  Tensor2<T> loss_tensor = Tensor2<T>::stretch_from(raw_metrics[RawType::Loss]);
  CudaDeviceContext context(resource_manager_->get_local_gpu(local_gpu_id)->get_device_id());
  CK_CUDA_THROW_(
      cudaMemcpy(&loss_host, loss_tensor.get_ptr(), sizeof(float), cudaMemcpyDeviceToHost));
  loss_local_[local_gpu_id] = loss_host;
}

template <typename T>
void AverageLoss<T>::global_reduce(int n_nets) {
  float loss_inter = 0.0f;
  for (auto& loss_local : loss_local_) {
    loss_inter += loss_local;
  }

#ifdef ENABLE_MPI
  if (num_procs_ > 1) {
    float loss_reduced = 0.0f;
    CK_MPI_THROW_(MPI_Reduce(&loss_inter, &loss_reduced, 1, MPI_FLOAT, MPI_SUM, 0, MPI_COMM_WORLD));
    loss_inter = loss_reduced;
  }
#endif
  loss_global_ += loss_inter / n_nets / num_procs_;
  n_batches_++;
}

template <typename T>
float AverageLoss<T>::finalize_metric() {
  float ret = 0.0f;
  if (pid_ == 0) {
    if (n_batches_) {
      ret = loss_global_ / n_batches_;
    }
  }
#ifdef ENABLE_MPI
  CK_MPI_THROW_(MPI_Barrier(MPI_COMM_WORLD));
  CK_MPI_THROW_(MPI_Bcast(&ret, 1, MPI_FLOAT, 0, MPI_COMM_WORLD));
#endif

  loss_global_ = 0.0f;
  for (auto& loss_local : loss_local_) {
    loss_local = 0.0f;
  }
  n_batches_ = 0;
  return ret;
}

template <typename T>
AUC<T>::AUC(int batch_size_per_gpu, int n_batches,
            const std::shared_ptr<ResourceManager>& resource_manager)
    : Metric(),
      resource_manager_(resource_manager),
      batch_size_per_gpu_(batch_size_per_gpu),
      n_batches_(n_batches),
      root_device_id_(resource_manager->get_local_gpu(0)->get_device_id()),
      num_gpus_(resource_manager->get_local_gpu_count()),
      offset_(0),
      temp0_(nullptr),
      temp1_(nullptr),
      temp2_(nullptr),
      temp3_(nullptr),
      workspace_(nullptr),
      temp_storage_bytes_(0) {
  int num_elems = batch_size_per_gpu_ * n_batches_ * num_gpus_;
#ifdef ENABLE_MPI
  if (num_procs_ > 1 && pid_ == 0) {
    num_elems *= num_procs_;
  }
#endif
  size_t buffer_size = num_elems * sizeof(float);

  CudaDeviceContext context(root_device_id_);
  CK_CUDA_THROW_(cudaMallocManaged(&temp0_, buffer_size));
  CK_CUDA_THROW_(cudaMallocManaged(&temp1_, buffer_size));
  CK_CUDA_THROW_(cudaMallocManaged(&temp2_, buffer_size));
  CK_CUDA_THROW_(cudaMallocManaged(&temp3_, buffer_size));

  size_t new_temp_storage_bytes = 0;

  CK_CUDA_THROW_(cub::DeviceRadixSort::SortPairsDescending(nullptr, new_temp_storage_bytes,
                                                           d_pred(), d_pred_sort(), d_label(),
                                                           d_label_sort(), num_elems, 0));
  set_max_temp_storage_bytes(new_temp_storage_bytes);

  CK_CUDA_THROW_(cub::DeviceScan::InclusiveSum(nullptr, new_temp_storage_bytes, d_label_sort(),
                                               d_label(), num_elems));
  set_max_temp_storage_bytes(new_temp_storage_bytes);

  char* dummy_d_flags = nullptr;
  int* dummy_d_num_selected_out = nullptr;
  CK_CUDA_THROW_(cub::DeviceSelect::Flagged(nullptr, new_temp_storage_bytes, d_label(),
                                            dummy_d_flags, d_label_sort(), dummy_d_num_selected_out,
                                            num_elems));
  set_max_temp_storage_bytes(new_temp_storage_bytes);

  set_max_temp_storage_bytes(buffer_size);

  size_t flag_size = num_elems * sizeof(char);
  size_t num_size = sizeof(int);
  CK_CUDA_THROW_(cudaMallocManaged(&workspace_, temp_storage_bytes_ + num_size + flag_size));

  for (int b = 0; b < n_batches_; b++) {
    for (int g = 0; g < num_gpus_; g++) {
      int offset = (g + b * num_gpus_) * batch_size_per_gpu_;
      size_t size = batch_size_per_gpu_ * sizeof(float);
      cudaMemAdvise(d_pred() + offset, size, cudaMemAdviseSetPreferredLocation, cudaCpuDeviceId);
      cudaMemAdvise(d_label() + offset, size, cudaMemAdviseSetAccessedBy, g);
    }
  }
}

template <typename T>
AUC<T>::~AUC() {
  cudaFree(temp0_);
  cudaFree(temp1_);
  cudaFree(temp2_);
  cudaFree(temp3_);
  cudaFree(workspace_);
}

template <typename T>
void AUC<T>::local_reduce(int local_gpu_id, RawMetricMap raw_metrics) {
  Tensor2<PredType> pred_tensor = Tensor2<PredType>::stretch_from(raw_metrics[RawType::Pred]);
  Tensor2<LabelType> label_tensor = Tensor2<LabelType>::stretch_from(raw_metrics[RawType::Label]);

  int device_id = resource_manager_->get_local_gpu(local_gpu_id)->get_device_id();
  CudaDeviceContext context(device_id);
  int num_active_gpu = 0;
  int r = 0;
  num_active_gpu_and_r(num_active_gpu, r);
  if (r) {
    num_active_gpu += 1;
  }

  if (device_id < num_active_gpu) {
    int num_elems = (r && device_id == num_active_gpu - 1) ? r : batch_size_per_gpu_;

    size_t offset = offset_ + batch_size_per_gpu_ * device_id;

    // TBD get_local_gpu
    copy_all<T>(d_pred() + offset, d_label() + offset, pred_tensor.get_ptr(),
                label_tensor.get_ptr(), num_elems,
                resource_manager_->get_local_gpu(local_gpu_id)->get_sm_count(),
                resource_manager_->get_local_gpu(local_gpu_id)->get_stream());
  }
}

template <typename T>
void AUC<T>::global_reduce(int n_nets) {
  int num_active_gpu = 0;
  int r = 0;
  num_active_gpu_and_r(num_active_gpu, r);
  offset_ += (batch_size_per_gpu_ * num_active_gpu + r);

#ifdef ENABLE_MPI
  if (num_procs_ > 1) {
    int cnt = offset_;
    CK_MPI_THROW_(MPI_Gather((pid_ == 0) ? MPI_IN_PLACE : d_pred(), cnt, MPI_FLOAT, d_pred(), cnt,
                             MPI_FLOAT, 0, MPI_COMM_WORLD));
    CK_MPI_THROW_(MPI_Gather((pid_ == 0) ? MPI_IN_PLACE : d_label(), cnt, MPI_FLOAT, d_label(), cnt,
                             MPI_FLOAT, 0, MPI_COMM_WORLD));
  }
#endif
}

template <typename T>
float AUC<T>::finalize_metric() {
  CudaDeviceContext context(root_device_id_);

  if (pid_ == 0) {
    for (int i = 0; i < num_gpus_; i++) {
      CudaDeviceContext context(resource_manager_->get_local_gpu(i)->get_device_id());
      CK_CUDA_THROW_(cudaDeviceSynchronize());
    }

    int num_elems = offset_ * num_procs_;
    CK_CUDA_THROW_(cub::DeviceRadixSort::SortPairsDescending(workspace_, temp_storage_bytes_,
                                                             d_pred(), d_pred_sort(), d_label(),
                                                             d_label_sort(), num_elems, 0));
    int* d_num_selected_out = ((int*)workspace_) + temp_storage_bytes_ / sizeof(int);
    char* d_flag = ((char*)workspace_) + temp_storage_bytes_ + sizeof(int);

    dim3 grid(160, 1, 1);
    dim3 block(1024, 1, 1);
    unique_flag_kernel<<<grid, block>>>(d_pred_sort(), d_flag, num_elems);

    CK_CUDA_THROW_(cub::DeviceScan::InclusiveSum(workspace_, temp_storage_bytes_, d_label_sort(),
                                                 d_inc_sum(), num_elems));

    CK_CUDA_THROW_(cub::DeviceSelect::Flagged(workspace_, temp_storage_bytes_, d_inc_sum(), d_flag,
                                              tpr(), d_num_selected_out, num_elems));

    int num_selected = 0;
    CK_CUDA_THROW_(
        cudaMemcpy(&num_selected, d_num_selected_out, sizeof(int), cudaMemcpyDeviceToHost));

    CK_CUDA_THROW_(cub::DeviceScan::InclusiveSum(workspace_, temp_storage_bytes_, d_flag,
                                                 d_flag_inc_sum(), num_elems));

    unique_index_kernel<<<grid, block>>>(d_flag, d_flag_inc_sum(), d_unique_index(), num_elems);

    create_fpr_kernel<<<grid, block>>>(tpr(), d_unique_index(), fpr(), num_selected, num_elems);

    initialize_array<<<grid, block>>>(d_auc(), 1, 0.0f);

    trapz_kernel<<<grid, block>>>(tpr(), fpr(), d_auc(), num_selected);

    CK_CUDA_THROW_(cudaDeviceSynchronize());
  }
  offset_ = 0;

#ifdef ENABLE_MPI
  CK_MPI_THROW_(MPI_Barrier(MPI_COMM_WORLD));
  CK_MPI_THROW_(MPI_Bcast(d_auc(), 1, MPI_FLOAT, 0, MPI_COMM_WORLD));
#endif

  return *d_auc();
}

template <typename T>
void AUC<T>::set_max_temp_storage_bytes(size_t& new_val) {
  temp_storage_bytes_ = (new_val > temp_storage_bytes_) ? new_val : temp_storage_bytes_;
  new_val = 0;
}

template <typename T>
void AUC<T>::num_active_gpu_and_r(int& num_active_gpu, int& r) {
  num_active_gpu = current_batch_size_ / (batch_size_per_gpu_ * num_procs_);
  r = current_batch_size_ % (batch_size_per_gpu_ * num_procs_);
}

template class AverageLoss<float>;
template class AUC<float>;
template class AUC<__half>;

}  // namespace metrics

}  // namespace HugeCTR
