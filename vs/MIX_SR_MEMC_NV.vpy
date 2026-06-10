### 综合滤镜：AI超分 + RIFE补帧，5060友好配置
### 仅对≤720p源进行超分2x，RIFE使用4.25lite轻量模型
### 1080p源只补帧不超分，>1200p源不处理

import vapoursynth as vs
from vapoursynth import core
import k7sfunc as k7f

core.num_threads = k7f.vs_t_dft
clip = video_in

############
# 用户选项 #
############

H_Pre = 720          # SR预降低处理源高度
H_SR_Max = 1200      # SR输出高度限制
H_RIFE_Max = 1200    # RIFE输入高度限制
SR_Model = 7          # ArtCNN模型 (7=R8F64轻量, 8=R8F64_DS更强)
RIFE_Model = 4251     # RIFE模型 (4251=4.25lite轻量, 426=4.26标准)
Fps_Num = 2           # 帧率倍数分子
Fps_Den = 1           # 帧率倍数分母
Gpu = 0               # 显卡序号
Gpu_T = 2             # 显卡线程数
## 整数，预降低处理源高度
## 整数，SR输出高度限制
## 整数，RIFE输入高度限制
## <6|7|8> ArtCNN模型，7为轻量推荐
## <4251|426|4262> RIFE模型，4251为轻量推荐
## 整数，帧率倍数=Fps_Num/Fps_Den
## 整数
## 显卡序号，0为排序一号
## <1|2|3> 显卡线程数

# 超分：仅对720p及以下的源进行2x放大
if clip.height <= 720:
    clip = k7f.FMT_CTRL(clip, h_max=H_Pre, fmt_pix=1)
    clip = k7f.ARTCNN_NV(clip, lt_hd=False, model=SR_Model, gpu=Gpu, gpu_t=Gpu_T, st_eng=False, ws_size=0)
    clip = k7f.FMT_CTRL(clip, h_max=H_SR_Max)

# 补帧：RIFE轻量模型，仅对≤32fps的源补帧
if container_fps <= 32:
    clip = k7f.FMT_CTRL(clip, h_max=H_RIFE_Max, fmt_pix=1)
    clip = k7f.RIFE_NV(clip, model=RIFE_Model, turbo=2, fps_in=container_fps, fps_num=Fps_Num, fps_den=Fps_Den, sc_mode=1, gpu=Gpu, gpu_t=Gpu_T)

# 有处理才输出，否则播放原始源
if clip != video_in:
    clip.set_output()
