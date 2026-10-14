#!/usr/bin/env python3
"""检查真实提示视图的英文词性与异步返回后的高度，不发送输入事件。"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/Polish/TypingAssist.swift').read_text()
views = source[source.index('@MainActor\nfinal class HintModel'):].replace('private func legend(', 'func legend(', 1).replace('private func colored(', 'func colored(', 1)
start = source.index('    private func show()')
show = source[start:source.index('\n    }', start) + len('\n    }')].replace('private func', 'func', 1)
probe = '''import AppKit
import SwiftUI
import NaturalLanguage
import PolishCore
'''+(root / 'Sources/Polish/PanelBackground.swift').read_text()+(root / 'Sources/Polish/Motion.swift').read_text()+views+'''
func tr(_ zh: String, _ en: String) -> String { zh }
extension TypingLanguage { var uiName: String { name } }
struct StateStub { var targetLanguage = TypingLanguage.english; var native = TypingLanguage.chinese }
@MainActor final class Probe {
 let state = StateStub()
 let model = HintModel()
 let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
 var dismissal = 0
 lazy var probe = NSHostingController(rootView: TypingHintView(model: model))
 var lastWaiting: Bool?
 let anchor = CGRect(x: 100, y: 540, width: 510, height: 22)
 init() { panel.contentView = NSHostingView(rootView: TypingHintView(model: model)) }
 func fadeOut() { panel.orderOut(nil) }
 func origin(for size: NSSize) -> NSPoint? {
  typingHintFrame(size: size, anchor: anchor, visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600))?.origin
 }
'''+show+'''}
@main struct Check {
 @MainActor static func main() {
  NSApplication.shared.setActivationPolicy(.prohibited)
  var failures = 0
  func check(_ ok: Bool, _ name: String) {
   print("\\(ok ? "PASS" : "FAIL"): \\(name)")
   if !ok { failures += 1 }
  }
  let p = Probe()
  p.model.pinyin = "等待翻译"; p.show()
  RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  check(p.panel.frame.width == TypingHintView.width.lowerBound, "内容很短时提示框取最小宽度 240")
  check(p.model.shown, "显示后 shown 为 true，驱动出现动画和扫光")
  p.model.en = "Please give me my book and read it carefully."
  p.model.pairs = [SentencePair(zh: "给我", en: "give me"), SentencePair(zh: "我的书", en: "my book")]
  let view = TypingHintView(model: p.model)
  let labels = view.legend(p.model.en!)
  check(labels.contains("give（动词）") && labels.contains("me（代词）")
        && labels.contains("read（动词）") && labels.contains("it（代词）"), "逐词按完整英文解析，短语不能吞掉代词")
  let english = view.colored(p.model.en!, primary: true)
  check(english[english.range(of: "give me")!].foregroundColor != nil && english[english.range(of: "read")!].foregroundColor == nil,
        "只有中英对应的词着色，词性不再用颜色")
  p.model.pairs = []
  check(view.legend(p.model.en!) == labels, "中文对应关系不能改变英文词性标签")
  p.model.en = String(repeating: "Please give me my book and read it carefully. ", count: 12)
  p.model.zh = String(repeating: "请把我的书给我并仔细阅读它。", count: 12)
  p.show()
  RunLoop.main.run(until: Date().addingTimeInterval(0.2)) // 「翻译中 → 结果」窗口尺寸过渡 120ms
  let measured = p.panel.frame.size
  let actual = (p.panel.contentView as! NSHostingView<TypingHintView>).fittingSize
  check(measured.height >= actual.height, "返回成功时按实际多行高度设置面板，不能沿用等待态高度")
  check(measured.width == TypingHintView.width.upperBound, "内容很长时提示框取最大宽度 420 并折行")
  check(!p.panel.frame.intersects(p.anchor) && p.panel.frame.maxY < p.anchor.minY,
        "多行结果上方放不下时放下方，不覆盖输入区域")
  p.panel.orderOut(nil)
  exit(failures == 0 ? 0 : 1)
 }
}
'''
bin_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
with tempfile.TemporaryDirectory(prefix='polish-hint-check-') as folder:
    file = Path(folder) / 'check.swift'
    file.write_text(probe)
    binary = Path(folder) / 'check'
    subprocess.run(['swiftc', '-parse-as-library', '-I', str(bin_dir / 'Modules'), str(file),
                    *map(str, (bin_dir / 'PolishCore.build').glob('*.o')), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
