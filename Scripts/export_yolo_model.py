#!/usr/bin/env python3
"""
YOLOv8 → Core ML 模型导出脚本

用法:
    pip install ultralytics coremltools
    python3 scripts/export_yolo_model.py

输出: HOKAuto/yolov8n_ui.mlmodel (约4-6MB)

如需自定义训练:
    1. 准备数据集目录 datasets/hok_ui/
       ├── data.yaml        # 类别定义
       ├── train/images/    # 标注截图
       ├── train/labels/    # YOLO 标注文件
       └── val/images/ + val/labels/
    2. 取消下方 train() 调用注释
    3. 运行脚本

类别 (7类):
    0: button        - 通用可点击按钮
    1: close_button  - 关闭/取消按钮 (X)
    2: popup         - 弹窗/对话框
    3: tab           - 标签页/导航按钮
    4: icon          - 图标 (英雄头像、道具)
    5: badge         - 红点/角标
    6: input         - 输入框
"""

import os
import sys

MODEL_OUTPUT = os.path.join(os.path.dirname(__file__), "..", "HOKAuto", "yolov8n_ui.mlmodel")
DATASET_YAML = os.path.join(os.path.dirname(__file__), "..", "datasets", "hok_ui", "data.yaml")


def export_base_model():
    """直接导出预训练 YOLOv8n 为 Core ML (不含游戏UI微调)"""
    print("=== 导出 YOLOv8n 基础模型 -> Core ML ===")
    try:
        from ultralytics import YOLO
    except ImportError:
        print("错误: 请先安装 ultralytics")
        print("  pip install ultralytics")
        sys.exit(1)

    model = YOLO("yolov8n.pt")
    print("下载 YOLOv8n 预训练权重...")

    # 导出为 Core ML (内置NMS, 640x640输入)
    model.export(
        format="coreml",
        nms=True,           # 内置非极大值抑制
        imgsz=640,          # 输入尺寸
        int8=False,         # FP16 精度 (平衡精度和速度)
        half=True,
        verbose=True,
    )

    # 移动文件到项目目录
    src = "yolov8n.mlmodel"
    if os.path.exists(src):
        os.rename(src, MODEL_OUTPUT)
        size_mb = os.path.getsize(MODEL_OUTPUT) / (1024 * 1024)
        print(f"✅ 模型已导出: {MODEL_OUTPUT} ({size_mb:.1f} MB)")
    else:
        # 尝试 .mlpackage 格式
        src_pkg = "yolov8n.mlpackage"
        if os.path.exists(src_pkg):
            print(f"⚠ 导出为 .mlpackage 格式: {src_pkg}")
            print("  需要 iOS 14+, 请确保部署目标匹配")
            # 如果是 mlpackage, 直接使用
            import shutil
            dest = MODEL_OUTPUT.replace(".mlmodel", ".mlpackage")
            if os.path.exists(dest):
                shutil.rmtree(dest)
            shutil.move(src_pkg, dest)
            print(f"✅ 模型已导出: {dest}")
        else:
            print("❌ 导出失败，未找到输出文件")
            sys.exit(1)


def train_and_export():
    """用自定义数据集微调后导出 (需要标注数据)"""
    print("=== 训练 HOK UI 检测模型 ===")
    try:
        from ultralytics import YOLO
    except ImportError:
        print("错误: 请先安装 ultralytics")
        sys.exit(1)

    if not os.path.exists(DATASET_YAML):
        print(f"⚠ 数据集配置文件不存在: {DATASET_YAML}")
        print("  使用基础模型替代...")
        export_base_model()
        return

    model = YOLO("yolov8n.pt")

    # 微调训练
    model.train(
        data=DATASET_YAML,
        epochs=50,
        imgsz=640,
        batch=8,
        device="mps" if _has_mps() else "cpu",  # Apple Silicon GPU 加速
        verbose=True,
    )

    # 导出
    model.export(format="coreml", nms=True, imgsz=640, half=True)
    src = "yolov8n.mlmodel"
    if os.path.exists(src):
        os.rename(src, MODEL_OUTPUT)
        print(f"✅ 微调模型已导出: {MODEL_OUTPUT}")
    else:
        print("❌ 导出失败")


def create_dataset_template():
    """生成数据集目录模板"""
    ds_dir = os.path.join(os.path.dirname(__file__), "..", "datasets", "hok_ui")
    os.makedirs(os.path.join(ds_dir, "train", "images"), exist_ok=True)
    os.makedirs(os.path.join(ds_dir, "train", "labels"), exist_ok=True)
    os.makedirs(os.path.join(ds_dir, "val", "images"), exist_ok=True)
    os.makedirs(os.path.join(ds_dir, "val", "labels"), exist_ok=True)

    yaml_content = """# HOK UI 目标检测数据集配置
path: .
train: train/images
val: val/images

nc: 7
names:
  0: button
  1: close_button
  2: popup
  3: tab
  4: icon
  5: badge
  6: input
"""
    with open(os.path.join(ds_dir, "data.yaml"), "w") as f:
        f.write(yaml_content)
    print(f"✅ 数据集模板创建于: {ds_dir}")
    print("  将标注截图放入 train/images/, 标注文件放入 train/labels/")


def _has_mps():
    """检查是否支持 Apple Metal Performance Shaders"""
    try:
        import torch
        return torch.backends.mps.is_available()
    except Exception:
        return False


if __name__ == "__main__":
    print("=" * 50)
    print("  HOK UI YOLO Model Exporter")
    print("=" * 50)
    print()

    if len(sys.argv) > 1 and sys.argv[1] == "--init-dataset":
        create_dataset_template()
    elif len(sys.argv) > 1 and sys.argv[1] == "--train":
        train_and_export()
    else:
        export_base_model()
        print()
        print("提示:")
        print("  --init-dataset  生成数据集目录模板")
        print("  --train         用自定义数据集微调后导出")
