// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.1.0",
        archive: "dmx-guest-0.1.0.tar.gz",
        bytes: 61697966,
        sha256: "6339408347e0c57f6acdfef3d8296e48727fea6462cbc969fa9e4060d74d87fa",
        files: [
            "Image": "ae0aeacf5fd282302293c8b8e7132e218f4dd29ee6eab8c882f92b25d85189ba",
            "docker.img": "0160beafe4638858a9ecfe7aa09711c4c9cc24de6898f42da71c6c3cd78bb6a9",
            "initramfs.gz": "d36eb097b9755d240fb722625d7f61652dfa6143fd9ae48a757ec8b4bda835b8",
            "manifest.json": "00e4d191b2f38dd24b017896adf6a46144b8a7296a707cc42654589ba6eb8d1e",
        ]
    )
}
