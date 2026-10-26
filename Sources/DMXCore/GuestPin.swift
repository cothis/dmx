// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.2.2",
        archive: "dmx-guest-0.2.2.tar.gz",
        bytes: 61834130,
        sha256: "4f9a96f7e458fe24e7447cc19e6307e7a0090bbc941e160b42f632279c913775",
        files: [
            "Image": "ae0aeacf5fd282302293c8b8e7132e218f4dd29ee6eab8c882f92b25d85189ba",
            "docker.img": "8ef9875d26fd680d2e367011fcad241faa8c5b01b7c3b8867b75bf805b70428b",
            "initramfs.gz": "c6606a4d6dbd5c5f2f7d85596562dce9603231beaad44640452f21e8823d98a9",
            "manifest.json": "711afacaa143bf773572972fe67ef361d8698835f9c75a64242f8515eb770d88",
        ]
    )
}
