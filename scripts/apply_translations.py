"""Fill the Turkish column of Localizable.xcstrings from translations_tr.json.

Run after the catalog has been synced from a build:
  xcrun xcstringstool sync Tern/Resources/Localizable.xcstrings --stringsdata $(find build -path '*Tern.build/Objects-normal*' -name '*.stringsdata')
Keys that read the same in every language are marked "do not translate".
"""
import json, pathlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
catalog_path = root / "Tern/Resources/Localizable.xcstrings"
tr = json.loads((root / "scripts/translations_tr.json").read_text())
catalog = json.loads(catalog_path.read_text())
same_everywhere = {"", "·", "Tern", "GPX", "Joystick", "%lld×"}

# Keys no longer in the source are marked stale by the sync; drop them instead of translating.
for key in [k for k, e in catalog["strings"].items() if e.get("extractionState") == "stale"]:
    del catalog["strings"][key]

missing = []
for key, entry in catalog["strings"].items():
    if key in same_everywhere:
        entry["shouldTranslate"] = False
        entry.pop("localizations", None)
    elif key in tr:
        entry.setdefault("localizations", {})["tr"] = {
            "stringUnit": {"state": "translated", "value": tr[key]}
        }
    else:
        missing.append(key)

catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
if missing:
    print("Missing Turkish:", *missing, sep="\n  ")
    sys.exit(1)
print(f"Turkish filled for {len(catalog['strings']) - len(same_everywhere & set(catalog['strings']))} strings")
