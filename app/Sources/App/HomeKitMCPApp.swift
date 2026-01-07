import SwiftUI
import HomeKit

// MARK: - Glass Effect Compatibility

extension View {
    /// Applies Liquid Glass on iOS 26+, falls back to translucent material on older versions
    @ViewBuilder
    func compatibleGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, macCatalyst 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
        }
    }

    @ViewBuilder
    func compatibleGlassRounded(cornerRadius: CGFloat = 16) -> some View {
        compatibleGlass(in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func compatibleGlassCapsule() -> some View {
        compatibleGlass(in: Capsule())
    }

    @ViewBuilder
    func compatibleGlassCircle() -> some View {
        compatibleGlass(in: Circle())
    }
}

@main
struct HomeKitMCPApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.homeKitManager)
                .environmentObject(appDelegate.httpServer)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var homeKitManager: HomeKitManager
    @EnvironmentObject var httpServer: SimpleHTTPServer

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.1, green: 0.1, blue: 0.2),
                    Color(red: 0.15, green: 0.1, blue: 0.25),
                    Color(red: 0.1, green: 0.15, blue: 0.2)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                headerView
                    .padding(.horizontal)
                    .padding(.top, 8)

                if homeKitManager.isReady {
                    homeKitDetailsView
                } else {
                    loadingView
                }
            }
        }
        .frame(minWidth: 550, minHeight: 500)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 16) {
            // App icon
            ZStack {
                Circle()
                    .fill(.linearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 48, height: 48)

                Image(systemName: "house.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .compatibleGlassCircle()

            VStack(alignment: .leading, spacing: 4) {
                Text("HomeKit MCP")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                HStack(spacing: 6) {
                    Circle()
                        .fill(homeKitManager.isReady ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(homeKitManager.isReady ? "Ready" : "Loading...")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer()

            // Server status pill
            serverStatusPill
        }
        .padding()
        .compatibleGlassRounded(cornerRadius: 20)
    }

    private var serverStatusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(httpServer.isRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(httpServer.isRunning ? "Server Running" : "Server Stopped")
                    .font(.caption)
                    .fontWeight(.medium)
                if httpServer.isRunning {
                    Text("localhost:\(String(httpServer.port))")
                        .font(.caption2)
                        .opacity(0.7)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .compatibleGlassCapsule()
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.5)
                .tint(.white)

            Text("Loading HomeKit...")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            Text("Grant HomeKit access in System Settings")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))

            Spacer()
        }
        .padding()
    }

    // MARK: - HomeKit Details

    private var homeKitDetailsView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Summary Cards
                summaryCards
                    .padding(.horizontal)

                // Homes
                ForEach(homeKitManager.homes, id: \.uniqueIdentifier) { home in
                    homeCard(home)
                        .padding(.horizontal)
                }

                // Server Info
                serverInfoCard
                    .padding(.horizontal)
                    .padding(.bottom, 16)
            }
            .padding(.top, 16)
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            StatCard(
                icon: "house.fill",
                value: "\(homeKitManager.homes.count)",
                label: "Homes",
                color: .blue
            )

            StatCard(
                icon: "lightbulb.fill",
                value: "\(totalAccessoryCount)",
                label: "Accessories",
                color: .yellow
            )

            StatCard(
                icon: "door.left.hand.open",
                value: "\(totalRoomCount)",
                label: "Rooms",
                color: .orange
            )
        }
    }

    private func homeCard(_ home: HMHome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Home Header
            HStack {
                Image(systemName: home.isPrimary ? "house.fill" : "house")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(home.name)
                            .font(.headline)
                            .foregroundStyle(.white)

                        if home.isPrimary {
                            Text("PRIMARY")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }

                    Text("\(home.accessories.count) accessories · \(home.rooms.count) rooms")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()
            }

            Divider()
                .background(.white.opacity(0.2))

            // Rooms
            ForEach(home.rooms, id: \.uniqueIdentifier) { room in
                roomRow(room, in: home)
            }

            // Scenes
            if !home.actionSets.isEmpty {
                Divider()
                    .background(.white.opacity(0.2))

                HStack {
                    Image(systemName: "theatermasks.fill")
                        .foregroundStyle(.purple)
                    Text("\(home.actionSets.count) Scenes")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .padding()
        .compatibleGlassRounded(cornerRadius: 16)
    }

    private func roomRow(_ room: HMRoom, in home: HMHome) -> some View {
        let accessories = home.accessories.filter { $0.room?.uniqueIdentifier == room.uniqueIdentifier }

        return DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(accessories, id: \.uniqueIdentifier) { accessory in
                    accessoryRow(accessory)
                }
            }
            .padding(.leading, 8)
        } label: {
            HStack {
                Image(systemName: "door.left.hand.open")
                    .foregroundStyle(.orange)
                    .frame(width: 24)

                Text(room.name)
                    .foregroundStyle(.white)

                Spacer()

                Text("\(accessories.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .tint(.white)
    }

    private func accessoryRow(_ accessory: HMAccessory) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(accessory.isReachable ? .green.opacity(0.2) : .gray.opacity(0.2))
                    .frame(width: 36, height: 36)

                Image(systemName: accessoryIcon(for: accessory))
                    .font(.system(size: 14))
                    .foregroundStyle(accessory.isReachable ? .green : .gray)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(accessory.name)
                    .font(.subheadline)
                    .foregroundStyle(.white)

                HStack(spacing: 6) {
                    Text(accessory.category.localizedDescription)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))

                    if !accessory.isReachable {
                        Text("· Unreachable")
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }
            }

            Spacer()

            Text("\(accessory.services.count)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.vertical, 4)
    }

    private var serverInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(.cyan)

                Text("Local Server")
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()

                Circle()
                    .fill(httpServer.isRunning ? .green : .red)
                    .frame(width: 10, height: 10)
            }

            Divider()
                .background(.white.opacity(0.2))

            if httpServer.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    EndpointRow(method: "GET", path: "/health", description: "Full HomeKit state")
                    EndpointRow(method: "GET", path: "/homes", description: "List homes")
                    EndpointRow(method: "GET", path: "/accessories", description: "List accessories")
                }
            } else {
                Text("Server is not running")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding()
        .compatibleGlassRounded(cornerRadius: 16)
    }

    // MARK: - Helpers

    private func accessoryIcon(for accessory: HMAccessory) -> String {
        let category = accessory.category.categoryType
        switch category {
        case HMAccessoryCategoryTypeLightbulb:
            return "lightbulb.fill"
        case HMAccessoryCategoryTypeSwitch, HMAccessoryCategoryTypeOutlet:
            return "powerplug.fill"
        case HMAccessoryCategoryTypeThermostat:
            return "thermometer"
        case HMAccessoryCategoryTypeDoorLock:
            return "lock.fill"
        case HMAccessoryCategoryTypeSensor:
            return "sensor.fill"
        case HMAccessoryCategoryTypeDoor, HMAccessoryCategoryTypeGarageDoorOpener:
            return "door.left.hand.closed"
        case HMAccessoryCategoryTypeFan:
            return "fan.fill"
        case HMAccessoryCategoryTypeWindow, HMAccessoryCategoryTypeWindowCovering:
            return "blinds.horizontal.closed"
        case HMAccessoryCategoryTypeSecuritySystem:
            return "shield.fill"
        case HMAccessoryCategoryTypeIPCamera, HMAccessoryCategoryTypeVideoDoorbell:
            return "camera.fill"
        default:
            return "cube.fill"
        }
    }

    private var totalAccessoryCount: Int {
        homeKitManager.homes.reduce(0) { $0 + $1.accessories.count }
    }

    private var totalRoomCount: Int {
        homeKitManager.homes.reduce(0) { $0 + $1.rooms.count }
    }
}

// MARK: - Supporting Views

struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            Text(value)
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(.white)

            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .compatibleGlassRounded(cornerRadius: 12)
    }
}

struct EndpointRow: View {
    let method: String
    let path: String
    let description: String

    var body: some View {
        HStack(spacing: 8) {
            Text(method)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.cyan)

            Text("—")
                .foregroundStyle(.white.opacity(0.3))

            Text(description)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))

            Spacer()
        }
    }
}
