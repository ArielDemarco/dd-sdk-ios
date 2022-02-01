/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

internal class RUMViewScope: RUMScope, RUMContextProvider {
    struct Constants {
        static let frozenFrameThresholdInNs = (0.07).toInt64Nanoseconds // 70ms
        static let slowRenderingThresholdFPS = 55.0
    }

    // MARK: - Child Scopes

    /// Active Resource scopes, keyed by .resourceKey.
    private(set) var resourceScopes: [String: RUMResourceScope] = [:]
    /// Active User Action scope. There can be only one active user action at a time.
    private(set) var userActionScope: RUMUserActionScope?

    // MARK: - Initialization

    private unowned let parent: RUMContextProvider
    private let dependencies: RUMScopeDependencies
    /// If this is the very first view created in the current app process.
    private let isInitialView: Bool

    /// The value holding stable identity of this RUM View.
    let identity: RUMViewIdentity
    /// View attributes.
    private(set) var attributes: [AttributeKey: AttributeValue]
    /// View custom timings, keyed by name. The value of timing is given in nanoseconds.
    private(set) var customTimings: [String: Int64] = [:]

    /// This View's UUID.
    let viewUUID: RUMUUID
    /// The path of this View, used as the `VIEW URL` in RUM Explorer.
    let viewPath: String
    /// The name of this View, used as the `VIEW NAME` in RUM Explorer.
    let viewName: String
    /// The start time of this View.
    let viewStartTime: Date
    /// Date correction to server time.
    private let dateCorrection: DateCorrection
    /// Tells if this View is the active one.
    /// `true` for every new started View.
    /// `false` if the View was stopped or any other View was started.
    private(set) var isActiveView = true
    /// Tells if this scope has received the "start" command.
    /// If `didReceiveStartCommand == true` and another "start" command is received for this View this scope is marked as inactive.
    private var didReceiveStartCommand = false

    /// Number of Actions happened on this View.
    private var actionsCount: UInt = 0
    /// Number of Resources tracked by this View.
    private var resourcesCount: UInt = 0
    /// Number of Errors tracked by this View.
    private var errorsCount: UInt = 0
    /// Number of Long Tasks tracked by this View.
    private var longTasksCount: Int64 = 0
    /// Number of Frozen Frames tracked by this View.
    private var frozenFramesCount: Int64 = 0

    /// Current version of this View to use for RUM `documentVersion`.
    private var version: UInt = 0

    /// Whether or not the current call to `process(command:)` should trigger a `sendViewEvent()` with an update.
    /// It can be toggled from inside `RUMResourceScope`/`RUMUserActionScope` callbacks, as they are called from processing `RUMCommand`s inside `process()`.
    private var needsViewUpdate = false

    private let vitalInfoSampler: VitalInfoSampler

    init(
        isInitialView: Bool,
        parent: RUMContextProvider,
        dependencies: RUMScopeDependencies,
        identity: RUMViewIdentifiable,
        path: String,
        name: String,
        attributes: [AttributeKey: AttributeValue],
        customTimings: [String: Int64],
        startTime: Date
    ) {
        self.parent = parent
        self.dependencies = dependencies
        self.isInitialView = isInitialView
        self.identity = identity.asRUMViewIdentity()
        self.attributes = attributes
        self.customTimings = customTimings
        self.viewUUID = dependencies.rumUUIDGenerator.generateUnique()
        self.viewPath = path
        self.viewName = name
        self.viewStartTime = startTime
        self.dateCorrection = dependencies.dateCorrector.currentCorrection

        self.vitalInfoSampler = VitalInfoSampler(
            cpuReader: dependencies.vitalCPUReader,
            memoryReader: dependencies.vitalMemoryReader,
            refreshRateReader: dependencies.vitalRefreshRateReader
        )
    }

    // MARK: - RUMContextProvider

    var context: RUMContext {
        var context = parent.context
        context.activeViewID = viewUUID
        context.activeViewPath = viewPath
        context.activeUserActionID = userActionScope?.actionUUID
        context.activeViewName = viewName
        return context
    }

    // MARK: - RUMScope

