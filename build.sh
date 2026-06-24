#!/bin/bash
# Mac 上一键构建脚本

set -e

echo "=== 安装 xcodegen ==="
brew install xcodegen 2>/dev/null || echo "已安装"

echo "=== 生成 Xcode 项目 ==="
xcodegen generate

echo "=== 构建无签名 IPA ==="
xcodebuild -project HOKAuto.xcodeproj \
    -scheme HOKAuto \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath build 2>&1 | tail -5

echo "=== 打包 IPA ==="
APP=$(find build -name "HOKAuto.app" -type d | head -1)
if [ -d "$APP" ]; then
    mkdir -p Payload
    cp -r "$APP" Payload/
    zip -r HOKAuto.ipa Payload/
    rm -rf Payload
    echo "=== 成功: HOKAuto.ipa ==="
else
    echo "构建失败，请检查 Xcode 输出"
fi
