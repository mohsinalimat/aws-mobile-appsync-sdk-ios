//
// Copyright 2010-2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
// http://aws.amazon.com/apache2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//

import Foundation
import Reachability

/// Defines a factory to return a NetworkReachabilityProviding instance
protocol NetworkReachabilityProvidingFactory {
    /// Abstracting the only of Reachability's initializers that we care about into a factory method. Since Reachability isn't
    /// final, we'd have to add a lot of code to conform its initializers otherwise.
    static func make(for hostname: String) -> NetworkReachabilityProviding?
}

/// Wraps methods and properties of Reachability
protocol NetworkReachabilityProviding: class {
    /// If `true`, device can attempt to reach the host using a cellular connection (WAN). If `false`, host is only considered
    /// reachable if it can be accessed via WiFi
    var allowsCellularConnection: Bool { get set }

    var connection: Reachability.Connection { get }

    /// The notification center on which "reachability changed" events are being posted
    var notificationCenter: NotificationCenter { get set }

    /// Starts notifications for reachability changes
    func startNotifier() throws

    /// Pauses notifications for reachability changes
    func stopNotifier()
}

internal extension Notification.Name {
    static let appSyncReachabilityChanged = Notification.Name("AppSyncNetworkAvailabilityChangedNotification")
}

protocol NetworkReachabilityWatcher {
    func onNetworkReachabilityChanged(isEndpointReachable: Bool)
}

class NetworkReachabilityNotifier {
    private(set) static var shared: NetworkReachabilityNotifier?

    // Network status monitoring
    private var reachability: NetworkReachabilityProviding?
    private var allowsCellularAccess = true
    private var isInitialConnection = true

    /// A list of watchers to be notified when the network status changes
    private var networkReachabilityWatchers: [NetworkReachabilityWatcher] = []

    /// Sets up the shared `NetworkReachabilityNotifier` instance for the specified host and access rules.
    ///
    /// - Parameters:
    ///   - host: The AppSync endpoint URL
    ///   - allowsCellularAccess: If `true`, the host is considered reachable if it is accessible via cellular (WAN) connection
    ///     _or_ WiFi. If `false`, the host is only reachable if it is accessible via WiFi.
    ///   - reachabilityFactory: An optional factory for making ReachabilityProviding instances. Defaults to `Reachability.self`
    static func setupShared(host: String,
                            allowsCellularAccess: Bool,
                            reachabilityFactory: NetworkReachabilityProvidingFactory.Type?) {
        guard shared == nil else {
            return
        }

        let factory = reachabilityFactory ?? Reachability.self
        shared = NetworkReachabilityNotifier(
            host: host,
            allowsCellularAccess: allowsCellularAccess,
            reachabilityFactory: factory)
    }

    /// Clears the shared instance and all networkReachabilityWatchers
    static func clearShared() {
        guard let shared = shared else {
            return
        }
        NotificationCenter.default.removeObserver(shared)
        shared.clearWatchers()
        NetworkReachabilityNotifier.shared = nil
    }

    /// Creates the instance
    private init(host: String,
                 allowsCellularAccess: Bool,
                 reachabilityFactory: NetworkReachabilityProvidingFactory.Type) {
        reachability = reachabilityFactory.make(for: host)
        self.allowsCellularAccess = allowsCellularAccess

        // Add listener for Reachability and start its notifier
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(respondToReachabilityChange),
                                               name: .reachabilityChanged,
                                               object: nil)
        do {
            try reachability?.startNotifier()
        } catch {
        }

        // Add listener for KSReachability's notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(respondToReachabilityChange),
            name: NSNotification.Name(rawValue: kAWSDefaultNetworkReachabilityChangedNotification),
            object: nil)
    }

    /// Returns `true` if `endpointURL` is reachable based on the current network state.
    ///
    /// Note that a `true` return value from this operation does not mean that a network operation is guaranteed to succeed, or
    /// even that the network state is necessarily being accurately evaluated at the time of execution. This value should be
    /// considered advisory only; callers are responsible for correct error handling when actually performing a network
    /// operation.
    var isNetworkReachable: Bool {
        guard let reachability = reachability else {
            return false
        }

        switch reachability.connection {
        case .none:
            return false
        case .wifi:
            return true
        case .cellular:
            return allowsCellularAccess
        }
    }

    /// Adds a new item to the list of watchers to be notified in case of a network reachability change
    ///
    /// - Parameter watcher: The watcher to add
    func add(watcher: NetworkReachabilityWatcher) {
        objc_sync_enter(networkReachabilityWatchers)
        networkReachabilityWatchers.append(watcher)
        objc_sync_exit(networkReachabilityWatchers)
    }

    private func clearWatchers() {
        objc_sync_enter(networkReachabilityWatchers)
        networkReachabilityWatchers = []
        objc_sync_exit(networkReachabilityWatchers)
    }

    // MARK: - Notifications

    /// If a network reachability change occurs after the initial connection, respond by posting a notification to the default
    /// notification center, and by invoking each networkReachabilityWatcher callback.
    @objc private func respondToReachabilityChange() {
        guard isInitialConnection == false else {
            isInitialConnection = false
            return
        }

        guard let reachability = reachability else {
            return
        }

        let isReachable: Bool
        switch reachability.connection {
        case .wifi:
            isReachable = true
        case .cellular:
            isReachable = allowsCellularAccess
        case .none:
            isReachable = false
        }

        for watchers in networkReachabilityWatchers {
            watchers.onNetworkReachabilityChanged(isEndpointReachable: isReachable)
        }

        let info = AppSyncConnectionInfo(isConnectionAvailable: isReachable, isInitialConnection: isInitialConnection)
        NotificationCenter.default.post(name: .appSyncReachabilityChanged, object: info)
    }

}

// MARK: - Reachability

extension Reachability: NetworkReachabilityProvidingFactory {
    static func make(for hostname: String) -> NetworkReachabilityProviding? {
        return Reachability(hostname: hostname)
    }
}

extension Reachability: NetworkReachabilityProviding { }
