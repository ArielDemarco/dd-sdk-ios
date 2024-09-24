/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

#if os(iOS)

import XCTest
import TestUtilities
import DatadogInternal

@testable import DatadogSessionReplay

class DDSessionReplayOverrideTests: XCTestCase {
    func testTextAndInputPrivacyLevelsOverrideInterop() {
        XCTAssertEqual(DDTextAndInputPrivacyLevelOverride.maskAll._swift, .maskAll)
        XCTAssertEqual(DDTextAndInputPrivacyLevelOverride.maskAllInputs._swift, .maskAllInputs)
        XCTAssertEqual(DDTextAndInputPrivacyLevelOverride.maskSensitiveInputs._swift, .maskSensitiveInputs)
        XCTAssertNil(DDTextAndInputPrivacyLevelOverride.none._swift)

        XCTAssertEqual(DDTextAndInputPrivacyLevelOverride(.maskAll), .maskAll)
        XCTAssertEqual(DDTextAndInputPrivacyLevelOverride(.maskAllInputs), .maskAllInputs)
        XCTAssertEqual(DDTextAndInputPrivacyLevelOverride(.maskSensitiveInputs), .maskSensitiveInputs)
        XCTAssertEqual(DDTextAndInputPrivacyLevelOverride(nil), .none)
    }

    func testImagePrivacyLevelsOverrideInterop() {
        XCTAssertEqual(DDImagePrivacyLevelOverride.maskAll._swift, .maskAll)
        XCTAssertEqual(DDImagePrivacyLevelOverride.maskNonBundledOnly._swift, .maskNonBundledOnly)
        XCTAssertEqual(DDImagePrivacyLevelOverride.maskNone._swift, .maskNone)
        XCTAssertNil(DDImagePrivacyLevelOverride.none._swift)

        XCTAssertEqual(DDImagePrivacyLevelOverride(.maskAll), .maskAll)
        XCTAssertEqual(DDImagePrivacyLevelOverride(.maskNonBundledOnly), .maskNonBundledOnly)
        XCTAssertEqual(DDImagePrivacyLevelOverride(.maskNone), .maskNone)
        XCTAssertEqual(DDImagePrivacyLevelOverride(nil), .none)
    }

    func testTouchPrivacyLevelsOverrideInterop() {
        XCTAssertEqual(DDTouchPrivacyLevelOverride.show._swift, .show)
        XCTAssertEqual(DDTouchPrivacyLevelOverride.hide._swift, .hide)
        XCTAssertNil(DDTouchPrivacyLevelOverride.none._swift)

        XCTAssertEqual(DDTouchPrivacyLevelOverride(.show), .show)
        XCTAssertEqual(DDTouchPrivacyLevelOverride(.hide), .hide)
        XCTAssertEqual(DDTouchPrivacyLevelOverride(nil), .none)
    }

    func testHiddenPrivacyLevelsOverrideInterop() {
        let override = DDSessionReplayOverride()

        // When setting hiddenPrivacy via Swift
        override._swift.hiddenPrivacy = true
        XCTAssertEqual(override.hiddenPrivacy, NSNumber(value: true))

        override._swift.hiddenPrivacy = false
        XCTAssertEqual(override.hiddenPrivacy, NSNumber(value: false))

        override._swift.hiddenPrivacy = nil
        XCTAssertNil(override.hiddenPrivacy)

        // When setting hiddenPrivacy via Objective-C
        override.hiddenPrivacy = NSNumber(value: true)
        XCTAssertEqual(override._swift.hiddenPrivacy, true)

        override.hiddenPrivacy = NSNumber(value: false)
        XCTAssertEqual(override._swift.hiddenPrivacy, false)

        override.hiddenPrivacy = nil
        XCTAssertNil(override._swift.hiddenPrivacy)
    }

    func testSettingAndRemovingPrivacyOverridesObjc() {
        // Given
        let override = DDSessionReplayOverride()
        let textAndInputPrivacy: DDTextAndInputPrivacyLevelOverride = [.maskAll, .maskAllInputs, .maskSensitiveInputs].randomElement()!
        let imagePrivacy: DDImagePrivacyLevelOverride = [.maskAll, .maskNonBundledOnly, .maskNone].randomElement()!
        let touchPrivacy: DDTouchPrivacyLevelOverride = [.show, .hide].randomElement()!
        let hiddenPrivacy: NSNumber? = [true, false].randomElement().map { NSNumber(value: $0) } ?? nil

        // When
        override.textAndInputPrivacy = textAndInputPrivacy
        override.imagePrivacy = imagePrivacy
        override.touchPrivacy = touchPrivacy
        override.hiddenPrivacy = hiddenPrivacy

        // Then
        XCTAssertEqual(override.textAndInputPrivacy, textAndInputPrivacy)
        XCTAssertEqual(override.imagePrivacy, imagePrivacy)
        XCTAssertEqual(override.touchPrivacy, touchPrivacy)
        XCTAssertEqual(override.hiddenPrivacy, hiddenPrivacy)

        // When
        override.textAndInputPrivacy = .none
        override.imagePrivacy = .none
        override.touchPrivacy = .none
        override.hiddenPrivacy = false

        // Then
        XCTAssertEqual(override.textAndInputPrivacy, .none)
        XCTAssertEqual(override.imagePrivacy, .none)
        XCTAssertEqual(override.touchPrivacy, .none)
        XCTAssertEqual(override.hiddenPrivacy, false)
    }
}
#endif
