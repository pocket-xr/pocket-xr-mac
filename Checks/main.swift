import Foundation

// Pocket XR's core checks, for a Mac without XCTest (Command Line Tools only): scripts/core-check.sh builds the core
// with every file in Checks/ and runs it. Each area adds its own file with one function, called from here.

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !ok {
        failures += 1
        print("FAIL \(file):\(line): \(what())")
    }
}

func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

settingsChecks()
trackingChecks()
layoutChecks()
glassesChecks()
tourChecks()
controllerChecks()
launcherChecks()
handChecks()
pcScreenChecks()

print(failures == 0 ? "core checks: all \(checks) passed" : "core checks: \(failures) of \(checks) FAILED")
exit(failures == 0 ? 0 : 1)