    func process(command: RUMCommand) -> Bool {
        // Tells if the View did change and an update event should be send.
        needsViewUpdate = false

        // Propagate to User Action scope
        userActionScope = manage(childScope: userActionScope, byPropagatingCommand: command)

        // Send "application start" action if this is the very first view tracked in the app
        let hasSentNoViewUpdatesYet = version == 0
        if isInitialView && hasSentNoViewUpdatesYet {
            actionsCount += 1
            if !sendApplicationStartAction() {
                actionsCount -= 1
            } else {
                needsViewUpdate = true
            }
        }

        // Apply side effects
        switch command {
        // View commands
        case let command as RUMStartViewCommand where identity.equals(command.identity):
            if didReceiveStartCommand {
                // This is the case of duplicated "start" command. We know that the Session scope has created another instance of
                // the `RUMViewScope` for tracking this View, so we mark this one as inactive.
                isActiveView = false
            }
            didReceiveStartCommand = true
            needsViewUpdate = true
        case let command as RUMStartViewCommand where !identity.equals(command.identity):
            isActiveView = false
            needsViewUpdate = true // sanity update (in case if the user forgets to end this View)
        case let command as RUMStopViewCommand where identity.equals(command.identity):
            isActiveView = false
            needsViewUpdate = true
        case let command as RUMAddViewTimingCommand where isActiveView:
            customTimings[command.timingName] = command.time.timeIntervalSince(viewStartTime).toInt64Nanoseconds
            needsViewUpdate = true

        // Resource commands
        case let command as RUMStartResourceCommand where isActiveView:
            startResource(on: command)

        // User Action commands
        case let command as RUMStartUserActionCommand where isActiveView:
            if userActionScope == nil {
                startContinuousUserAction(on: command)
            } else {
                reportActionDropped(type: command.actionType, name: command.name)
            }
        case let command as RUMAddUserActionCommand where isActiveView:
            if command.actionType == .custom {
                // send it instantly without waiting for child events (e.g. resource associated to this action)
                sendDiscreteCustomUserAction(on: command)
            } else if userActionScope == nil {
                addDiscreteUserAction(on: command)
            } else {
                reportActionDropped(type: command.actionType, name: command.name)
            }

        // Error command
        case let command as RUMAddCurrentViewErrorCommand where isActiveView:
            errorsCount += 1
            if sendErrorEvent(on: command) {
                needsViewUpdate = true
            } else {
                errorsCount -= 1
            }

        case let command as RUMAddLongTaskCommand where isActiveView:
            if sendLongTaskEvent(on: command) {
                longTasksCount += 1
                if command.duration.toInt64Nanoseconds > Constants.frozenFrameThresholdInNs {
                    frozenFramesCount += 1
                }

                needsViewUpdate = true
            }

        default:
            break
        }

        // Propagate to Resource scopes
        if let resourceCommand = command as? RUMResourceCommand {
            resourceScopes[resourceCommand.resourceKey] = manage(
                childScope: resourceScopes[resourceCommand.resourceKey],
                byPropagatingCommand: resourceCommand
            )
        }

        // Consider scope state and completion
        if needsViewUpdate {
            sendViewUpdateEvent(on: command)
        }

        let hasNoPendingResources = resourceScopes.isEmpty
        let shouldComplete = !isActiveView && hasNoPendingResources

        return !shouldComplete
    }

    // MARK: - RUMCommands Processing

    private func startResource(on command: RUMStartResourceCommand) {
        resourceScopes[command.resourceKey] = RUMResourceScope(
            context: context,
            dependencies: dependencies,
            resourceKey: command.resourceKey,
            attributes: command.attributes,
            startTime: command.time,
            dateCorrection: dateCorrection,
            url: command.url,
            httpMethod: command.httpMethod,
            isFirstPartyResource: command.isFirstPartyRequest,
            resourceKindBasedOnRequest: command.kind,
            spanContext: command.spanContext,
            onResourceEventSent: { [weak self] in
                self?.resourcesCount += 1
                self?.needsViewUpdate = true
            },
            onErrorEventSent: { [weak self] in
                self?.errorsCount += 1
                self?.needsViewUpdate = true
            }
        )
    }

