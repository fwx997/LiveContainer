import AppIntents
import Contacts
import CoreLocation
import Foundation
import Intents
import UniformTypeIdentifiers

// These native intents live in the extension so their result survives a switch
// from LiveContainer or SideStore to SideInstaller. The client owns that switch;
// openAppWhenRun must not move execution into the host's different Swift module.

@available(iOS 17.4, *)
enum SIShortcutValue {
    static func invalid(_ field: String) -> NSError {
        NSError(domain: "SideInstallerShortcuts", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "SideInstaller returned an invalid \(field)."])
    }

    static func object(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw invalid("object") }
        return object
    }

    static func objects(_ value: Any?) throws -> [[String: Any]] {
        guard let objects = value as? [[String: Any]] else { throw invalid("list") }
        return objects
    }

    static func string(_ value: Any?, _ field: String = "text") throws -> String {
        guard let value = value as? String else { throw invalid(field) }
        return value
    }

    static func bool(_ response: [String: Any]) throws -> Bool {
        guard let value = response["value"] as? Bool else { throw invalid("Boolean result") }
        return value
    }

    static func coordinate(_ object: [String: Any]) throws -> CLLocationCoordinate2D {
        guard let latitude = object["latitude"] as? Double,
              let longitude = object["longitude"] as? Double,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { throw invalid("coordinate") }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func place(_ object: [String: Any]) throws -> CLPlacemark {
        let coordinate = try coordinate(object)
        return CLPlacemark(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                           name: object["name"] as? String, postalAddress: nil)
    }

    static func parameters(_ place: CLPlacemark) throws -> [String: Any] {
        guard let coordinate = place.location?.coordinate,
              CLLocationCoordinate2DIsValid(coordinate) else { throw invalid("place coordinate") }
        var result: [String: Any] = ["latitude": coordinate.latitude, "longitude": coordinate.longitude]
        if let name = place.name { result["name"] = name }
        return result
    }

    static func dialog(_ response: [String: Any], fallback: String = "Done.") -> IntentDialog {
        let text = response["dialog"] as? String ?? fallback
        return IntentDialog("\(text)")
    }
}

@available(iOS 17.4, *)
struct SISavedPlaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "SI Saved Place"
    static let defaultQuery = SISavedPlaceQuery()
    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Latitude") var latitude: Double
    @Property(title: "Longitude") var longitude: Double
    @Property(title: "Location") var location: CLPlacemark?

    init(_ object: [String: Any]) throws {
        guard let id = UUID(uuidString: try SIShortcutValue.string(object["id"], "place ID"))
        else { throw SIShortcutValue.invalid("place ID") }
        let coordinate = try SIShortcutValue.coordinate(object)
        self.id = id
        name = try SIShortcutValue.string(object["name"], "place name")
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        location = try SIShortcutValue.place(object)
    }

    var parameters: [String: Any] {
        ["id": id.uuidString, "name": name, "latitude": latitude, "longitude": longitude]
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(latitude), \(longitude)",
                              image: .init(systemName: "mappin.circle.fill"))
    }
}

@available(iOS 17.4, *)
struct SISavedPlaceQuery: EnumerableEntityQuery, EntityStringQuery {
    @MainActor private func read(_ parameters: [String: Any] = [:]) throws -> [SISavedPlaceEntity] {
        let response = try SIShortcutClient.cached(action: "SavedPlaceQuery", parameters: parameters)
        return try SIShortcutValue.objects(response["value"]).map(SISavedPlaceEntity.init)
    }

    @MainActor func entities(for identifiers: [UUID]) async throws -> [SISavedPlaceEntity] {
        try read(["identifiers": identifiers.map(\.uuidString)])
    }

    @MainActor func allEntities() async throws -> [SISavedPlaceEntity] { try read() }
    @MainActor func suggestedEntities() async throws -> [SISavedPlaceEntity] { try read() }
    @MainActor func entities(matching string: String) async throws -> [SISavedPlaceEntity] {
        try read(["matching": string])
    }
}

