#!/bin/zsh
# 克隆 KeyboardShortcuts 3.1.0 到 ./KeyboardShortcuts，并去掉 CLT-only 环境下缺失的 SwiftUI 宏用法：
#   1) Recorder.swift 末尾 3 个 #Preview（需要 PreviewsMacros 插件，仅 Xcode 自带）
#   2) ConflictPolicy.swift 的 @Entry（需要 SwiftUIMacros 插件，仅 Xcode 自带），改写为手写 EnvironmentKey
set -euo pipefail
cd "${0:A:h}"
rm -rf KeyboardShortcuts
git clone --quiet --depth 1 --branch 3.1.0 https://github.com/sindresorhus/KeyboardShortcuts KeyboardShortcuts
rm -rf KeyboardShortcuts/.git
perl -0pi -e 's/\n#Preview \{.*?\n\}\n//gs' KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift
perl -0pi -e 's/extension EnvironmentValues \{\n\t\@Entry\n\tvar keyboardShortcutsConflictPolicy = KeyboardShortcuts\.ConflictPolicy\.default\n\}/private struct ConflictPolicyKey: EnvironmentKey {\n\tstatic let defaultValue = KeyboardShortcuts.ConflictPolicy.default\n}\n\nextension EnvironmentValues {\n\tvar keyboardShortcutsConflictPolicy: KeyboardShortcuts.ConflictPolicy {\n\t\tget { self[ConflictPolicyKey.self] }\n\t\tset { self[ConflictPolicyKey.self] = newValue }\n\t}\n}/' KeyboardShortcuts/Sources/KeyboardShortcuts/ConflictPolicy.swift
! grep -rn "#Preview\|@Entry" KeyboardShortcuts/Sources
echo "patched OK"
