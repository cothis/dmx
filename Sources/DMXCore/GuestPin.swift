// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.4.1",
        archive: "dmx-guest-0.4.1.tar.gz",
        bytes: 62896188,
        sha256: "43b167dc3f66f153b6712bda0a4b3047f57ab84f8d8f771482356ecb8fa34ecb",
        files: [
            "Image": "fa487e1461eac6012fb5c43281b815e36cfea99d4f4ce4ed30498811f7650bf3",
            "docker.img": "bf216b3410931e0c20abf6cc528e50b2888d8233d53fcbb0d197b6305196205c",
            "initramfs.gz": "f045b3c6f5cff87d2fb41f057032da081796c456ab2c024a6b35ecd044537243",
            "manifest.json": "edddadf84c98530dcffcf05be99eb7753ad3d93954c7e924da1dba2ffbbbe338",
        ]
    )
}
