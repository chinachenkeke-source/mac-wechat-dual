#!/bin/bash
# 一键编译并打包「微信分身管理.app」
set -e

APP_NAME="微信分身管理"
cd "$(dirname "$0")"

rm -rf build
mkdir -p "build/$APP_NAME.app/Contents/MacOS"
mkdir -p "build/$APP_NAME.app/Contents/Resources"

echo "🔨 编译 ARM64 ..."
swiftc -O -swift-version 5 -target arm64-apple-macos11.0 \
  -o /tmp/wm_arm WeChatManager.swift

echo "🔨 编译 x86_64 ..."
swiftc -O -swift-version 5 -target x86_64-apple-macos11.0 \
  -o /tmp/wm_x86 WeChatManager.swift

echo "📦 合并为通用二进制 ..."
lipo -create /tmp/wm_arm /tmp/wm_x86 \
  -output "build/$APP_NAME.app/Contents/MacOS/WeChatManager"

echo "🎨 拷贝资源 ..."
cp assets/Info.plist "build/$APP_NAME.app/Contents/Info.plist"
cp assets/AppIcon.icns "build/$APP_NAME.app/Contents/Resources/AppIcon.icns"

echo "✍️ 临时签名 ..."
codesign --force --sign - "build/$APP_NAME.app"

echo ""
echo "✅ 完成！产物在: build/$APP_NAME.app"
echo "👉 把它拖到「应用程序」文件夹即可使用"
