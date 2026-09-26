import Foundation
import ServiceManagement
import XCTest
@testable import TKMYApp

final class LaunchAtLoginTests: XCTestCase {
    private final class Service: LaunchAtLoginService {
        var status: SMAppService.Status = .notRegistered
        var registrations = 0
        var unregistrations = 0
        var registrationError: Error?

        func register() throws {
            registrations += 1
            if let registrationError { throw registrationError }
            status = .enabled
        }

        func unregister() throws {
            unregistrations += 1
            status = .notRegistered
        }
    }

    @MainActor
    private func withSettings(_ test: (AppSettings, Service) -> Void) throws {
        let suite = "TKMYLoginTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = Service()
        test(AppSettings(defaults: defaults, loginService: service), service)
    }

    @MainActor
    func testDoesNotRegisterWithoutUserRequestAndEnablingIsIdempotent() throws {
        try withSettings { settings, service in
            XCTAssertFalse(settings.launchAtLogin)
            XCTAssertEqual(service.registrations, 0)
            settings.setLaunchAtLogin(true)
            settings.setLaunchAtLogin(true)
            XCTAssertTrue(settings.launchAtLogin)
            XCTAssertNil(settings.launchAtLoginError)
            XCTAssertEqual(service.registrations, 1)
            settings.setLaunchAtLogin(false)
            XCTAssertFalse(settings.launchAtLogin)
            XCTAssertEqual(service.unregistrations, 1)
        }
    }

    @MainActor
    func testCanCancelRegistrationAwaitingApproval() throws {
        try withSettings { settings, service in
            service.status = .requiresApproval
            settings.refreshLaunchAtLoginStatus()
            XCTAssertFalse(settings.launchAtLogin)
            settings.setLaunchAtLogin(false)
            XCTAssertEqual(service.unregistrations, 1)
            XCTAssertEqual(service.status, .notRegistered)
        }
    }

    @MainActor
    func testRegistrationFailureReportsErrorAndActualStatus() throws {
        try withSettings { settings, service in
            service.registrationError = NSError(domain: "TKMYLoginTests", code: 1)
            settings.setLaunchAtLogin(true)
            XCTAssertFalse(settings.launchAtLogin)
            XCTAssertNotNil(settings.launchAtLoginError)
            service.status = .enabled
            settings.refreshLaunchAtLoginStatus()
            XCTAssertTrue(settings.launchAtLogin)
        }
    }
}
