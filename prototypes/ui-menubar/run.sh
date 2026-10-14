#!/bin/sh
# PROTOTYPE：编译并启动菜单栏 UI 原型（一次性代码）
set -e
cd "$(dirname "$0")"
mkdir -p build
if [ "$1" = motion ]; then
  shift
  swiftc -swift-version 5 -O OverlayMotion.swift -o build/overlay-motion
  exec build/overlay-motion "$@"
fi
swiftc -swift-version 5 -O PolishUIPrototype.swift -o build/polish-ui-prototype
exec build/polish-ui-prototype
