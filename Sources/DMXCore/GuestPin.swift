// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.4.2",
        archive: "dmx-guest-0.4.2.tar.gz",
        bytes: 62896188,
        sha256: "4bd9355c8eac8f40f8e14395b00e518bbe0f08116aea008986634c23aaccb56c",
        files: [
            "Image": "fa487e1461eac6012fb5c43281b815e36cfea99d4f4ce4ed30498811f7650bf3",
            "docker.img": "bf216b3410931e0c20abf6cc528e50b2888d8233d53fcbb0d197b6305196205c",
            "initramfs.gz": "f045b3c6f5cff87d2fb41f057032da081796c456ab2c024a6b35ecd044537243",
            "manifest.json": "edddadf84c98530dcffcf05be99eb7753ad3d93954c7e924da1dba2ffbbbe338",
        ]
    )
}
