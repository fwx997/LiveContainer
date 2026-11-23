"""Validate SI intent coverage and execute production result/entity conversion."""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SWIFTC = shutil.which("swiftc")
SOURCE = ROOT / "LaunchAppExtension/SideInstallerIntents.swift"
ACTIONS = {
    "GetSideloadedAppsIntent", "RefreshAllAppsIntent", "RefreshAppIntent",
    "InstallAppIntent", "InstallIPAIntent", "InstallIPAFromURLIntent",
    "IsTunnelConnectedIntent", "ConnectLocalDevVPNIntent", "GetPairingFileIntent",
    "ImportPairingFileIntent", "InstallPairingIntoAppsIntent", "ShowDeveloperModeIntent",
    "GetActivityLogIntent", "SetLocationIntent", "SetCoordinatesIntent", "SetSavedPlaceIntent",
    "ResetLocationIntent", "GetSpoofedLocationIntent", "IsLocationSpoofedIntent",
    "SavePlaceIntent", "DeleteSavedPlaceIntent", "PlayGPXRouteIntent",
    "TravelToPlaceIntent", "StopRouteIntent",
}


ADAPTERS = r'''
import Foundation

struct CLLocationCoordinate2D {
    let latitude: Double
    let longitude: Double
}
func CLLocationCoordinate2DIsValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
    coordinate.latitude.isFinite && coordinate.longitude.isFinite &&
        (-90...90).contains(coordinate.latitude) && (-180...180).contains(coordinate.longitude)
}
struct CLLocation {
    let coordinate: CLLocationCoordinate2D
    init(latitude: Double, longitude: Double) {
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
struct CLPlacemark {
    var location: CLLocation?
    var name: String?
    init(location: CLLocation?, name: String?, postalAddress: String?) {
        self.location = location
        self.name = name
    }
}
typealias TypeDisplayRepresentation = String
struct DisplayRepresentation {
    struct Image { init(systemName: String) {} }
    init(title: String, subtitle: String?, image: Image) {}
}
struct IntentDialog {
    let text: String
    init(_ text: String) { self.text = text }
}
protocol AppEntity {}
protocol EntityQuery {}
protocol EnumerableEntityQuery {}
protocol EntityStringQuery {}
@propertyWrapper struct Property<Value> {
    var storage: Value?
    init(title: String) {}
    var wrappedValue: Value {
        get { storage! }
        set { storage = newValue }
    }
}
@MainActor enum SIShortcutClient {
    static var cache: [String: Any] = ["value": []]
    static var receivedAction = ""
    static var receivedParameters: [String: Any] = [:]
    static func cached(action: String, parameters: [String: Any]) throws -> [String: Any] {
        receivedAction = action
        receivedParameters = parameters
        return cache
    }
}
'''


