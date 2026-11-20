// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "v0.5.0",
        archive: "dmx-guest-0.5.0.tar.gz",
        bytes: 62656217,
        sha256: "11b4b63b58488c3acac15c06e20c2b2fdafb4fd360b52ca6fdd75d8476e0af8f",
        files: [
            "Image": "fa487e1461eac6012fb5c43281b815e36cfea99d4f4ce4ed30498811f7650bf3",
            "docker.img": "84589344b5e025fb0a2841a215554ea18861ac26add7e5fb98ce9e67fb03097d",
            "initramfs.gz": "d2ce5c3764ecf43f92c5ae1a5dd8be52eb5f52033b641b6c6ce53c5b05bb831e",
            "manifest.json": "5d67938b21c137a00b8c8c67c06f434a99c2fce69618ee99d48a8e6115e702a2",
        ]
    )
}