    private func startContinuousUserAction(on command: RUMStartUserActionCommand) {
        userActionScope = RUMUserActionScope(
            parent: self,
            dependencies: dependencies,
            name: command.name,
            actionType: command.actionType,
            attributes: command.attributes,
            startTime: command.time,
            dateCorrection: dateCorrection,
            isContinuous: true,
            onActionEventSent: { [weak self] in
                self?.actionsCount += 1
                self?.needsViewUpdate = true
            }
        )
    }

    private func createDiscreteUserActionScope(on command: RUMAddUserActionCommand) -> RUMUserActionScope {
        return RUMUserActionScope(
            parent: self,
            dependencies: dependencies,
            name: command.name,
            actionType: command.actionType,
            attributes: command.attributes,
            startTime: command.time,
            dateCorrection: dateCorrection,
            isContinuous: false,
            onActionEventSent: { [weak self] in
                self?.actionsCount += 1
                self?.needsViewUpdate = true
            }
        )
    }

    private func addDiscreteUserAction(on command: RUMAddUserActionCommand) {
        userActionScope = createDiscreteUserActionScope(on: command)
    }

    private func sendDiscreteCustomUserAction(on command: RUMAddUserActionCommand) {
        let customActionScope = createDiscreteUserActionScope(on: command)
        _ = customActionScope.process(
            command: RUMStopUserActionCommand(
                                    time: command.time,
                                    attributes: [:],
                                    actionType: .custom,
                                    name: nil
            )
        )
    }

    private func reportActionDropped(type: RUMUserActionType, name: String) {
        userLogger.warn(
            """
            RUM Action '\(type)' on '\(name)' was dropped, because another action is still active for the same view.
            """
        )
    }

    // MARK: - Sending RUM Events

