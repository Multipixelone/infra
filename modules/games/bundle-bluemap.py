"""Vendor BlueMap's declared Paper library; keep startup offline."""
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as plugin, zipfile.ZipFile(sys.argv[2]) as library:
    with zipfile.ZipFile(sys.argv[3], "w", zipfile.ZIP_DEFLATED) as output:
        names = set()
        for archive in (plugin, library):
            for item in archive.infolist():
                if item.filename in names or (archive is library and item.filename.startswith("META-INF/")):
                    continue
                content = archive.read(item)
                if item.filename == "plugin.yml":
                    declaration = b'\nlibraries:\n  - "com.flowpowered:flow-math:1.0.3"\n'
                    if declaration not in content:
                        raise ValueError("BlueMap library declaration changed")
                    content = content.replace(declaration, b"\n")
                output.writestr(item, content)
                names.add(item.filename)