@available(iOS 17.4, *)
struct SISideloadedAppEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "SI Sideloaded App"
    static let defaultQuery = SISideloadedAppQuery()
    let id: String
    private let expiry: String
    @Property(title: "Name") var name: String
    @Property(title: "Bundle ID") var bundleID: String
    @Property(title: "Version") var version: String?
    @Property(title: "Expiration Date") var expirationDate: Date?
    @Property(title: "Days Left") var daysLeft: Int?
    @Property(title: "Can Be Refreshed") var canBeRefreshed: Bool

    init(_ object: [String: Any]) throws {
        id = try SIShortcutValue.string(object["id"], "app ID")
        expiry = object["expiry"] as? String ?? ""
        name = try SIShortcutValue.string(object["name"], "app name")
        bundleID = try SIShortcutValue.string(object["bundleID"], "bundle ID")
        version = object["version"] as? String
        expirationDate = (object["expirationDate"] as? Double).map(Date.init(timeIntervalSince1970:))
        daysLeft = object["daysLeft"] as? Int
        guard let refreshable = object["canBeRefreshed"] as? Bool else {
            throw SIShortcutValue.invalid("refresh availability")
        }
        canBeRefreshed = refreshable
    }

    init(placeholder id: String) {
        self.id = id
        expiry = ""
        name = id
        bundleID = id
        version = nil
        expirationDate = nil
        daysLeft = nil
        canBeRefreshed = false
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: expiry.isEmpty ? nil : "\(expiry)",
                              image: .init(systemName: "app.badge"))
    }
}

@available(iOS 17.4, *)
struct SISideloadedAppQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [SISideloadedAppEntity] {
        let response = try SIShortcutClient.cached(action: "SideloadedAppQuery", parameters: ["identifiers": identifiers])
        let known = try SIShortcutValue.objects(response["value"]).map(SISideloadedAppEntity.init)
        return identifiers.map { id in known.first { $0.id == id } ?? SISideloadedAppEntity(placeholder: id) }
    }

    @MainActor func suggestedEntities() async throws -> [SISideloadedAppEntity] {
        let response = try SIShortcutClient.cached(action: "SideloadedAppQuery", parameters: [:])
        return try SIShortcutValue.objects(response["value"]).map(SISideloadedAppEntity.init)
    }
}

@available(iOS 17.4, *)
enum SIInstallableApp: String, AppEnum {
    case sideStore, liveContainer, madeira, altStore
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "SI Installable App"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .sideStore: "SideStore", .liveContainer: "LiveContainer + SideStore",
        .madeira: "Madeira", .altStore: "AltStore",
    ]
}

@available(iOS 17.4, *)
enum SIReleaseTrack: String, AppEnum {
    case stable, nightly
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Release"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.stable: "Stable", .nightly: "Nightly"]
}

@available(iOS 17.4, *)
enum SIRouteSpeed: String, AppEnum {
    case recorded, walk, cycle, drive
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Route Speed"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .recorded: "As Recorded", .walk: "Walk", .cycle: "Cycle", .drive: "Drive",
    ]
}

@available(iOS 17.4, *)
enum SITravelMode: String, AppEnum {
    case walk, cycle, drive
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Travel Mode"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.walk: "Walk", .cycle: "Cycle", .drive: "Drive"]
}

@available(iOS 17.4, *)
struct SIGetSideloadedAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Get Sideloaded Apps"
    static let description = IntentDescription("Lists SideInstaller's sideloaded apps with their expiration dates.", categoryName: "SideInstaller · Apps")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[SISideloadedAppEntity]> {
        let response = try await SIShortcutClient.perform(action: "GetSideloadedAppsIntent", parameters: [:])
        return .result(value: try SIShortcutValue.objects(response["value"]).map(SISideloadedAppEntity.init))
    }
}

@available(iOS 17.4, *)
struct SIRefreshAllAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Refresh All Apps"
    static let description = IntentDescription("Refreshes the apps whose IPA SideInstaller has saved. Returns the completed refresh report.", categoryName: "SideInstaller · Apps")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "RefreshAllAppsIntent", parameters: [:])
        let report = try SIShortcutValue.string(response["value"])
        return .result(value: report, dialog: SIShortcutValue.dialog(response, fallback: report))
    }
}

@available(iOS 17.4, *)
struct SIRefreshAppIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Refresh App"
    static let description = IntentDescription("Refreshes one app using SideInstaller's saved IPA.", categoryName: "SideInstaller · Apps")
    @Parameter(title: "App", requestValueDialog: "Which app?") var app: SISideloadedAppEntity
    static var parameterSummary: some ParameterSummary { Summary("Refresh \(\.$app) in SI") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "RefreshAppIntent", parameters: ["app": app.id])
        let report = try SIShortcutValue.string(response["value"])
        return .result(value: report, dialog: SIShortcutValue.dialog(response, fallback: report))
    }
}

