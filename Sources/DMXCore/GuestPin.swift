// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.3.3",
        archive: "dmx-guest-0.3.3.tar.gz",
        bytes: 62891200,
        sha256: "441679a2f70dd5cb374e1ef560c32d027ae31b1d8184e268cc683b3353c1d423",
        files: [
            "Image": "fa487e1461eac6012fb5c43281b815e36cfea99d4f4ce4ed30498811f7650bf3",
            "docker.img": "5c4e1ba3f5dcca0b7666652455c80d1598d51703a6656fe03a02a9c58de08d57",
            "initramfs.gz": "c476c97f457808ecfd0719748e50b4996b3c83d25c43b48ee3cb3419607783c8",
            "manifest.json": "87200ce8e7dc0e027f66930540faf2045a1aa0a43d91c4749f45ac22dd674ea6",
        ]
    )
}
