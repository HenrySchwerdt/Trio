import Foundation
import InsightKit
import LoopKitUI
import os.log

class InsightKitPlugin: NSObject, PumpManagerUIPlugin {
    private let log = Logger(subsystem: "org.nightscout.InsightKit", category: "Plugin")

    public var pumpManagerType: PumpManagerUI.Type? {
        InsightPumpManager.self
    }

    public var cgmManagerType: CGMManagerUI.Type? {
        nil
    }

    override init() {
        super.init()
        log.debug("InsightKitPlugin instantiated")
    }
}