@available(iOS 17.4, *)
struct SIInstallAppIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Install App"
    static let description = IntentDescription("Opens SideInstaller to install the selected app and waits for the installation result.", categoryName: "SideInstaller · Install")
    @Parameter(title: "App", default: .sideStore) var app: SIInstallableApp
    @Parameter(title: "Release", default: .stable) var release: SIReleaseTrack
    static var parameterSummary: some ParameterSummary { Summary("Install \(\.$app) in SI") { \.$release } }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "InstallAppIntent", parameters: ["app": app.rawValue, "release": release.rawValue])
        return .result(dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SIInstallIPAIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Install IPA"
    static let description = IntentDescription("Opens SideInstaller to install an IPA file and waits for the installation result.", categoryName: "SideInstaller · Install")
    @Parameter(title: "IPA File") var file: IntentFile
    static var parameterSummary: some ParameterSummary { Summary("Install \(\.$file) in SI") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "InstallIPAIntent", parameters: ["file": file])
        return .result(dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SIInstallIPAFromURLIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Install IPA from URL"
    static let description = IntentDescription("Downloads and installs an IPA through SideInstaller, returning when it finishes.", categoryName: "SideInstaller · Install")
    @Parameter(title: "URL") var url: URL
    static var parameterSummary: some ParameterSummary { Summary("Install the IPA at \(\.$url) in SI") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "InstallIPAFromURLIntent", parameters: ["url": url.absoluteString])
        return .result(dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SIIsTunnelConnectedIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Is LocalDevVPN Connected"
    static let description = IntentDescription("Reports whether SideInstaller can see the LocalDevVPN tunnel.", categoryName: "SideInstaller · Device")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let response = try await SIShortcutClient.perform(action: "IsTunnelConnectedIntent", parameters: [:])
        return .result(value: try SIShortcutValue.bool(response))
    }
}

@available(iOS 17.4, *)
struct SIConnectLocalDevVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Connect LocalDevVPN"
    static let description = IntentDescription("Opens LocalDevVPN through SideInstaller and waits for the connection.", categoryName: "SideInstaller · Device")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "ConnectLocalDevVPNIntent", parameters: [:])
        return .result(value: try SIShortcutValue.bool(response), dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SIGetPairingFileIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Get Pairing File"
    static let description = IntentDescription("Exports SideInstaller's pairing file. Keep it private; it grants access to this device.", categoryName: "SideInstaller · Device")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let response = try await SIShortcutClient.perform(action: "GetPairingFileIntent", parameters: [:])
        let value = try SIShortcutValue.object(response["value"])
        let filename = try SIShortcutValue.string(value["filename"], "filename")
        guard let data = Data(base64Encoded: try SIShortcutValue.string(value["dataBase64"], "pairing file")) else {
            throw SIShortcutValue.invalid("pairing file")
        }
        return .result(value: IntentFile(data: data, filename: (filename as NSString).lastPathComponent, type: .propertyList))
    }
}

@available(iOS 17.4, *)
struct SIImportPairingFileIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Import Pairing File"
    static let description = IntentDescription("Imports a pairing file into SideInstaller.", categoryName: "SideInstaller · Device")
    @Parameter(title: "Pairing File", supportedTypeIdentifiers: ["com.frizzlem.sideinstaller.mobiledevicepairing", "com.apple.property-list", "public.xml", "public.data"])
    var file: IntentFile
    static var parameterSummary: some ParameterSummary { Summary("Import \(\.$file) into SI") }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try await SIShortcutClient.perform(action: "ImportPairingFileIntent", parameters: ["file": file])
        return .result()
    }
}

