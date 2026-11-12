import Darwin
import Testing

/// Keep Hypervisor entitlement on the executable that loads the Swift Testing bundle.
@main struct LifecycleRunner {
    static func main() async {
        guard let path = getenv("DMX_TEST_BUNDLE"), dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil else {
            if let error = dlerror() { fputs(error, stderr) }
            exit(2)
        }
        let code: CInt = await Testing.__swiftPMEntryPoint()
        exit(code)
    }
}
