/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import XCTest
@testable import Datadog

class RUMScopeTests: XCTestCase {
    private class CompletedScope: RUMScope {
        let context = RUMContext(rumApplicationID: .mockAny(), sessionID: .nullUUID)
        func process(command: RUMCommand) -> Bool { false }
    }

    private class NonCompletedScope: RUMScope {
        let context = RUMContext(rumApplicationID: .mockAny(), sessionID: .nullUUID)
        func process(command: RUMCommand) -> Bool { true }
    }

    func testWhenPropagatingCommand_itRemovesCompletedScope() {
        // Direct reference
        var scope: RUMScope? = CompletedScope()
        RUMScopeMock().manage(childScope: &scope, byPropagatingCommand: RUMCommandMock())
        XCTAssertNil(scope)

        // Dictionary item reference
        var dictionaryOfScopes: [String: RUMScope] = [
            "a": CompletedScope(),
            "b": NonCompletedScope(),
        ]
        RUMScopeMock().manage(childScope: &dictionaryOfScopes["a"], byPropagatingCommand: RUMCommandMock())
        XCTAssertNil(dictionaryOfScopes["a"])
        XCTAssertNotNil(dictionaryOfScopes["b"])
    }

    func testWhenPropagatingCommand_itKeepsNonCompletedScope() {
        // Direct reference
        var scope: RUMScope? = NonCompletedScope()
        RUMScopeMock().manage(childScope: &scope, byPropagatingCommand: RUMCommandMock())
        XCTAssertNotNil(scope)

        // Dictionary item reference
        var dictionaryOfScopes: [String: RUMScope] = [
            "a": CompletedScope(),
            "b": NonCompletedScope(),
        ]
        RUMScopeMock().manage(childScope: &dictionaryOfScopes["b"], byPropagatingCommand: RUMCommandMock())
        XCTAssertNotNil(dictionaryOfScopes["a"])
        XCTAssertNotNil(dictionaryOfScopes["b"])
    }

    func testWhenPropagatingCommand_itRemovesCompletedScopes() {
        var scopes: [RUMScope] = [
            CompletedScope(),
            NonCompletedScope(),
            CompletedScope(),
            NonCompletedScope()
        ]

        RUMScopeMock().manage(childScopes: &scopes, byPropagatingCommand: RUMCommandMock())

        XCTAssertEqual(scopes.count, 2)
        XCTAssertEqual(scopes.filter { $0 is NonCompletedScope }.count, 2)
    }

    func testMergingRUMAttributes() {
        var attributes: [AttributeKey: AttributeValue] = ["foo": "bar", "fizz": "buzz"]
        let additionalAttribtues: [AttributeKey: AttributeValue] = ["foo": "bar 2", "baz": "qux"]

        attributes.merge(rumCommandAttributes: additionalAttribtues)
        XCTAssertEqual(attributes as? [String: String], ["foo": "bar 2", "fizz": "buzz", "baz": "qux"], "`bar` should be overwritten")

        attributes.merge(rumCommandAttributes: nil)
        XCTAssertEqual(attributes as? [String: String], ["foo": "bar 2", "fizz": "buzz", "baz": "qux"])
    }
}