    private func sendApplicationStartAction() -> Bool {
        let eventData = RUMActionEvent(
            dd: .init(
                browserSdkVersion: nil,
                session: .init(plan: .plan1)
            ),
            action: .init(
                crash: nil,
                error: nil,
                id: dependencies.rumUUIDGenerator.generateUnique().toRUMDataFormat,
                loadingTime: dependencies.launchTimeProvider.launchTime.toInt64Nanoseconds,
                longTask: nil,
                resource: nil,
                target: nil,
                type: .applicationStart
            ),
            application: .init(id: context.rumApplicationID),
            ciTest: nil,
            connectivity: dependencies.connectivityInfoProvider.current,
            context: .init(contextInfo: attributes),
            date: dateCorrection.applying(to: viewStartTime).timeIntervalSince1970.toInt64Milliseconds,
            service: dependencies.serviceName,
            session: .init(hasReplay: nil, id: context.sessionID.toRUMDataFormat, type: .user),
            source: .ios,
            synthetics: nil,
            usr: dependencies.userInfoProvider.current,
            view: .init(
                id: viewUUID.toRUMDataFormat,
                inForeground: nil,
                name: viewName,
                referrer: nil,
                url: viewPath
            )
        )

#if DD_SDK_ENABLE_INTERNAL_MONITORING
        if #available(iOS 15, *) {
            // Starting MetricKit monitor from here, to ensure that our launch time was already reported
            // in `.applicationStart` action and we could compare both measurements.
            MetricMonitor.shared.monitorMetricKit(launchTime: dependencies.launchTimeProvider.launchTime)
        }
#endif
        if let event = dependencies.eventBuilder.build(from: eventData) {
            dependencies.eventOutput.write(event: event)
            return true
        }
        return false
    }

    private func sendViewUpdateEvent(on command: RUMCommand) {
        version += 1
        attributes.merge(rumCommandAttributes: command.attributes)

        // RUMM-1779 Keep view active as long as we have ongoing resources
        let isActive = isActiveView || !resourceScopes.isEmpty

        let timeSpent = command.time.timeIntervalSince(viewStartTime)
        let cpuInfo = vitalInfoSampler.cpu
        let memoryInfo = vitalInfoSampler.memory
        let refreshRateInfo = vitalInfoSampler.refreshRate
        let isSlowRendered = refreshRateInfo.meanValue.flatMap { $0 < Constants.slowRenderingThresholdFPS }

        let eventData = RUMViewEvent(
            dd: .init(
                browserSdkVersion: nil,
                documentVersion: version.toInt64,
                session: .init(plan: .plan1)
            ),
            application: .init(id: context.rumApplicationID),
            ciTest: nil,
            connectivity: dependencies.connectivityInfoProvider.current,
            context: .init(contextInfo: attributes),
            date: dateCorrection.applying(to: viewStartTime).timeIntervalSince1970.toInt64Milliseconds,
            service: dependencies.serviceName,
            session: .init(hasReplay: nil, id: context.sessionID.toRUMDataFormat, type: .user),
            source: .ios,
            synthetics: nil,
            usr: dependencies.userInfoProvider.current,
            view: .init(
                action: .init(count: actionsCount.toInt64),
                cpuTicksCount: cpuInfo.greatestDiff,
                cpuTicksPerSecond: cpuInfo.greatestDiff?.divideIfNotZero(by: Double(timeSpent)),
                crash: nil,
                cumulativeLayoutShift: nil,
                customTimings: customTimings.reduce(into: [:]) { acc, element in
                    acc[sanitizeCustomTimingName(customTiming: element.key)] = element.value
                },
                domComplete: nil,
                domContentLoaded: nil,
                domInteractive: nil,
                error: .init(count: errorsCount.toInt64),
                firstContentfulPaint: nil,
                firstInputDelay: nil,
                firstInputTime: nil,
                frozenFrame: .init(count: frozenFramesCount),
                id: viewUUID.toRUMDataFormat,
                inForegroundPeriods: nil,
                isActive: isActive,
                isSlowRendered: isSlowRendered,
                largestContentfulPaint: nil,
                loadEvent: nil,
                loadingTime: nil,
                loadingType: nil,
                longTask: .init(count: longTasksCount),
                memoryAverage: memoryInfo.meanValue,
                memoryMax: memoryInfo.maxValue,
                name: viewName,
                referrer: nil,
                refreshRateAverage: refreshRateInfo.meanValue,
                refreshRateMin: refreshRateInfo.minValue,
                resource: .init(count: resourcesCount.toInt64),
                timeSpent: timeSpent.toInt64Nanoseconds,
                url: viewPath
            )
        )

        if let event = dependencies.eventBuilder.build(from: eventData) {
            dependencies.eventOutput.write(event: event)

            // Update `CrashContext` with recent RUM view:
            dependencies.crashContextIntegration?.update(lastRUMViewEvent: event)
        } else {
            version -= 1
        }
    }

    private func sendErrorEvent(on command: RUMAddCurrentViewErrorCommand) -> Bool {
        attributes.merge(rumCommandAttributes: command.attributes)

        let eventData = RUMErrorEvent(
            dd: .init(
                browserSdkVersion: nil,
                session: .init(plan: .plan1)
            ),
            action: context.activeUserActionID.flatMap { rumUUID in
                .init(id: rumUUID.toRUMDataFormat)
            },
            application: .init(id: context.rumApplicationID),
            ciTest: nil,
            connectivity: dependencies.connectivityInfoProvider.current,
            context: .init(contextInfo: attributes),
            date: dateCorrection.applying(to: command.time).timeIntervalSince1970.toInt64Milliseconds,
            error: .init(
                handling: nil,
                handlingStack: nil,
                id: nil,
                isCrash: command.isCrash,
                message: command.message,
                resource: nil,
                source: command.source.toRUMDataFormat,
                sourceType: command.errorSourceType,
                stack: command.stack,
                type: command.type
            ),
            service: dependencies.serviceName,
            session: .init(hasReplay: nil, id: context.sessionID.toRUMDataFormat, type: .user),
            source: .ios,
            synthetics: nil,
            usr: dependencies.userInfoProvider.current,
            view: .init(
                id: context.activeViewID.orNull.toRUMDataFormat,
                inForeground: nil,
                name: context.activeViewName,
                referrer: nil,
                url: context.activeViewPath ?? ""
            )
        )

        if let event = dependencies.eventBuilder.build(from: eventData) {
            dependencies.eventOutput.write(event: event)
            return true
        }
        return false
    }

    private func sendLongTaskEvent(on command: RUMAddLongTaskCommand) -> Bool {
        attributes.merge(rumCommandAttributes: command.attributes)

        let taskDurationInNs = command.duration.toInt64Nanoseconds
        let isFrozenFrame = taskDurationInNs > Constants.frozenFrameThresholdInNs

        let eventData = RUMLongTaskEvent(
            dd: .init(
              browserSdkVersion: nil,
              session: .init(plan: .plan1)
            ),
            action: context.activeUserActionID.flatMap { RUMLongTaskEvent.Action(id: $0.toRUMDataFormat) },
            application: .init(id: context.rumApplicationID),
            ciTest: nil,
            connectivity: dependencies.connectivityInfoProvider.current,
            context: .init(contextInfo: attributes),
            date: dateCorrection.applying(to: command.time - command.duration).timeIntervalSince1970.toInt64Milliseconds,
            longTask: .init(duration: taskDurationInNs, id: nil, isFrozenFrame: isFrozenFrame),
            service: dependencies.serviceName,
            session: .init(hasReplay: nil, id: context.sessionID.toRUMDataFormat, type: .user),
            source: .ios,
            synthetics: nil,
            usr: dependencies.userInfoProvider.current,
            view: .init(
                id: context.activeViewID.orNull.toRUMDataFormat,
                name: context.activeViewName,
                referrer: nil,
                url: context.activeViewPath ?? ""
            )
        )

        if let event = dependencies.eventBuilder.build(from: eventData) {
            dependencies.eventOutput.write(event: event)
            return true
        }
        return false
    }

    private func sanitizeCustomTimingName(customTiming: String) -> String {
        let sanitized = customTiming.replacingOccurrences(of: "[^a-zA-Z0-9_.@$-]", with: "_", options: .regularExpression)

        if customTiming != sanitized {
            userLogger.warn(
                """
                Custom timing '\(customTiming)' was modified to '\(sanitized)' to match Datadog constraints.
                """
            )
        }

        return sanitized
    }
}

