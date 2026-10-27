// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.3.10",
        archive: "dmx-guest-0.3.10.tar.gz",
        bytes: 62890710,
        sha256: "bd5419ff02e7e0f3111c6d084b5c681c890fa7226ddb64da61c75b34bc774fc5",
        files: [
            "Image": "fa487e1461eac6012fb5c43281b815e36cfea99d4f4ce4ed30498811f7650bf3",
            "docker.img": "bf216b3410931e0c20abf6cc528e50b2888d8233d53fcbb0d197b6305196205c",
            "initramfs.gz": "7211f3cf803c7140ce26b2fcb70d524197874d3c5e945f1a7ff177931e5c8b5c",
            "manifest.json": "0173ec4bd836e7195dae1a0db75262971bda1663521a6fba5c9f070b35a03310",
        ]
    )
}
