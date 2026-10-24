// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release. nil until the first release is cut:
// builds from source then use the guest `make guest` builds.
extension GuestRelease {
    public static let pinned: GuestRelease? = nil
}
