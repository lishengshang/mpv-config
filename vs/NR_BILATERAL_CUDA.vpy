# https://github.com/hooke007/mpv_PlayKit/wiki/3_K7sfunc#bila_nv
# CUDA edge-preserving spatial denoise; no ONNX or TRT engine required.
import k7sfunc as k7f
from vapoursynth import core

core.num_threads = k7f.vs_t_dft
Gpu = 0
Gpu_T = 2
# Luma only, mild strength. Leave disabled for clean sources.
Nr_Spat = [2.0, 0.0, 0.0]
Nr_Color = [0.01, 0.0, 0.0]
clip = k7f.BILA_NV(video_in, nr_spat=Nr_Spat, nr_csp=Nr_Color,
                  gpu=Gpu, gpu_t=Gpu_T)
clip.set_output()
