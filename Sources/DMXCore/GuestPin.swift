// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.2.0",
        archive: "dmx-guest-0.2.0.tar.gz",
        bytes: 61702100,
        sha256: "e4aec7a4ebfcf5f6bc346c513234061982e934fff674c3952e87c9003184608a",
        files: [
            "Image": "ae0aeacf5fd282302293c8b8e7132e218f4dd29ee6eab8c882f92b25d85189ba",
            "docker.img": "0160beafe4638858a9ecfe7aa09711c4c9cc24de6898f42da71c6c3cd78bb6a9",
            "initramfs.gz": "820eaa1625b29d622bdee6660d07b375dde0a865c31df071bf3b23f0c2602177",
            "manifest.json": "843fc7b44f05cb5362053fc5fd9d37d538fcde1552569d3b188bdef521d8a75f",
        ]
    )
}