///
/// THE FOLLOWING IMPLEMENTATION SHALL BE REMOVED ONCE
/// METRICKIT HAS BEEN EVALUATED.
///
#if DD_SDK_ENABLE_INTERNAL_MONITORING
import MetricKit

/// The MetricMonitor only exists for internal testing, it will log the MetricKit payloads at reception to
/// Internal Monitoring Feature.
private class MetricMonitor: NSObject, MXMetricManagerSubscriber {
    static var shared = MetricMonitor()

    /// The launch time reported by the sdk.
    private var launchTime: TimeInterval = 0

    /// The time when this monitor starts.
    private var timestamp: Date = .distantPast

    /// Request MetricKit payload by subscribing to MXMetricManager.
    ///
    /// - Parameter launchTime: The launch time reported by the sdk.
    @available(iOS 13.0, *)
    func monitorMetricKit(launchTime: TimeInterval) {
        self.launchTime = launchTime
        self.timestamp = Date()
        MXMetricManager.shared.add(self)

        InternalMonitoringFeature.instance?.monitor.sdkLogger.info(
            "Did request MetricKit metrics and diagnostics",
            attributes: [
                "application_launch_time": launchTime,
                "active_pre_warm": ProcessInfo.processInfo.environment["ActivePrewarm"] ?? "(null)",
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString
            ]
        )
    }

    @available(iOS 13.0, *)
    func didReceive(_ payloads: [MXMetricPayload]) {
        let metrics = payloads
            .map { $0.dictionaryRepresentation() }
            .map(MetricEncodable.init)

        InternalMonitoringFeature.instance?.monitor.sdkLogger.info(
            "Did receive MetricKit metrics",
            attributes: [
                "application_launch_time": launchTime,
                "active_pre_warm": ProcessInfo.processInfo.environment["ActivePrewarm"] ?? "(null)",
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "delay": Date().timeIntervalSince(timestamp),
                "payloads": MetricEncodable(metrics)
            ]
        )
    }

    @available(iOS 14.0, *)
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let diagnostics = payloads
            .map { $0.dictionaryRepresentation() }
            .map(MetricEncodable.init)

