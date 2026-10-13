### https://github.com/Artoriuz/ArtCNN
### ArtCNN 亮度放大 + 神经网络色度重建，N卡专用
### 上游 README 对 Chroma 模型的约定:用于 4:2:0 BT.709 YCbCr 内容,且色度必须先经 bilinear 放大
### 绕开 k7sfunc.ARTCNN_NV(其 model 仅允许 6/7/8,见 mod_scale.py:98),直接调用 vsmlrt.ArtCNN;
### 与 k7sfunc 原实现的唯一区别是把 mod_scale.py:136 的 bilinear 色度放大换成了 Chroma 模型

import vapoursynth as vs
from vapoursynth import core
import k7sfunc as k7f
from k7sfunc._external import vsmlrt

core.num_threads = k7f.vs_t_dft
clip = video_in

############
# 用户选项 #
############

H_Pre = 720
Lt_Hd = True
Luma_Model = 7
Chroma_Model = 9
Gpu = 0
Gpu_T = 2
St_Eng = False
Ws_Size = 0
H_Max = 1440
Lk_Fmt = False
## 整数，预降低处理源高度
## <True|False> 是否对超过HD分辨率（720P）的源进行处理
## <6|7|8> 亮度模型：6=ArtCNN_R16F96，7=ArtCNN_R8F64，8=ArtCNN_R8F64_DS
## <9|17> 色度模型：9=ArtCNN_R8F64_Chroma，17=ArtCNN_R8F64_Chroma_DN（含色度降噪，适合噪点多的源）
## 使用的显卡序号，0为排序一号
## <1|2|3> 使用的显卡线程数
## <True|False> 是否使用静态引擎（需要对不同分辨率的源各进行预处理）；动态引擎自适应不同分辨率（64²→DCI2K）
## <0~1024> 约束显存（MiB），静态引擎的最小值为128（动态引擎自动双倍），设为低于此数的值即为不限制
## 整数，输出高度限制（填你的显示器高度）
## <True|False> 是否锁定像素格式为yuv420p8

def trt_backend() :
    return vsmlrt.BackendV2.TRT(
        num_streams=Gpu_T, force_fp16=True, output_format=1,
        workspace=None if Ws_Size < 128 else (Ws_Size if St_Eng else Ws_Size * 2),
        use_cuda_graph=True, use_cublas=False, use_cudnn=False,
        static_shape=St_Eng, min_shapes=[0, 0] if St_Eng else [384, 384],
        opt_shapes=None if St_Eng else ([1920, 1080] if Lt_Hd else [1280, 720]),
        max_shapes=None if St_Eng else ([2048, 1080] if Lt_Hd else [1280, 720]),
        device_id=Gpu, short_path=True)

ret = k7f.FMT_CTRL(clip, h_max=1200, h_ret=True)
clip = k7f.FMT_CTRL(clip, h_max=H_Pre, fmt_pix=1 if Lk_Fmt else 0)

fmt_in = clip.format.id
cut0 = core.resize.Bilinear(clip=clip, format=vs.YUV444PH)
cut0_y = core.std.ShufflePlanes(clips=cut0, planes=0, colorfamily=vs.GRAY)
cut1_y = vsmlrt.ArtCNN(clip=cut0_y, model=Luma_Model, backend=trt_backend())
cut1_uv = vsmlrt.ArtCNN(clip=cut0, model=Chroma_Model, backend=trt_backend())
cut2 = core.std.ShufflePlanes(clips=[cut1_y, cut1_uv], planes=[0, 1, 2], colorfamily=vs.YUV)
clip = core.resize.Bilinear(clip=cut2, format=fmt_in)

clip = k7f.FMT_CTRL(clip, h_max=H_Max, fmt_pix=1 if Lk_Fmt else 0)

clip.set_output()
