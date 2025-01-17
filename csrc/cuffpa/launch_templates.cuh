#include "ffpa_attn_templates_L1.cuh"
using namespace ffpa;                                            


template<
  const int kHeadDim,              // Headdim, 32~1024   
  const int kMmaAccFloat32QK,      // 0/1, Q@K^T, 0 MMA Acc with fp16, 1 MMA Acc with fp32.
  const int kMmaAccFloat32PV,      // 0/1, P@V, 0 MMA Acc with fp16, 1 MMA Acc with fp32.
  const int kStage
>
void launch_ffpa_mma_L1_template(torch::Tensor Q, 
                                 torch::Tensor K, 
                                 torch::Tensor V, 
                                 torch::Tensor O) {
  // Q,K,V,O with [B, H, N, D] layout, B=batch, H=head, N=seqlen, D=dim
  // TODO: support BNHD layout, Q,K,V,O with [B, N, H, D] layout.
  // Now: fixed tile BrxBc=128x128 for d>= 128, 64x64 for d<128.
  constexpr int kMmaAtomM = 16;
  constexpr int kMmaAtomN = 8;
  constexpr int kMmaAtomK = 16;
  constexpr int kMmaTileSeqLenQ  = (kHeadDim < 128) ? 4 : 8;
  constexpr int kMmaTileSeqLenK  = 1;
  constexpr int kMmaTileSeqLenP  = (kHeadDim < 128) ? 4 : 8;
  constexpr int kMmaTileHeadDimV = 1;
  constexpr int kWarpTileSeqLenQ = 1;
  constexpr int kWarpTileSeqLenK = (kHeadDim < 128) ? 8 : 16;
  constexpr int kWarpTileSeqLenP = 1;
  constexpr int kWarpTileHeadDimV = (kHeadDim / (kMmaAtomN * kMmaTileHeadDimV));
  constexpr int Br = kMmaAtomM * kMmaTileSeqLenQ * kWarpTileSeqLenQ;
  constexpr int Bc = kMmaAtomN * kMmaTileSeqLenK * kWarpTileSeqLenK;
  constexpr int kNumThreads = WARP_SIZE * kMmaTileSeqLenQ * kMmaTileSeqLenK;
  // Apply different multi stages policy for QK and V.
  constexpr int kStageQK = kStage; // <= 4
  constexpr int kStagePV = kStage; // <= 4
  // 0/1, The precision of the O storage buffer can differ from 
  // that of the MMA, supporting either FP32 or Half precision.
  // FP16 can provide precision to approximately 3-4 decimal places.
  // Thus, if the error does not exceed 1e-3, using FP16 storage is 
  // sufficient for most applications.
  constexpr int kOStorageAccFloat32 = (kHeadDim < 256) ? 1 : 0;
  // Persist load Q s2r for headdim < 512, more registers, 
  // but still keep O(1) SRAM.
#ifdef ENABLE_FFPA_PERSIST_Q_S2R
  const int kPersistQs2r = 1;
#else
  const int kPersistQs2r = 0;
#endif
  // Persist load Q g2s for headdim < 512, more SRAM, but still
  // keep register usage.
#ifdef ENABLE_FFPA_PERSIST_Q_G2S
  const int kPersistQg2s = (kHeadDim < 256) ? 1 : (
    (kHeadDim <= 320) ? ((kStageQK < 3) ? 1 : 0) : 0 
  );
#else
  const int kPersistQg2s = 0;
#endif
  // Prefetch QKV at the appropriate time point. 
#ifdef ENABLE_FFPA_PREFETCH_QKV
  constexpr int kPrefetchQK = (kStageQK > 1) ? 1 : 0; 
  constexpr int kPrefetchPV = (kStagePV > 1) ? 1 : 0; 
#else 
  constexpr int kPrefetchQK = 0;
  constexpr int kPrefetchPV = 0;
#endif
  // QKV smem swizzle, 0 for smem swizzle, !0 for smem padding.
#ifdef ENABLE_FFPA_SMEM_SWIZZLE_Q
  constexpr int kPadQ = 0;
#else 
  constexpr int kPadQ = 8;
#endif
#ifdef ENABLE_FFPA_SMEM_SWIZZLE_K
  constexpr int kPadK = 0; 
#else
  constexpr int kPadK = 8;
#endif
#ifdef ENABLE_FFPA_SMEM_SWIZZLE_V
  constexpr int kPadV = 0; 
#else 
  constexpr int kPadV = 8;
#endif

  // Calculate SRAM size needed per block, Q,K,V smem size, V shared the QK smem.
  constexpr int QK_smem_size = (
    (kPersistQg2s ? (kHeadDim / kMmaAtomK) : kStageQK) * // Q
    (Br * (kMmaAtomK + kPadQ)) + 
    (kStageQK) * (Bc * (kMmaAtomK + kPadK))  // K
  );
  // R_D registers, s=2, d=64, 16 regs; d=128, 32 regs; 
  // d=256, 64 regs; d=512, 128 regs; d=1024, 256 regs;
  constexpr int PV_smem_size = (kStagePV * (Bc * (kMmaAtomN * 2 + kPadV))); 
#ifdef ENABLE_FFPA_QKV_SMEM_SHARE
  constexpr int kShareSmemQKV = 1;
  // try to let V reuse all Q+K smem after Q@K^T, reduce smem usage.
  constexpr int kQKVSmemMaxSize = (QK_smem_size > PV_smem_size ? 
                                   QK_smem_size * 2 : 
                                   PV_smem_size * 2);
#else
  constexpr int kShareSmemQKV = 0;
  constexpr int kQKVSmemMaxSize = (QK_smem_size + PV_smem_size) * 2;
#endif 

  const int QKV_batch  = Q.size(0); 
  const int QKV_head   = Q.size(1);
  const int QKV_seqlen = Q.size(2); // QKV_seqlen
  assert(QKV_seqlen % max(Br, Bc) == 0); // multiple of max(Br, Bc)
  
  dim3 block(kNumThreads); // 4/8 warps per block
  // Tr(=N/Br), batch_size x num_heads
  // try grid(N/Br, B * H) or grid(N/Br, H, B)
#ifdef ENBALE_FFPA_LAUNCH_GRID_DNHB
  dim3 grid(utils::div_ceil(QKV_seqlen, Br), QKV_head, QKV_batch); 
#else
  dim3 grid(utils::div_ceil(QKV_seqlen, Br), QKV_batch * QKV_head); 
#endif

  auto ffpa_mma_L1_kernel_func = (
    ffpa_mma_stages_split_q_L1_template<
      kHeadDim, 
      kMmaAtomM, 
      kMmaAtomN, 
      kMmaAtomK, 
      kMmaTileSeqLenQ,  
      kMmaTileSeqLenK,
      kMmaTileSeqLenP, 
      kMmaTileHeadDimV, 
      kWarpTileSeqLenQ, 
      kWarpTileSeqLenK, 
      kWarpTileSeqLenP, 
      kWarpTileHeadDimV, 
      kMmaAccFloat32QK,
      kMmaAccFloat32PV,
      kOStorageAccFloat32,
      kPrefetchQK,
      kPrefetchPV,
      kShareSmemQKV,
      kPersistQs2r,
      kPersistQg2s,
      kStageQK, 
      kStagePV,
      kPadQ,
      kPadK,
      kPadV
    >
  );

  cudaFuncSetAttribute(
    ffpa_mma_L1_kernel_func,
    cudaFuncAttributeMaxDynamicSharedMemorySize,
    kQKVSmemMaxSize
  );

  ffpa_mma_L1_kernel_func<<<grid, block, kQKVSmemMaxSize>>>(
    reinterpret_cast<half*>(Q.data_ptr()),
    reinterpret_cast<half*>(K.data_ptr()),
    reinterpret_cast<half*>(V.data_ptr()),
    reinterpret_cast<half*>(O.data_ptr()),
    QKV_seqlen,
    QKV_head
  );
}

