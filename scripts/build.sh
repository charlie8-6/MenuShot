#!/bin/bash
# 构建脚本：xcodebuild 编译（跳过签名）→ ad-hoc codesign + entitlements
# 用法: ./scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"
SCHEME="MenuShot"
APP=".build/Build/Products/$CONFIG/MenuShot.app"

echo "==> 构建时间水印"
date '+%Y-%m-%d %H:%M:%S' > Resources/BuildStamp.txt

echo "==> xcodegen 生成工程（纳入新增资源）"
xcodegen generate >/dev/null

echo "==> xcodebuild ($CONFIG, skip signing)"
xcodebuild -project MenuShot.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "==> 签名"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "MenuShotDev"; then
  codesign --force --sign MenuShotDev --entitlements Support/FinderSync.entitlements \
    "$APP/Contents/PlugIns/MenuShotFinder.appex"
  codesign --force --sign MenuShotDev --entitlements Support/App.entitlements "$APP"
  echo "==> 校验"
  codesign --verify --deep --strict "$APP"
  codesign -d --entitlements - "$APP" >/dev/null && echo "签名完成: $APP"
else
  # 无 MenuShotDev 证书时跳过 codesign：保留 xcodebuild 产物的 linker-signed ad-hoc 签名
  # （与现行可用安装一致；强改签名会导致 TCC 屏幕录制授权失效、需要重新弹窗授权）
  echo "未找到 MenuShotDev 证书，跳过 codesign（保持 linker-signed ad-hoc）"
fi

# 统一安装到 /Applications（启动台可见，TCC 授权稳定；不再复制到其他路径，避免多副本冲突）
if ditto "$APP" "/Applications/MenuShot.app" 2>/dev/null; then
  echo "已安装到 /Applications/MenuShot.app"
else
  mkdir -p "$HOME/Applications" && ditto "$APP" "$HOME/Applications/MenuShot.app" \
    && echo "已安装到 ~/Applications/MenuShot.app"
fi

# 清理构建缓存：中间产物 + 非当前配置的产物（工程目录只保留必要内容）
rm -rf .build/Build/Intermediates.noindex .build/Index.noindex
if [ "$CONFIG" = "Release" ]; then rm -rf .build/Build/Products/Debug; else rm -rf .build/Build/Products/Release; fi
echo "已清理构建缓存（工程目录 .build 仅保留 $CONFIG 产物）"
