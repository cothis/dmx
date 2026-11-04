// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.4.3",
        archive: "dmx-guest-0.4.3.tar.gz",
        bytes: 62900659,
        sha256: "bb18bd94dd31749c9d9c6353c77a8b7192b69a3e2125a05f57157b32f53f6d92",
        files: [
            "Image": "fa487e1461eac6012fb5c43281b815e36cfea99d4f4ce4ed30498811f7650bf3",
            "docker.img": "520d69c21674712ad000870faa7a7bcd11ffc973e7c856b09bf77ddf23ac13b5",
            "initramfs.gz": "f045b3c6f5cff87d2fb41f057032da081796c456ab2c024a6b35ecd044537243",
            "manifest.json": "cd6be902ccad16d4ea2e85a6311a5716a23f985ab52ea8631af1d10f8f37bbd7",
        ]
    )
}
