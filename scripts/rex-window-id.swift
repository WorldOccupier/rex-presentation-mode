import CoreGraphics

let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    fputs("could not list windows\n", stderr)
    exit(1)
}

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    let isRex = owner == "Rex" || owner.hasPrefix("Rex ")
    if isRex && layer == 0 {
        let number = window[kCGWindowNumber as String] as? Int ?? 0
        if number > 0 {
            print(number)
            exit(0)
        }
    }
}

fputs("no Rex window\n", stderr)
exit(1)
