// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.4.8",
        archive: "dmx-guest-0.4.8.tar.gz",
        bytes: 62908315,
        sha256: "945df49c1aa5f534288d6660bd34a6d46b847a5e8f5f9bf8eb47c7b752e2919c",
        files: [
            "Image": "fa487e1461eac6012fb5c43281b815e36cfea99d4f4ce4ed30498811f7650bf3",
            "docker.img": "b4a642e5e12fde9779958974aba4b83f68c9e26128c8b6261a7c3f2a8a42e7b4",
            "initramfs.gz": "974488281cca4778d2e79e0f77f1d7d38257f27e5ecfc859611ef5a40969af1b",
            "manifest.json": "3f745b7e2f9aef745d94feb685ea5bf5f87edecc868f0306f4807ff937e74fd6",
        ]
    )
}
