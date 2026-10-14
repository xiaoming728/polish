#!/usr/bin/env python3
"""在隔离进程中运行真实的输入处理方法，不发送按键、不请求网络。"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/Polish/TypingAssist.swift').read_text()

def method(name):
    start = source.index('    private func ' + name + '(')
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end].replace('private func', 'func', 1).replace('IsSecureEventInputEnabled()', 'secureInput')

probe = '''import AppKit
import Carbon
import PolishCore
struct State { var typingAssist = true; var current = defaultProfile() }
struct PolisherStub {
 var busy = false
 static var output = ""
 func cancel() {}
 func start(_ p: Profile, apiKey: String, text: String, fast: Bool,
            onDelta: (String) -> Void, onDone: (Result<String, Error>) -> Void) {
  onDone(.success(Self.output))
 }
}
struct PanelStub { var isVisible = true; var alphaValue = 1.0 }
@MainActor enum KeyStore { static func apiKey(_ p: Profile) -> String { "test" } }
@MainActor enum Log { static func write(_ text: String) {} }
@MainActor enum HotKey {
 static var ids = Set<UInt32>()
 static func unregisterExtra(_ id: UInt32) { ids.remove(id) }
 static func registerExtra(_ id: UInt32, code: Int, mods: Int, _ run: @escaping () -> Void) { ids.insert(id) }
}
@MainActor enum IME {
 static var frame: CGRect?
 static func candidates() -> (list: [String], frame: CGRect?) { ([], frame) }
}
@MainActor enum Selection {
 static var caret: CGRect?
 static func focusedElement() -> Int? { caret == nil ? nil : 1 }
 static func caretRect(_ el: Int) -> CGRect? { caret }
 static func bounds(_ el: Int) -> CGRect? { nil }
 static func role(_ el: Int) -> String? { nil }
}
@MainActor final class Model {
 var pinyin = ""; var en: String?; var zh: String?; var error: String?; var pairs: [SentencePair] = []
}
@MainActor final class Probe {
 var state = State(); var isBusy: () -> Bool = { false }; var choosing = false
 var buffer = PinyinBuffer(); var polisher = PolisherStub(); var debounce: DispatchWorkItem?
 var candidateRead: DispatchWorkItem?; var pid: pid_t = 0
 var panel = PanelStub(); var sentencePolisher = PolisherStub()
 var sentenceNeedsConversion = false
 var sentence = ""; var sentenceResult: (text: String, t: SentenceTranslation)?
 var candidates: (pinyin: String, list: [String]) = ("", [])
 var visible = true; var model = Model()
 var terminal = false; var secureInput = false; var hintAnchor: CGRect?; var imeFrame: CGRect?
 func inTerminal() -> Bool { terminal }
 func chineseInputActive() -> Bool { true }
 func sentenceChanged() {}
 func clearSentence() { sentence = ""; sentenceNeedsConversion = false; sentenceResult = nil }
 func convert() {}
 func show() { visible = true }
 func fadeOut() { visible = false }
 func choose(english: Bool) {}
'''
probe += '\n'.join(method(n) for n in ['typedChar', 'trackSentence', 'committed', 'classify', 'feed', 'hide', 'origin', 'requestSentence', 'registerKeys'])
probe += '''
 func press(_ code: Int, char: String) {
  let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
  let units = Array(char.utf16)
  event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
  trackSentence(code, [], event)
  feed(classify(code, [], event))
 }
 func word(_ pinyin: String, _ chinese: String) {
  for c in pinyin { buffer.feed(.letter(c)) }
  candidates = (pinyin, [chinese])
 }
}
@main struct Check {
 @MainActor static func main() {
  let p = Probe()
  p.word("nihao", "你好"); p.press(kVK_Space, char: " ")
  assert(p.sentence == "你好" && p.model.pinyin == "你好" && p.visible, "空格后保留已上屏内容")
  p.word("shijie", "世界"); p.press(kVK_ANSI_Period, char: ".")
  assert(p.sentence == "你好世界。" && p.model.pinyin == "你好世界。" && p.visible, "标点后保留整句，不能只剩最后一个词")
  p.press(kVK_Delete, char: "")
  assert(p.sentence == "你好世界" && p.visible, "删除标点仍保留前文")
  p.sentenceResult = (p.sentence, SentenceTranslation(en: "Hello world", pairs: []))
  p.press(kVK_Space, char: " ")
  assert(p.sentence == "你好世界 " && p.model.pinyin == "你好世界 " && p.visible, "直接空格加入整句，提示继续保留前文")
  p.press(kVK_Return, char: "\\r")
  assert(p.sentence.isEmpty && !p.visible, "回车结束本句")
  let mixed = Probe()
  mixed.word("xiufu", "修复"); mixed.press(kVK_Space, char: " ")
  mixed.word("bug", "不顾"); mixed.press(kVK_Return, char: "\\r")
  assert(mixed.sentence == "修复bug" && mixed.buffer.text.isEmpty && mixed.visible,
         "组合态回车是确认英文：保留中文前文和 bug，不清空整句")
  mixed.sentenceResult = (mixed.sentence, SentenceTranslation(zh: "修复错误", en: "Fix the bug", pairs: []))
  mixed.hide()
  assert(mixed.model.zh == "修复bug", "已确认的英文不是未知拼音，不能用模型改写的中文覆盖原文")
  PolisherStub.output = #"{"zh":"修复错误","en":"Fix the bug","pairs":[]}"#
  mixed.requestSentence("")
  assert(mixed.sentence == "修复bug" && mixed.model.zh == "修复bug",
         "异步结果应用路径不能重写已确认的英文或退格计数")
  assert(HotKey.ids == [2, 3], "中英混编的完整结果允许使用 ⌥1 / ⌥2，不误当作未知拼音")
  mixed.word("le", "了"); mixed.press(kVK_Space, char: " ")
  assert(mixed.sentence == "修复bug了", "英文上屏后继续拼音输入，整句连续累积")
  mixed.press(kVK_Return, char: "\\r")
  assert(mixed.sentence.isEmpty && !mixed.visible, "没有组合态的回车仍结束本次输入")
  let terminalMixed = Probe(); terminalMixed.terminal = true
  terminalMixed.word("xiufu", "修复"); terminalMixed.press(kVK_Space, char: " ")
  terminalMixed.word("bug", "不顾")
  terminalMixed.press(kVK_Return, char: "\\r")
  assert(terminalMixed.sentence == "修复bug" && terminalMixed.visible, "终端中文前文后的英文回车不丢整句")
  terminalMixed.press(kVK_Return, char: "\\r")
  assert(terminalMixed.sentence.isEmpty, "真正的提交回车仍清空终端整句")
  let englishMode = Probe(); englishMode.terminal = true
  englishMode.word("xiufu", "修复"); englishMode.press(kVK_Space, char: " ")
  for c in "bug" { englishMode.press(kVK_ANSI_B, char: String(c)) }
  englishMode.press(kVK_Return, char: "\\r")
  assert(englishMode.sentence.isEmpty, "终端没有候选的英文模式回车是提交，不能误当组合态上屏")
  let password = Probe(); password.terminal = true
  for c in "secret" { password.press(kVK_ANSI_S, char: String(c)) }
  password.press(kVK_Return, char: "\\r")
  assert(password.sentence.isEmpty, "终端没有已知中文与候选窗时，未知字母不能交给模型")
  let fallback = Probe(); fallback.word("nihao", "你好"); fallback.press(kVK_Space, char: " ")
  for c in "shijie" { fallback.press(kVK_ANSI_S, char: String(c)) }
  fallback.press(kVK_Space, char: " ")
  assert(fallback.sentenceNeedsConversion, "没读到候选的拼音仍标记为未转换")
  HotKey.ids.removeAll(); fallback.model.en = "Hello world"; fallback.model.zh = "你好世界"
  fallback.registerKeys()
  assert(HotKey.ids.isEmpty, "未知拼音的实际字数未确认，不能允许退格替换")
  PolisherStub.output = #"{"zh":"你好世界","en":"Hello world","pairs":[]}"#
  fallback.requestSentence("")
  assert(fallback.sentence == "你好世界" && !fallback.sentenceNeedsConversion && HotKey.ids == [2, 3],
         "模型补全未知拼音后恢复准确原文与替换快捷键")
  let numbers = Probe()
  for c in "2026" { numbers.press(kVK_ANSI_2, char: String(c)) }
  assert(numbers.sentence == "2026" && numbers.visible, "直接输入数字应拉起提示")
  numbers.press(kVK_Space, char: " ")
  numbers.press(kVK_ANSI_3, char: "3")
  assert(numbers.sentence == "2026 3", "数字与空格必须保留在整句中")
  numbers.press(kVK_ANSI_Minus, char: "-")
  assert(numbers.sentence == "2026 3-", "其他符号也应更新提示")
  let selection = Probe(); selection.word("hao", "好")
  selection.candidates = ("hao", ["好", "号"])
  selection.press(kVK_ANSI_2, char: "2")
  assert(selection.sentence == "号", "组合态数字仍选候选，不能当数字上屏")
  let zero = Probe(); zero.word("hao", "好"); zero.press(kVK_ANSI_0, char: "0")
  assert(zero.sentence == "好0", "0 是直输数字，应保留它和前面的候选词")
  let symbol = Probe(); symbol.word("hao", "好"); symbol.press(kVK_ANSI_Equal, char: "+")
  assert(symbol.sentence == "好+", "组合态后输入符号保留候选词和符号")
  let apostrophe = Probe(); apostrophe.word("xi", "西"); apostrophe.press(kVK_ANSI_Quote, char: "'")
  assert(apostrophe.sentence.isEmpty && apostrophe.buffer.text == "xi'", "拼音分隔符不能提前提交候选")
  let secure = Probe(); secure.secureInput = true
  secure.press(kVK_ANSI_2, char: "2")
  assert(secure.sentence.isEmpty, "Secure Input 下不能记录数字")
  let terminal = Probe(); terminal.terminal = true
  terminal.press(kVK_ANSI_1, char: "1")
  assert(terminal.sentence.isEmpty, "终端未知输入不能被当作中文发送")
  terminal.word("hao", "好"); terminal.press(kVK_Space, char: " ")
  terminal.press(kVK_ANSI_2, char: "2")
  assert(terminal.sentence == "好2", "已确认中文的终端句子可累积数字")
  let position = Probe()
  let screen = NSScreen.main!.visibleFrame
  IME.frame = CGRect(x: screen.midX, y: screen.midY, width: 200, height: 32)
  let first = IME.frame!
  _ = position.origin(for: CGSize(width: 420, height: 140))
  IME.frame = first.offsetBy(dx: 0, dy: -80)
  let origin = position.origin(for: CGSize(width: 420, height: 140))!
  assert(origin.y >= first.maxY + 22, "长句换行后提示仍在首行上方，不能遮挡先前输入")
  let terminalPosition = Probe(); terminalPosition.terminal = true
  IME.frame = nil
  Selection.caret = CGRect(x: screen.minX + 4, y: screen.maxY - 24, width: 1, height: 20)
  assert(terminalPosition.origin(for: CGSize(width: 420, height: 100)) == nil,
         "终端未读到候选窗时必须隐藏，不能定位到 AX 返回的窗口第一行")
  IME.frame = CGRect(x: screen.minX + 80, y: screen.midY, width: 200, height: 32)
  let nearCaret = terminalPosition.origin(for: CGSize(width: 420, height: 100))!
  assert(nearCaret.y == screen.midY + 70, "首次候选位置不能被先前的假光标污染")
  IME.frame = IME.frame!.offsetBy(dx: 100, dy: -80)
  let moved = terminalPosition.origin(for: CGSize(width: 420, height: 100))!
  assert(moved == nearCaret, "首次定位后候选窗移动，提示仍固定在最初位置")
  IME.frame = nil
  assert(terminalPosition.origin(for: CGSize(width: 420, height: 100)) == moved,
         "候选上屏后沿用最后可信位置，不能跳回终端上方")
  terminalPosition.hide()
  IME.frame = CGRect(x: screen.minX + 180, y: screen.midY - 80, width: 200, height: 32)
  let next = terminalPosition.origin(for: CGSize(width: 420, height: 100))!
  assert(next.x == screen.minX + 180 && next.y == screen.midY - 10,
         "本次提示结束后，下次输入重新确定起始位置")
  Selection.caret = nil
  print("中英混编、整句、数字符号与首次定位固定回归检查通过")
 }
}
'''
bin_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
with tempfile.TemporaryDirectory(prefix='polish-sentence-check-') as folder:
    file = Path(folder) / 'check.swift'
    file.write_text(probe)
    binary = Path(folder) / 'check'
    subprocess.run(['swiftc', '-parse-as-library', '-I', str(bin_dir / 'Modules'), str(file),
                    *map(str, (bin_dir / 'PolishCore.build').glob('*.o')), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
