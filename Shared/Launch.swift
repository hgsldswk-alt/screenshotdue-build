import Foundation

enum Launch {
    static let freePeriod = false
    static let appGroup = "group.com.hgsldswk.screenshotdue"
    static let proID = "com.hgsldswk.screenshotdue.pro"
    static let trialID = "com.hgsldswk.screenshotdue.trial"
    static let testing = ProcessInfo.processInfo.arguments.contains("-ui-testing")
    static func has(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains(flag) }
}
