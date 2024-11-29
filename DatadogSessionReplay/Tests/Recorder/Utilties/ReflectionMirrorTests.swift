/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import XCTest
import DatadogInternal

@testable import DatadogSessionReplay

class ReflectionMirrorTests: XCTestCase {
    func testClassDisplay() {
        class Mock {}
        let mirror = ReflectionMirror(reflecting: Mock())
        XCTAssertEqual(mirror.displayStyle, .class)
    }

    func testStructDisplay() {
        struct Mock {}
        let mirror = ReflectionMirror(reflecting: Mock())
        XCTAssertEqual(mirror.displayStyle, .struct)
    }

    func testTupleDisplay() {
        let mirror = ReflectionMirror(reflecting: (1, 2))
        XCTAssertEqual(mirror.displayStyle, .tuple)
    }

    func testEnumDisplay() {
        enum Mock {
            case test
        }
        let mirror = ReflectionMirror(reflecting: Mock.test)
        XCTAssertEqual(mirror.displayStyle, .enum(case: "test"))
    }

    func testNilDisplay() {
        struct Mock {}
        let mirror = ReflectionMirror(reflecting: Optional<Mock>.none as Any)
        XCTAssertEqual(mirror.displayStyle, .nil)
    }

    func testNonNilDisplay() {
        struct Mock {}
        let mirror = ReflectionMirror(reflecting: Optional.some(Mock()) as Any)
        XCTAssertEqual(mirror.displayStyle, .struct)
    }
}
