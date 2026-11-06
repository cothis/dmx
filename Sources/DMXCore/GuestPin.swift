// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.4.7",
        archive: "dmx-guest-0.4.7.tar.gz",
        bytes: 62905747,
        sha256: "f0e212a8384853121515b922eae8b2e80a711503786b6c2c2f64211926d1de72",
        files: [
            "Image": "fa487e1461eac6012fb5c43281b815e36cfea99d4f4ce4ed30498811f7650bf3",
            "docker.img": "b4a642e5e12fde9779958974aba4b83f68c9e26128c8b6261a7c3f2a8a42e7b4",
            "initramfs.gz": "4fa5e89e5c082636492ed2f8285f60511d90db5ed74381e177e1f959f75bc1ea",
            "manifest.json": "a7c397bda41a6350979e6f5ece897bfaafd5fe617b3e44060a7cf4e3986439fc",
        ]
    )
}
