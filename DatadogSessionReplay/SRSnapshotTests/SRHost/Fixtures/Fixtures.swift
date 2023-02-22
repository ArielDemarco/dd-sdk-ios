/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import UIKit

internal enum Fixture: CaseIterable {
    case basicShapes
    case basicTexts
    case sliders
    case segments

    var menuItemTitle: String {
        switch self {
        case .basicShapes:
            return "Basic Shapes"
        case .basicTexts:
            return "Basic Texts"
        case .sliders:
            return "Sliders"
        case .segments:
            return "Segments"
        }
    }

    func instantiateViewController() -> UIViewController {
        switch self {
        case .basicShapes:
            return UIStoryboard.basic.instantiateViewController(withIdentifier: "Shapes")
        case .basicTexts:
            return UIStoryboard.basic.instantiateViewController(withIdentifier: "Texts")
        case .sliders:
            return UIStoryboard.inputElements.instantiateViewController(withIdentifier: "Sliders")
        case .segments:
            return UIStoryboard.inputElements.instantiateViewController(withIdentifier: "Segments")

        }
    }
}

internal extension UIStoryboard {
    static var basic: UIStoryboard { UIStoryboard(name: "Basic", bundle: nil) }
    static var inputElements: UIStoryboard { UIStoryboard(name: "InputElements", bundle: nil) }
}