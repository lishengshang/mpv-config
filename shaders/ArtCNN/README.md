# ArtCNN 实时 GPU 超分

两个 `.glsl` 逐字节取自 [Artoriuz/ArtCNN](https://github.com/Artoriuz/ArtCNN/tree/8789539dfae120f2877a89bb6218026d56809612/GLSL)，保留内嵌 MIT 许可，未修改模型权重或算法。

- 上游提交：`8789539dfae120f2877a89bb6218026d56809612`。
- 获取日期：2026-10-14。
- C4F16 SHA256：`03D0B3D31CB82C898A94A46663021A3E8F02C5A21D69C5CFDF0208DE4BFD453E`。
- C4F32 SHA256：`F773BCE6CF5FE7E5E5D599A695EDD40DF5CD7A20C3D08C4D164D07591D5BEAD3`。

`CTRL+ALT+1` 轻量、`CTRL+ALT+2` 均衡；按键替换 shader 列表，`CTRL+0` 清空。目标宽高都大于源的 1.3 倍时触发；使用 `gpu-next`。不需 VS 与外部模型。

上游 C 系列面向实时动漫超分；本机检查只证明能初始化并渲染，不保证任意分辨率实时或所有片源画质改善。部署、取舍与 A/B 使用见 [GPU 指南](../../docs/gpu-setup.md)。
