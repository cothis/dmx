// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.3.4",
        archive: "dmx-guest-0.3.4.tar.gz",
        bytes: 62893852,
        sha256: "05981f5988600d158b7f287e6003050d2d02aba174acd3948d9fe9d8b335f6d9",
        files: [
            "Image": "fa487e1461eac6012fb5c43281b815e36cfea99d4f4ce4ed30498811f7650bf3",
            "docker.img": "102344858b0d5cbe80183fb5071b4cefd77e788ba05b52b5105bea75ea62e0a0",
            "initramfs.gz": "c476c97f457808ecfd0719748e50b4996b3c83d25c43b48ee3cb3419607783c8",
            "manifest.json": "42c3572c68503c7c4b15cb258618e027b0c6789be007dbe847c3c042922c29fb",
        ]
    )
}
