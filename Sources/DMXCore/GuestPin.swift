// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.3.0",
        archive: "dmx-guest-0.3.0.tar.gz",
        bytes: 62892710,
        sha256: "324374dabf85da62ae6aba0b629312aef5b7640c8096e32bfcfb852ca92d7468",
        files: [
            "Image": "fa487e1461eac6012fb5c43281b815e36cfea99d4f4ce4ed30498811f7650bf3",
            "docker.img": "d6c999ce4a51a93caf85db323bf080b6ba628b40272e4cfa7ba6717c5883204c",
            "initramfs.gz": "c476c97f457808ecfd0719748e50b4996b3c83d25c43b48ee3cb3419607783c8",
            "manifest.json": "a52f92662ce48665eae76354ee3060dd360afb16e8926ed1719e1160892a31e3",
        ]
    )
}
