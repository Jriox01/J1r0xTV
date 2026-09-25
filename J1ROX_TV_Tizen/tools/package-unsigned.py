"""Create a structure-only WGT archive, without certificates or TV install claims."""
import hashlib
import pathlib
import xml.etree.ElementTree as ET
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
config = ET.parse(root / "config.xml").getroot()
ns = {"w": "http://www.w3.org/ns/widgets", "t": "http://tizen.org/ns/widgets"}
assert config.find("w:content", ns).get("src") == "index.html"
assert config.find("t:application", ns).get("id") == "J1ROXTV001.TV"
assert config.find("t:profile", ns).get("name") == "tv-samsung"
assert config.find("t:content-security-policy", ns) is not None
files = [root / "config.xml", root / "index.html"]
for folder in ("js", "css", "assets"):
    files.extend(sorted(p for p in (root / folder).rglob("*") if p.is_file()))
target = root / "dist" / "J1ROX-TV-Samsung-unsigned.wgt"
target.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
    for file in files:
        archive.write(file, file.relative_to(root).as_posix())
with zipfile.ZipFile(target) as archive:
    assert archive.testzip() is None
    assert set(archive.namelist()) == {p.relative_to(root).as_posix() for p in files}
    assert "author-signature.xml" not in archive.namelist()
digest = hashlib.sha256(target.read_bytes()).hexdigest()
status = ("UNSIGNED STRUCTURE CHECK ONLY. Not installable on a retail Samsung TV.\n"
          "Not built or validated by Tizen CLI. No certificates generated.\n"
          f"Files: {len(files)}\nSHA256: {digest}\n")
target.with_suffix(".status.txt").write_text(status, encoding="utf-8")
print(target)
print(status)