MAIN = r'''
enum HarnessError: Error { case expectedRejection }
func rejects(_ operation: () throws -> Void) throws {
    do { try operation() }
    catch { return }
    throw HarnessError.expectedRejection
}

@main struct IntentConversionRegression {
    @MainActor static func main() async throws {
        let id = UUID()
        let object: [String: Any] = ["id": id.uuidString, "name": "Home", "latitude": 41.9, "longitude": 12.5]
        let saved = try SISavedPlaceEntity(object)
        precondition(saved.id == id && saved.name == "Home")
        precondition(saved.location?.location?.coordinate.latitude == 41.9)
        precondition(saved.parameters["id"] as? String == id.uuidString)
        precondition(saved.parameters["longitude"] as? Double == 12.5)
        let place = try SIShortcutValue.place(object)
        let parameters = try SIShortcutValue.parameters(place)
        precondition(parameters["latitude"] as? Double == 41.9)
        precondition(parameters["name"] as? String == "Home")
        try rejects { _ = try SIShortcutValue.coordinate(["latitude": Double.nan, "longitude": 0.0]) }
        try rejects { _ = try SIShortcutValue.coordinate(["latitude": 0.0, "longitude": 180.1]) }
        try rejects { _ = try SIShortcutValue.coordinate(["latitude": 0.0]) }
        try rejects { _ = try SISavedPlaceEntity(["id": "invalid", "name": "Home", "latitude": 0.0, "longitude": 0.0]) }
        try rejects { _ = try SIShortcutValue.parameters(CLPlacemark(location: nil, name: nil, postalAddress: nil)) }

        let appObject: [String: Any] = ["id": "com.example.app", "name": "Example", "bundleID": "com.example.app",
                                      "version": "1.2", "expirationDate": 1_800_000_000.0,
                                      "daysLeft": 6, "canBeRefreshed": true, "expiry": "6 days"]
        let app = try SISideloadedAppEntity(appObject)
        precondition(app.id == "com.example.app" && app.name == "Example" && app.canBeRefreshed)
        precondition(app.version == "1.2" && app.daysLeft == 6)
        precondition(app.expirationDate?.timeIntervalSince1970 == 1_800_000_000.0)
        let placeholder = SISideloadedAppEntity(placeholder: "com.example.missing")
        precondition(placeholder.name == placeholder.id && !placeholder.canBeRefreshed && placeholder.expirationDate == nil)
        try rejects { _ = try SISideloadedAppEntity(["id": "x", "name": "x", "bundleID": "x"]) }
        let disconnected = try SIShortcutValue.bool(["value": false])
        precondition(!disconnected)
        try rejects { _ = try SIShortcutValue.bool(["value": "false"]) }
        precondition(SIShortcutValue.dialog(["dialog": "Completed"]).text == "Completed")

        SIShortcutClient.cache = ["value": [object]]
        let places = try await SISavedPlaceQuery().entities(for: [id])
        precondition(places.count == 1 && places[0].id == id)
        precondition(SIShortcutClient.receivedAction == "SavedPlaceQuery")
        precondition(SIShortcutClient.receivedParameters["identifiers"] as? [String] == [id.uuidString])
        _ = try await SISavedPlaceQuery().entities(matching: "Home")
        precondition(SIShortcutClient.receivedParameters["matching"] as? String == "Home")
        SIShortcutClient.cache = ["value": [appObject]]
        let apps = try await SISideloadedAppQuery().entities(for: ["com.example.app", "com.example.missing"])
        precondition(apps.map(\.id) == ["com.example.app", "com.example.missing"])
        precondition(apps[0].canBeRefreshed && !apps[1].canBeRefreshed)
        precondition(SIShortcutClient.receivedAction == "SideloadedAppQuery")
        print("PASS: native SI result types, malformed response rejection, and cached entity queries")
    }
}
'''


def production_harness():
    source = SOURCE.read_text(encoding="utf-8")
    start = source.index("enum SIShortcutValue {")
    end = source.index("@available(iOS 17.4, *)\nenum SIInstallableApp:", start)
    return ADAPTERS + source[start:end] + MAIN


class SideInstallerIntentsTests(unittest.TestCase):
    def test_all_actions_are_native_and_preserve_the_extension_process(self):
        source = SOURCE.read_text(encoding="utf-8")
        actions = re.findall(r'SIShortcutClient.perform\(action: "([^"]+)"', source)
        self.assertEqual(set(actions), ACTIONS)
        self.assertEqual(len(actions), len(ACTIONS))
        self.assertEqual(set(re.findall(r"struct SI(\w+Intent): AppIntent", source)), ACTIONS)
        self.assertNotRegex(source, r"static\s+(?:let|var)\s+openAppWhenRun\s*[:=]")
        self.assertEqual(source.count("AppShortcut(intent:"), 7)

    def test_production_conversion_source_is_extracted(self):
        source = production_harness()
        self.assertIn("enum SIShortcutValue", source)
        self.assertIn("struct SISideloadedAppQuery", source)
        self.assertNotIn("enum SIInstallableApp", source)

    @unittest.skipUnless(SWIFTC, "swiftc is required to execute production SI result conversion")
    def test_production_result_types_and_cached_entities(self):
        with tempfile.TemporaryDirectory(prefix="si-intents-") as directory:
            source = Path(directory) / "IntentConversions.swift"
            binary = Path(directory) / "IntentConversions"
            source.write_text(production_harness(), encoding="utf-8")
            result = subprocess.run([SWIFTC, "-swift-version", "5", "-parse-as-library", str(source), "-o", str(binary)],
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
