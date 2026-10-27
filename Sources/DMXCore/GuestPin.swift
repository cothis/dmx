// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.3.5",
        archive: "dmx-guest-0.3.5.tar.gz",
        bytes: 62890366,
        sha256: "ba025b8580a10817fccd8f95594c74511a8374ec976e008d5ee449c7f13da3b8",
        files: [
            "Image": "fa487e1461eac6012fb5c43281b815e36cfea99d4f4ce4ed30498811f7650bf3",
            "docker.img": "bf216b3410931e0c20abf6cc528e50b2888d8233d53fcbb0d197b6305196205c",
            "initramfs.gz": "c476c97f457808ecfd0719748e50b4996b3c83d25c43b48ee3cb3419607783c8",
            "manifest.json": "545e8f7b25867a3c9d26b9e286dfa8cca354a45729581c6cda2197b8a0fcef2b",
        ]
    )
}
