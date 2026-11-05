// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.4.5",
        archive: "dmx-guest-0.4.5.tar.gz",
        bytes: 62904244,
        sha256: "40d4b83691eb8ae2ef3775c9bc7c5ccf693b0f0ff583463dddfdca32c151b274",
        files: [
            "Image": "fa487e1461eac6012fb5c43281b815e36cfea99d4f4ce4ed30498811f7650bf3",
            "docker.img": "b4a642e5e12fde9779958974aba4b83f68c9e26128c8b6261a7c3f2a8a42e7b4",
            "initramfs.gz": "f045b3c6f5cff87d2fb41f057032da081796c456ab2c024a6b35ecd044537243",
            "manifest.json": "0cb87dbc36e1b9afca8cd85ac096d3d22f7a6bc132924cff7672f686579ecf37",
        ]
    )
}
