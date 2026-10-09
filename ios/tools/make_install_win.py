from pathlib import Path
import argparse


def installation_table(language):
    folders = {
        3: "gamedata/tracks",
        5: "gamedata/carmodel",
        6: "gamedata/render/pc",
        7: "gamedata/dashhud",
        8: "gamedata/audio/pc",
        9: "gamedata/audio/sfx",
        10: f"gamedata/audio/speech/{language}",
        15: "fedata/art",
        16: "fedata/text",
        17: "fedata/text",
        18: "fedata/save",
        19: "fedata/stats",
        20: "fedata/config",
        21: "fedata/stats/carspecs",
        22: "fedata/art/slides",
        23: "fedata/art/track",
        24: "fedata/art/showcase",
        25: "fedata/movies",
    }
    entries = [language] + [".\\"] * 39
    for slot, folder in folders.items():
        entries[slot] = folder.replace("/", "\\") + "\\"
    return "\n".join(entries) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    parser.add_argument("--language", default="english", choices=["english", "french", "german", "italian", "spanish", "swedish"])
    arguments = parser.parse_args()
    arguments.destination.write_text(installation_table(arguments.language), encoding="ascii")


if __name__ == "__main__":
    main()
