import Foundation

@main
struct ModuleEnablerMigrationCheck {
    static func main() {
        let old = ModuleEnabler.legacyModuleID
        let current = ModuleEnabler.moduleID

        precondition(ModuleEnabler.replacingLegacyModuleIDs(in: ["other.one", old, "other.two"])
                     == ["other.one", current, "other.two"])
        precondition(ModuleEnabler.replacingLegacyModuleIDs(in: [old, "other.one", current])
                     == ["other.one", current])
        precondition(ModuleEnabler.replacingLegacyModuleIDs(in: [old, "other.one", old])
                     == [current, "other.one"])
        precondition(ModuleEnabler.replacingLegacyModuleIDs(in: ["other.one"]) == nil)
        print("module enablement migration checks passed")
    }
}