        InternalMonitoringFeature.instance?.monitor.sdkLogger.info(
            "Did receive MetricKit diagnostics",
            attributes: [
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "delay": Date().timeIntervalSince(timestamp),
                "payloads": MetricEncodable(diagnostics)
            ]
        )
    }
}

/**
 https://github.com/Flight-School/AnyCodable

 Copyright 2018 Read Evaluate Press, LLC

 Permission is hereby granted, free of charge, to any person obtaining a
 copy of this software and associated documentation files (the "Software"),
 to deal in the Software without restriction, including without limitation
 the rights to use, copy, modify, merge, publish, distribute, sublicense,
 and/or sell copies of the Software, and to permit persons to whom the
 Software is furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 DEALINGS IN THE SOFTWARE
 */

/**
 A type-erased `Encodable` value.
 The `AnyEncodable` type forwards encoding responsibilities
 to an underlying value, hiding its specific underlying type.
 You can encode mixed-type values in dictionaries
 and other collections that require `Encodable` conformance
 by declaring their contained type to be `AnyEncodable`:
     let dictionary: [String: AnyEncodable] = [
         "boolean": true,
         "integer": 42,
         "double": 3.141592653589793,
         "string": "string",
         "array": [1, 2, 3],
         "nested": [
             "a": "alpha",
             "b": "bravo",
             "c": "charlie"
         ],
         "null": nil
     ]
     let encoder = JSONEncoder()
     let json = try! encoder.encode(dictionary)
 */
private struct MetricEncodable: Encodable {
    let value: Any

    init<T>(_ value: T?) {
        self.value = value ?? ()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        #if canImport(Foundation)
        case let number as NSNumber:
            try encode(nsnumber: number, into: &container)
        case is NSNull:
            try container.encodeNil()
        #endif
        case is Void:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let int8 as Int8:
            try container.encode(int8)
        case let int16 as Int16:
            try container.encode(int16)
        case let int32 as Int32:
            try container.encode(int32)
        case let int64 as Int64:
            try container.encode(int64)
        case let uint as UInt:
            try container.encode(uint)
        case let uint8 as UInt8:
            try container.encode(uint8)
        case let uint16 as UInt16:
            try container.encode(uint16)
        case let uint32 as UInt32:
            try container.encode(uint32)
        case let uint64 as UInt64:
            try container.encode(uint64)
        case let float as Float:
            try container.encode(float)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        #if canImport(Foundation)
        case let date as Date:
            try container.encode(date)
        case let url as URL:
            try container.encode(url)
        #endif
        case let array as [Any?]:
            // DD Logs app fails to render arrays of JSON.
            // Here we map the array to a dictionary with indexes as keys.
            var dictionary: [String: MetricEncodable] = [:]
            array.enumerated().forEach { dictionary["\($0.offset)"] = MetricEncodable($0.element) }
            try container.encode(dictionary)
        case let dictionary as [String: Any?]:
            try container.encode(dictionary.mapValues { MetricEncodable($0) })
        case let encodable as Encodable:
            try encodable.encode(to: encoder)
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "AnyEncodable value cannot be encoded")
            throw EncodingError.invalidValue(value, context)
        }
    }

    #if canImport(Foundation)
    private func encode(nsnumber: NSNumber, into container: inout SingleValueEncodingContainer) throws {
        switch Character(Unicode.Scalar(UInt8(nsnumber.objCType.pointee))) {
        case "c", "C":
            try container.encode(nsnumber.boolValue)
        case "s":
            try container.encode(nsnumber.int8Value)
        case "i":
            try container.encode(nsnumber.int16Value)
        case "l":
            try container.encode(nsnumber.int32Value)
        case "q":
            try container.encode(nsnumber.int64Value)
        case "S":
            try container.encode(nsnumber.uint8Value)
        case "I":
            try container.encode(nsnumber.uint16Value)
        case "L":
            try container.encode(nsnumber.uint32Value)
        case "Q":
            try container.encode(nsnumber.uint64Value)
        case "f":
            try container.encode(nsnumber.floatValue)
        case "d":
            try container.encode(nsnumber.doubleValue)
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "NSNumber cannot be encoded because its type is not handled")
            throw EncodingError.invalidValue(nsnumber, context)
        }
    }
    #endif
}

#endif
