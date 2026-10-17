#!/bin/bash
# Regenerates Packages/AndroidEmulator's gRPC client from the SDK's emulator_controller.proto.
# Needs protoc and protoc-gen-swift (brew install protobuf swift-protobuf) and protoc-gen-grpc-swift-2, built from
# grpc-swift-protobuf at the version Package.swift pins: swift build -c release --product protoc-gen-grpc-swift-2.
#   scripts/generate-emulator-grpc.sh /path/to/protoc-gen-grpc-swift-2
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/Packages/AndroidEmulator"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
GRPC_PLUGIN="${1:?usage: $0 <protoc-gen-grpc-swift-2>}"
cp "$SDK/emulator/lib/emulator_controller.proto" "$PKG/Proto/"
protoc -I "$PKG/Proto" \
  --plugin=protoc-gen-grpc-swift="$GRPC_PLUGIN" \
  --swift_out="$PKG/Sources/AndroidEmulator/Generated" --swift_opt=Visibility=Public \
  --grpc-swift_out="$PKG/Sources/AndroidEmulator/Generated" --grpc-swift_opt=Visibility=Public,Server=false,Client=true \
  emulator_controller.proto
