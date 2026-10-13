import ApplicationServices
import Carbon
import Foundation

// 一次性探针：检测辅助功能授权与 Secure Event Input 状态
print("AXIsProcessTrusted:", AXIsProcessTrusted())
print("IsSecureEventInputEnabled:", IsSecureEventInputEnabled())