// dispatch headdim
#define LAUNCHER_L1(D, S)        \
  case D:                        \
    launch_ffpa_mma_L1_template< \
      (D),                       \
      kMmaAccFloat32QK,          \
      kMmaAccFloat32PV,          \
      (S)                        \
    >(Q, K, V, O);               \
    break;

#ifdef ENABLE_FFPA_DEBUG
  // minimal kernels for debug mode
#define DISPATCH_HEADDIM(LAUNCHER, S) \
  {                                   \
    switch (d)                        \
    {                                 \
      LAUNCHER(32,   (S));            \
      LAUNCHER(64,   (S));            \
      LAUNCHER(128,  (S));            \
      LAUNCHER(256,  (S));            \
      LAUNCHER(320,  (S));            \
      LAUNCHER(512,  (S));            \
      LAUNCHER(1024, (S));            \
    default:                          \
      throw std::runtime_error(       \
        "headdim not support!");      \
      break;                          \
    }                                 \
  }

#else
#ifdef ENABLE_FFPA_ALL_HEADDIM
  // multiple of 32
#define DISPATCH_HEADDIM(LAUNCHER, S) \
  {                                   \
    switch (d)                        \
    {                                 \
      LAUNCHER(32,   (S));            \
      LAUNCHER(64,   (S));            \
      LAUNCHER(96,   (S));            \
      LAUNCHER(128,  (S));            \
      LAUNCHER(160,  (S));            \
      LAUNCHER(192,  (S));            \
      LAUNCHER(224,  (S));            \
      LAUNCHER(256,  (S));            \
      LAUNCHER(288,  (S));            \
      LAUNCHER(320,  (S));            \
      LAUNCHER(352,  (S));            \
      LAUNCHER(384,  (S));            \
      LAUNCHER(416,  (S));            \
      LAUNCHER(448,  (S));            \
      LAUNCHER(480,  (S));            \
      LAUNCHER(512,  (S));            \
      LAUNCHER(544,  (S));            \
      LAUNCHER(576,  (S));            \
      LAUNCHER(608,  (S));            \
      LAUNCHER(640,  (S));            \
      LAUNCHER(672,  (S));            \
      LAUNCHER(704,  (S));            \
      LAUNCHER(736,  (S));            \
      LAUNCHER(768,  (S));            \
      LAUNCHER(800,  (S));            \
      LAUNCHER(832,  (S));            \
      LAUNCHER(864,  (S));            \
      LAUNCHER(896,  (S));            \
      LAUNCHER(928,  (S));            \
      LAUNCHER(960,  (S));            \
      LAUNCHER(992,  (S));            \
      LAUNCHER(1024, (S));            \
    default:                          \
      throw std::runtime_error(       \
        "headdim not support!");      \
      break;                          \
    }                                 \
  }
#else
  // multiple of 64
#define DISPATCH_HEADDIM(LAUNCHER, S) \
  {                                   \
    switch (d)                        \
    {                                 \
      LAUNCHER(256,  (S));            \
      LAUNCHER(320,  (S));            \
      LAUNCHER(384,  (S));            \
      LAUNCHER(448,  (S));            \
      LAUNCHER(512,  (S));            \
      LAUNCHER(576,  (S));            \
      LAUNCHER(640,  (S));            \
      LAUNCHER(704,  (S));            \
      LAUNCHER(768,  (S));            \
      LAUNCHER(832,  (S));            \
      LAUNCHER(896,  (S));            \
      LAUNCHER(960,  (S));            \
      LAUNCHER(1024, (S));            \
    default:                          \
      throw std::runtime_error(       \
        "headdim not support!");      \
      break;                          \
    }                                 \
  }
#endif

#endif
