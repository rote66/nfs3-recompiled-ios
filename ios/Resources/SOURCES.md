# Resource sources

`nfs3.exe`, `eacsnd.dll`, `softtria.dll` and `voodoo2a.dll` are the unmodified
files tracked in upstream `nfs3hp/` at revision
`77ebdb3b6a21925ccfc4fc4c1d712abec3e1945a`. No Android binary is a build input.

`GameFiles/install.win` is a generated text file, not an upstream asset.
The original EXE's `sub_4a6e10` opens it at startup and loads non-empty lines
into 128-byte path slots at `0x7a2634`. The first slot selects the language.
The bundled table has 40 lines: language, the relative FEDATA/GAMEDATA paths
used by the game, and `.\` for unused slots. It is required by this unchanged
startup path. It is not a WIM archive, a DLL or executable code.

To reproduce it without any Android files:

```sh
python3 ios/tools/make_install_win.py ios/Resources/GameFiles/install.win
```

The runtime diagnostic executes the original parser against this generated
file and checks its language, tracks and movies slots.

`OriginalIcon.png` was downloaded separately on 2026-10-05:

- Archive page: https://www.steamgriddb.com/icon/54271
- PNG: https://cdn2.steamgriddb.com/icon/420fabae64f99a67952af322bd30b450/32/256x256.png
- SHA-256: `259c48ade8e4a16f92fce643e0941597409595d5833cc1c33c9b04b1e06a20e0`

The archive labels this red-car/III icon **Official**. It is a third-party
archive, not an EA-hosted download; that label is the provenance evidence
available here. The PNG is not copied from the Android workspace.
`tools/prepare_icons.py` crops the white outer border, then creates the opaque
iOS PNG sizes from this file. The original download is retained unchanged.

The v0.1.1 app icon had been resized from the Android workspace's launcher
PNG. That source is no longer used. All controls, vector symbols, pointer and
keyboard views are written in this iOS tree, with no Android artwork/code inputs.