@available(iOS 17.4, *)
struct SIInstallPairingIntoAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Install Pairing File into Apps"
    static let description = IntentDescription("Installs SideInstaller's pairing file into supported apps and returns their names.", categoryName: "SideInstaller · Device")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "InstallPairingIntoAppsIntent", parameters: [:])
        guard let names = response["value"] as? [String] else { throw SIShortcutValue.invalid("app names") }
        return .result(value: names, dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SIShowDeveloperModeIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Show Developer Mode in Settings"
    static let description = IntentDescription("Makes the Developer Mode switch appear in Settings through SideInstaller.", categoryName: "SideInstaller · Device")
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "ShowDeveloperModeIntent", parameters: [:])
        return .result(dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SIGetActivityLogIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Get Activity Log"
    static let description = IntentDescription("Returns SideInstaller's activity log with private information removed.", categoryName: "SideInstaller · Device")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let response = try await SIShortcutClient.perform(action: "GetActivityLogIntent", parameters: [:])
        return .result(value: try SIShortcutValue.string(response["value"]))
    }
}

@available(iOS 17.4, *)
struct SISetLocationIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Set Location"
    static let description = IntentDescription("Sets the device's simulated location through SideInstaller.", categoryName: "SideInstaller · Location")
    @Parameter(title: "Place") var place: CLPlacemark
    static var parameterSummary: some ParameterSummary { Summary("Set SI location to \(\.$place)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<CLPlacemark> & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "SetLocationIntent", parameters: ["place": try SIShortcutValue.parameters(place)])
        return .result(value: try SIShortcutValue.place(SIShortcutValue.object(response["value"])), dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SISetCoordinatesIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Set Location to Coordinates"
    static let description = IntentDescription("Sets SideInstaller's simulated location to latitude and longitude.", categoryName: "SideInstaller · Location")
    @Parameter(title: "Latitude", controlStyle: .field, inclusiveRange: (-90, 90)) var latitude: Double
    @Parameter(title: "Longitude", controlStyle: .field, inclusiveRange: (-180, 180)) var longitude: Double
    static var parameterSummary: some ParameterSummary { Summary("Set SI location to \(\.$latitude), \(\.$longitude)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<CLPlacemark> & ProvidesDialog {
        let parameters: [String: Any] = ["latitude": latitude, "longitude": longitude]
        _ = try SIShortcutValue.coordinate(parameters)
        let response = try await SIShortcutClient.perform(action: "SetCoordinatesIntent", parameters: parameters)
        return .result(value: try SIShortcutValue.place(SIShortcutValue.object(response["value"])), dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SISetSavedPlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Set Location to Saved Place"
    static let description = IntentDescription("Sets SideInstaller's simulated location to a saved place.", categoryName: "SideInstaller · Location")
    @Parameter(title: "Saved Place", requestValueDialog: "Which saved place?") var place: SISavedPlaceEntity
    static var parameterSummary: some ParameterSummary { Summary("Set SI location to \(\.$place)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SISavedPlaceEntity> & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "SetSavedPlaceIntent", parameters: ["place": place.parameters])
        return .result(value: try SISavedPlaceEntity(SIShortcutValue.object(response["value"])), dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SIResetLocationIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Reset Location"
    static let description = IntentDescription("Stops SideInstaller's simulated location and restores the device's own location.", categoryName: "SideInstaller · Location")
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "ResetLocationIntent", parameters: [:])
        return .result(dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SIGetSpoofedLocationIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Get Spoofed Location"
    static let description = IntentDescription("Returns SideInstaller's current simulated place, or no value when it is inactive.", categoryName: "SideInstaller · Location")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<CLPlacemark?> & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "GetSpoofedLocationIntent", parameters: [:])
        let place: CLPlacemark?
        if let object = response["value"], !(object is NSNull) {
            place = try SIShortcutValue.place(SIShortcutValue.object(object))
        } else {
            place = nil
        }
        return .result(value: place, dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SIIsLocationSpoofedIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Is Location Spoofed"
    static let description = IntentDescription("Reports whether SideInstaller is simulating the device's location.", categoryName: "SideInstaller · Location")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let response = try await SIShortcutClient.perform(action: "IsLocationSpoofedIntent", parameters: [:])
        return .result(value: try SIShortcutValue.bool(response))
    }
}

@available(iOS 17.4, *)
struct SISavePlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Save Place"
    static let description = IntentDescription("Adds a saved place to SideInstaller's location page.", categoryName: "SideInstaller · Location")
    @Parameter(title: "Place") var place: CLPlacemark
    @Parameter(title: "Name") var name: String?
    static var parameterSummary: some ParameterSummary { Summary("Save \(\.$place) in SI as \(\.$name)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SISavedPlaceEntity> {
        var parameters: [String: Any] = ["place": try SIShortcutValue.parameters(place)]
        if let name { parameters["name"] = name }
        let response = try await SIShortcutClient.perform(action: "SavePlaceIntent", parameters: parameters)
        return .result(value: try SISavedPlaceEntity(SIShortcutValue.object(response["value"])))
    }
}

@available(iOS 17.4, *)
struct SIDeleteSavedPlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Delete Saved Place"
    static let description = IntentDescription("Deletes a place from SideInstaller's saved places.", categoryName: "SideInstaller · Location")
    @Parameter(title: "Saved Place") var place: SISavedPlaceEntity
    static var parameterSummary: some ParameterSummary { Summary("Delete \(\.$place) from SI") }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try await SIShortcutClient.perform(action: "DeleteSavedPlaceIntent", parameters: ["place": place.id.uuidString])
        return .result()
    }
}

@available(iOS 17.4, *)
struct SIPlayGPXRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Play GPX Route"
    static let description = IntentDescription("Starts a GPX route in SideInstaller and returns when playback has started.", categoryName: "SideInstaller · Location")
    @Parameter(title: "GPX File", supportedTypeIdentifiers: ["com.topografix.gpx", "public.xml", "public.data"]) var file: IntentFile
    @Parameter(title: "Speed") var speed: SIRouteSpeed?
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$file) in SI") { \.$speed } }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        var parameters: [String: Any] = ["file": file]
        if let speed { parameters["speed"] = speed.rawValue }
        let response = try await SIShortcutClient.perform(action: "PlayGPXRouteIntent", parameters: parameters)
        return .result(dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SITravelToPlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Travel to Place"
    static let description = IntentDescription("Plans and starts a route in SideInstaller, returning when playback starts.", categoryName: "SideInstaller · Location")
    @Parameter(title: "Destination") var destination: CLPlacemark
    @Parameter(title: "Travel By", default: .walk) var mode: SITravelMode
    @Parameter(title: "Start") var start: CLPlacemark?
    static var parameterSummary: some ParameterSummary { Summary("\(\.$mode) to \(\.$destination) in SI") { \.$start } }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        var parameters: [String: Any] = ["destination": try SIShortcutValue.parameters(destination), "mode": mode.rawValue]
        if let start { parameters["start"] = try SIShortcutValue.parameters(start) }
        let response = try await SIShortcutClient.perform(action: "TravelToPlaceIntent", parameters: parameters)
        return .result(dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SIStopRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "SI · Stop Route"
    static let description = IntentDescription("Stops SideInstaller's route while leaving the location at its current point.", categoryName: "SideInstaller · Location")
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await SIShortcutClient.perform(action: "StopRouteIntent", parameters: [:])
        return .result(dialog: SIShortcutValue.dialog(response))
    }
}

@available(iOS 17.4, *)
struct SISideInstallerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SISetSavedPlaceIntent(), phrases: ["Set my SideInstaller location with \(.applicationName)"],
                    shortTitle: "SI · Spoof Location", systemImageName: "location.fill")
        AppShortcut(intent: SIResetLocationIntent(), phrases: ["Reset my SideInstaller location with \(.applicationName)"],
                    shortTitle: "SI · Reset Location", systemImageName: "location.slash")
        AppShortcut(intent: SIStopRouteIntent(), phrases: ["Stop my SideInstaller route with \(.applicationName)"],
                    shortTitle: "SI · Stop Route", systemImageName: "stop.circle")
        AppShortcut(intent: SIGetSpoofedLocationIntent(), phrases: ["Get my SideInstaller location with \(.applicationName)"],
                    shortTitle: "SI · Spoofed Location", systemImageName: "mappin.and.ellipse")
        AppShortcut(intent: SIRefreshAllAppsIntent(), phrases: ["Refresh my SideInstaller apps with \(.applicationName)"],
                    shortTitle: "SI · Refresh Apps", systemImageName: "arrow.clockwise")
        AppShortcut(intent: SIInstallAppIntent(), phrases: ["Install an app in SideInstaller with \(.applicationName)"],
                    shortTitle: "SI · Install App", systemImageName: "square.and.arrow.down")
        AppShortcut(intent: SIConnectLocalDevVPNIntent(), phrases: ["Connect SideInstaller VPN with \(.applicationName)"],
                    shortTitle: "SI · Connect VPN", systemImageName: "network")
    }
}
