// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.2.1",
        archive: "dmx-guest-0.2.1.tar.gz",
        bytes: 61833712,
        sha256: "8ad661d3af6be1ce5e6b899f6006c02e3bc2f10577cbb95651b8402786e1a224",
        files: [
            "Image": "ae0aeacf5fd282302293c8b8e7132e218f4dd29ee6eab8c882f92b25d85189ba",
            "docker.img": "8ef9875d26fd680d2e367011fcad241faa8c5b01b7c3b8867b75bf805b70428b",
            "initramfs.gz": "a2f320e0f541096857a59129ee06930a4bf73ec8505b07676e582703cd78cd7e",
            "manifest.json": "4628ff6e0531fa09c4ab9da2b0c80ea34b41dc0cc1d0ed78934b3f31b9a56649",
        ]
    )
}
