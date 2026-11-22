# https://github.com/hooke007/mpv_PlayKit/wiki/3_K7sfunc#dftt_nv
# CUDA/NVRTC frequency-domain denoise; no ONNX or TRT engine required.
import k7sfunc as k7f
from vapoursynth import core

core.num_threads = k7f.vs_t_dft
Gpu = 0
Gpu_T = 2
# Luma only, mild starting point, three-frame temporal window.
Nr_Lv = 4.0
clip = k7f.DFTT_NV(video_in, plane=[0], nr_lv=Nr_Lv,
                  size_sb=16, size_so=12, size_tb=3, gpu=Gpu, gpu_t=Gpu_T)
clip.set_output()
